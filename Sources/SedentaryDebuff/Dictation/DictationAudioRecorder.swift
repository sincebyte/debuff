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

    /// 上一次选择、现已被切走的麦克风 uid。切换所选设备时记下，等新设备就绪后
    /// 显式关闭它，避免 iPhone 等互联设备在切走后仍保持录音/连接。
    private var staleInputDeviceUID: String?

    /// 设置本会话要使用的麦克风（nil = 跟随系统默认）。若与上次不同，记下旧 uid，
    /// 待下次 start() 应用新设备后关闭它（见 closeStaleInputIfNeeded）。
    func setInputDevice(uid: String?) {
        if uid != inputDeviceUID {
            staleInputDeviceUID = inputDeviceUID
        }
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
    /// 跟随系统默认）。引擎未运行时调用。无论走哪条分支，结束后都会关闭被切走的旧设备。
    private func applySelectedInput() {
        defer { closeStaleInputIfNeeded() }
        guard let desired = inputDeviceUID, !desired.isEmpty,
              DictationMicrophone.inputDeviceID(forUID: desired) != nil else {
            // 未选设备 / 所选设备不在线：跟随系统默认，退出接管。
            CrashLog.write("[\(Date())] [BOOTREC] applySelectedInput: 跟随系统默认，快速路径\n")
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
        let wakeStart = Date()
        let awake = wakeSelectedInput(uid: desired)
        let wakeMS = Date().timeIntervalSince(wakeStart) * 1000
        CrashLog.write(String(
            format: "[%@] [BOOTREC] applySelectedInput: 选麦唤醒 uid=%@ 切换默认=%@ 唤醒前running=%@ 就绪=%@ 唤醒耗时=%.0fms\n",
            "\(Date())", desired, "\(switched)", "\(runningBefore)", "\(awake)", wakeMS
        ))
    }

    /// 等待设备进入 running；先给系统一个很短的「切为默认后自唤醒」窗口，超时就立即显式
    /// 启动再等。USB 等设备（如 DJI 无线麦）被切为默认后并不会自动 running，旧实现先空等
    /// 满 1.5 秒才显式启动，导致每次激活都白等 1.5 秒；这里改为短探测 + 立即启动，把这段
    /// 死等消除，同时仍保留「系统自唤醒」的机会（探测窗口内已 running 就直接返回）。
    @discardableResult
    private func wakeSelectedInput(uid: String) -> Bool {
        if waitUntilRunning(uid: uid, timeout: Self.inputSelfWakeProbe) { return true }
        _ = DictationMicrophone.startInputDevice(uid: uid)
        return waitUntilRunning(uid: uid, timeout: Self.inputWakeTimeout)
    }

    private func waitUntilRunning(uid: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if DictationMicrophone.isInputRunning(forUID: uid) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return DictationMicrophone.isInputRunning(forUID: uid)
    }

    /// 切为默认输入后，先给系统这么短的窗口尝试自唤醒；超时立即显式 AudioDeviceStart。
    private static let inputSelfWakeProbe: TimeInterval = 0.2

    /// 本次唤醒等待上限：互联设备成为默认输入后通常 1 秒内就开始出流。
    private static let inputWakeTimeout: TimeInterval = 1.5

    /// 停止时还原默认输入：仅还原到「接管前」的设备；该设备已不存在时保持系统当前默认不动。
    private func releaseSelectedInput() {
        // 会话真正使用过的设备（仅在我们接管过默认输入时才需要显式关闭）。
        let used = holdingRouting ? inputDeviceUID : nil
        if holdingRouting, let original = originalDefaultInputUID,
           DictationMicrophone.inputDeviceID(forUID: original) != nil,
           DictationMicrophone.defaultInputDeviceUID() != original {
            _ = DictationMicrophone.setDefaultInputDevice(uid: original)
        }
        // 恢复默认后关闭本次会话用过、现已被切走的设备。否则 iPhone 等互联设备
        // 会一直保持录音/连接（手机上仍显示正在录音）。
        if let used, used != DictationMicrophone.defaultInputDeviceUID(),
           DictationMicrophone.inputDeviceID(forUID: used) != nil {
            let stopped = DictationMicrophone.stopInputDevice(uid: used)
            CrashLog.write("[\(Date())] 停止会话：关闭已切走的麦克风 uid=\(used) stopped=\(stopped)\n")
        }
        clearTakeover()
    }

    /// 关闭被切走的旧麦克风：新设备应用完成后显式 stop 旧设备。系统默认切走后旧设备
    /// （尤其 iPhone 等互联设备）仍可能保持 running，不 stop 会一直占着录音/连接。
    private func closeStaleInputIfNeeded() {
        guard let stale = staleInputDeviceUID else { return }
        staleInputDeviceUID = nil
        // 仍被选中、或已成为系统当前默认（系统还要用它）时不关闭。
        guard stale != inputDeviceUID,
              stale != DictationMicrophone.defaultInputDeviceUID(),
              DictationMicrophone.inputDeviceID(forUID: stale) != nil else { return }
        let stopped = DictationMicrophone.stopInputDevice(uid: stale)
        CrashLog.write("[\(Date())] 切换麦克风：关闭被切走的设备 uid=\(stale) stopped=\(stopped)\n")
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
            // 已授权：同步回调，省去一次主线程往返，让激活启动更快。
            // 调用方（DictationController）会在回调里自行切回 engineQueue，线程安全。
            completion(true)
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
        let t0 = Date()
        var tLast = t0
        func stage(_ name: String) {
            let now = Date()
            CrashLog.write(String(
                format: "[%@] [BOOTREC] %@  +%.0fms  (start 累计 %.0fms)\n",
                "\(now)", name, now.timeIntervalSince(tLast) * 1000, now.timeIntervalSince(t0) * 1000
            ))
            tLast = now
        }
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
        stage("applySelectedInput（选麦/唤醒）")
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
        stage("installTap")
        engine.prepare()
        stage("engine.prepare")
        try engine.start()
        stage("engine.start（真正打开麦克风）")
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
