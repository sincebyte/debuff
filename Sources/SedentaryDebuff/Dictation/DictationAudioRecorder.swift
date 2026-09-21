import AVFoundation
import CoreAudio
import ExceptionCatcher
import Foundation

enum DictationRecorderError: LocalizedError {
    case invalidInputFormat
    case tapCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat:
            return "无法读取输入设备的音频格式"
        case .tapCreationFailed(let reason):
            return "创建麦克风音频采集失败：\(reason)"
        }
    }
}

final class DictationAudioRecorder {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// 期望使用的麦克风 uid（nil = 跟随系统当前默认输入）。由 DictationController
    /// 从设置写入，引擎每次 start() 前会把系统默认输入切到该设备并等其就绪。
    private(set) var inputDeviceUID: String?

    /// 设置本会话要使用的麦克风（nil = 跟随系统默认）。
    func setInputDevice(uid: String?) {
        inputDeviceUID = uid
    }

    private(set) var sampleRate: Double = 16000

    /// inputNode 与硬件绑定。锁屏/唤醒或切换设备后硬件格式会变，长期复用同一
    /// 引擎会让 inputNode 缓存旧设备格式：installTap 用过期格式挂 tap 会抛
    /// NSException（Failed to create tap due to format mismatch）直接崩溃，
    /// 因此硬件变化时必须重建引擎让 inputNode 重新绑定当前硬件。
    private var engine = AVAudioEngine()
    /// 是否已在 inputNode 挂了 tap。切换输入设备时引擎会被系统自行 stop，
    /// 但挂上的 tap 不会随之移除，重挂前必须显式删掉，否则 installTap 因
    /// 「已有 tap」抛异常直接崩溃（required condition is false: nullptr == Tap()）。
    private var tapInstalled = false

    var isRunning: Bool { engine.isRunning }

    // MARK: 选择输入设备
    // iPhone 等互联设备只有被设为「系统默认输入」时系统才会唤醒它（直接把输入 AudioUnit
    // 绑到该设备不会触发互联握手，start 只会反复得到 coreaudio 'stop'）。因此录音期间仍需
    // 接管系统默认输入，但唤醒方式要安全：只做一次真实的默认切换，然后轮询设备是否真正
    // running（必要时显式 AudioDeviceStart），就绪后才开麦——避免在设备半连接状态下启动
    // 引擎，得到「已连接却全是零电平」的坏会话；也避免旧实现「切走再切回」的抖动。
    /// 录音前接管前的系统默认输入 uid，用于 stop 时还原。
    private var originalDefaultInputUID: String?
    /// 当前是否持有「已切默认输入」状态（true 期间默认输入被我们接管）。
    private var holdingRouting = false

    /// 启动前把系统默认输入切到所选麦克风并等待其真正就绪（inputDeviceUID 为 nil 则
    /// 跟随系统默认）。引擎未运行时调用。
    private func applySelectedInput() {
        guard let desired = inputDeviceUID, !desired.isEmpty,
              DictationMicrophone.inputDeviceID(forUID: desired) != nil else {
            // 未选设备 / 所选设备不在线：跟随系统默认，退出接管。
            releaseSelectedInput()
            return
        }
        // 所选设备已经是系统默认输入：直接跟随系统使用，绝不做任何接管动作
        // （不切默认、不绑 AudioUnit、不 AudioDeviceStart）。iPhone 等互联设备正是
        // 在被程序化「选中」时才会落入「已连接却全是零电平」的坏态；而系统默认
        // 由系统自己管理时链路正常。此时保持与「跟随系统默认」完全一致即可。
        if DictationMicrophone.defaultInputDeviceUID() == desired {
            // 已是系统默认：清掉可能残留的接管状态但不做还原（还原反而会把它切走）。
            clearTakeover()
            CrashLog.write("[\(Date())] 所选麦克风已是系统默认，直接使用不接管：\(desired)\n")
            return
        }
        if originalDefaultInputUID == nil {
            originalDefaultInputUID = DictationMicrophone.defaultInputDeviceUID()
        }
        let switched = DictationMicrophone.defaultInputDeviceUID() != desired
        if switched {
            _ = DictationMicrophone.setDefaultInputDevice(uid: desired)
        }
        holdingRouting = true
        let runningBefore = DictationMicrophone.isInputRunning(forUID: desired)
        let awake = wakeSelectedInput(uid: desired)
        CrashLog.write("[\(Date())] 唤醒麦克风 uid=\(desired) 切换默认=\(switched) 唤醒前running=\(runningBefore) 就绪=\(awake)\n")
    }

    /// 等待设备进入 running；超时则显式启动一次再等，尽量把互联设备从
    /// 「已列出但未运行」状态里拉起来。返回最终是否 running。
    @discardableResult
    private func wakeSelectedInput(uid: String) -> Bool {
        if waitUntilRunning(uid: uid, timeout: Self.inputWakeTimeout) { return true }
        _ = DictationMicrophone.startInputDevice(uid: uid)
        return waitUntilRunning(uid: uid, timeout: Self.inputWakeTimeout)
    }

    private func waitUntilRunning(uid: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if DictationMicrophone.isInputRunning(forUID: uid) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return DictationMicrophone.isInputRunning(forUID: uid)
    }

    /// 本次唤醒等待上限：互联设备成为默认输入后通常 1 秒内就开始出流。
    private static let inputWakeTimeout: TimeInterval = 1.5

    /// 停止时还原默认输入：仅还原到「接管前」的设备；该设备已不存在时保持系统当前默认不动。
    private func releaseSelectedInput() {
        if holdingRouting, let original = originalDefaultInputUID,
           DictationMicrophone.inputDeviceID(forUID: original) != nil,
           DictationMicrophone.defaultInputDeviceUID() != original {
            _ = DictationMicrophone.setDefaultInputDevice(uid: original)
        }
        clearTakeover()
    }

    /// 只清空接管状态，不改动系统默认输入。
    private func clearTakeover() {
        holdingRouting = false
        originalDefaultInputUID = nil
    }

    private let bufferClockLock = NSLock()
    private var _lastBufferAt: Date?

    /// 最近一次收到输入缓冲的时刻。锁屏/唤醒或设备重连后，引擎可能“start 成功却
    /// 一直不回调 tap”（设备尚未就绪），此时该值长时间不更新，健康检查据此重建重启。
    var lastBufferAt: Date? {
        bufferClockLock.lock()
        defer { bufferClockLock.unlock() }
        return _lastBufferAt
    }

    private func markBufferReceived() {
        bufferClockLock.lock()
        _lastBufferAt = Date()
        bufferClockLock.unlock()
    }

    /// 清理缓冲时钟：启动/重建引擎时调用，避免误把上一轮引擎的最后缓冲当作本轮“健康”。
    func resetBufferClock() {
        bufferClockLock.lock()
        _lastBufferAt = nil
        bufferClockLock.unlock()
    }

    func requestPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            DispatchQueue.main.async {
                completion(true)
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        default:
            DispatchQueue.main.async {
                completion(false)
            }
        }
    }

    func start() throws {
        if engine.isRunning {
            engine.stop()
        }
        // 上次因设备变化被系统停掉的残留 tap 需先移除，再按新设备格式重挂。
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        resetBufferClock()
        // 先把系统默认输入切到所选麦克风并等它就绪，再按当前设备格式挂 tap。
        applySelectedInput()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw DictationRecorderError.invalidInputFormat
        }
        sampleRate = format.sampleRate
        // installTap 在格式与硬件不匹配时抛的是 Objective-C 异常（NSException），
        // Swift 的 do/catch 接不住，会直接 terminate 进程（典型场景：解锁唤醒后
        // 新引擎的 inputNode 还报着过期的 44100/2 格式，而硬件已就绪为别的格式）。
        // 用 ObjC 桥接把它转成可捕获的错误，交给上层的退避重试自愈。
        var tapError: NSString?
        let installed = DBCatchException({
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                self?.markBufferReceived()
                self?.onBuffer?(buffer)
            }
        }, &tapError)
        guard installed else {
            resetBufferClock()
            throw DictationRecorderError.tapCreationFailed(tapError as String? ?? "未知原因")
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        // 引擎会话结束：把系统默认输入还原到接管前。
        releaseSelectedInput()
    }

    /// 输入/输出硬件变化后调用：丢弃旧引擎并新建，让 inputNode 重新绑定当前
    /// 硬件，避免用旧设备缓存的格式 installTap 而崩溃。必须在引擎未运行的
    /// 引擎队列上调用。
    func rebuildEngine() {
        if engine.isRunning {
            engine.stop()
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine = AVAudioEngine()
        sampleRate = 0
        resetBufferClock()
    }
}
