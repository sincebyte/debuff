import AVFoundation
import CoreAudio
import Foundation

enum DictationRecorderError: LocalizedError {
    case invalidInputFormat

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat:
            return "无法读取输入设备的音频格式"
        }
    }
}

final class DictationAudioRecorder {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// 期望使用的麦克风 uid（nil = 跟随系统当前默认输入）。由 DictationController
    /// 从设置写入，引擎每次 start() 前会把系统默认输入切到该设备。
    /// 只在 routingLock 保护下读写，避免引擎队列写、监听回调读的竞态。
    private(set) var inputDeviceUID: String?

    /// 设置本会话要使用的麦克风（nil = 跟随系统默认）。
    func setInputDevice(uid: String?) {
        routingLock.lock()
        inputDeviceUID = uid
        routingLock.unlock()
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

    // MARK: 输入路由（录音期间把系统默认输入切到所选麦克风，结束后还原）
    // AVAudioEngine 只能采系统默认输入设备，无法直接指定设备，因此用 CoreAudio 在
    // 引擎 start 前切换默认输入。整个「强制切默认输入 → 监听变化 → 停止时还原」的生命
    // 周期以一次引擎会话为单位：rebuildEngine/原地续麦不清零，只有 stop() 才还原，
    // 保证会话内自动续麦仍采同一支麦克风。
    private let routingLock = NSLock()
    /// 强制切换前的系统默认输入 uid，用于 stop 时还原。
    private var originalDefaultInputUID: String?
    /// 当前是否持有「已切默认输入」状态（true 期间默认输入被我们接管）。
    private var holdingRouting = false
    /// CoreAudio 属性监听块需强持有，否则会被释放导致监听失效。
    private var routingListener: AudioObjectPropertyListenerBlock?
    /// 默认输入变化监听派发队列。路由状态可能被引擎队列与监听回调并发触碰，
    /// 一律经 routingLock 串行保护。
    private let routingQueue = DispatchQueue(label: "dictation.audio.routing")

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

    /// 启动前切换默认输入到所选麦克风（inputDeviceUID 为 nil 则不动，跟随系统）。
    /// 在引擎准备/启动之前调用，保证 inputNode 绑定到目标设备。
    private func applyInputDeviceRouting() {
        routingLock.lock()
        defer { routingLock.unlock() }
        guard let desired = inputDeviceUID, !desired.isEmpty else {
            // 跟随系统默认：若上一段还握着「切到某设备」的接管，先还原，让引擎绑回系统默认。
            releaseInputDeviceRoutingLocked()
            return
        }
        // 所选设备不在线（未连接/未就绪）：跟随系统当前默认，不持有路由。
        guard DictationMicrophone.name(forUID: desired) != nil else {
            releaseInputDeviceRoutingLocked()
            return
        }
        installRoutingListenerLocked()
        let currentDefault = DictationMicrophone.defaultInputDeviceUID()
        if originalDefaultInputUID == nil {
            originalDefaultInputUID = currentDefault
        }
        guard currentDefault != desired else {
            // 系统默认本来就是目标设备，无需切换，但仍持有状态以便监听变化。
            holdingRouting = true
            return
        }
        if DictationMicrophone.setDefaultInputDevice(uid: desired) {
            holdingRouting = true
        } else {
            // 切换失败（设备刚掉线等）：跟随系统默认，退出接管。
            releaseInputDeviceRoutingLocked()
        }
    }

    /// 系统默认输入被外部改动（如所选设备拔出后系统回退）时回调：所选设备仍在则
    /// 重新切回（避免系统把默认输入悄悄切走，导致本会话录到别的麦克风）；所选设备已
    /// 消失则放弃接管，跟随系统回退后的默认输入继续（由健康检查自动续麦）。
    private func handleDefaultInputChanged() {
        routingLock.lock()
        defer { routingLock.unlock() }
        guard holdingRouting, let desired = inputDeviceUID, !desired.isEmpty else { return }
        guard let currentDefault = DictationMicrophone.defaultInputDeviceUID(),
              currentDefault != desired else { return }
        if DictationMicrophone.name(forUID: desired) != nil {
            _ = DictationMicrophone.setDefaultInputDevice(uid: desired)
        } else {
            releaseInputDeviceRoutingLocked()
        }
    }

    /// 停止时还原默认输入：仅还原到「强制切换前」的设备；若该设备已不存在则保持
    /// 系统当前默认不动。随后移除监听、清空接管状态，等待下一次会话重新接管。
    private func releaseInputDeviceRouting() {
        routingLock.lock()
        releaseInputDeviceRoutingLocked()
        routingLock.unlock()
    }

    private func releaseInputDeviceRoutingLocked() {
        if holdingRouting, let original = originalDefaultInputUID,
           let currentDefault = DictationMicrophone.defaultInputDeviceUID(),
           currentDefault != original,
           DictationMicrophone.name(forUID: original) != nil {
            _ = DictationMicrophone.setDefaultInputDevice(uid: original)
        }
        holdingRouting = false
        originalDefaultInputUID = nil
        removeRoutingListenerLocked()
    }

    private func installRoutingListenerLocked() {
        guard routingListener == nil else { return }
        var address = Self.defaultInputPropertyAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultInputChanged()
        }
        guard AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, routingQueue, listener
        ) == noErr else { return }
        routingListener = listener
    }

    private func removeRoutingListenerLocked() {
        guard let listener = routingListener else { return }
        var address = Self.defaultInputPropertyAddress
        _ = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, routingQueue, listener
        )
        routingListener = nil
    }

    private static let defaultInputPropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

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
        // 先切默认输入再拿 inputNode，让引擎绑定到所选麦克风。
        applyInputDeviceRouting()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw DictationRecorderError.invalidInputFormat
        }
        sampleRate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.markBufferReceived()
            self?.onBuffer?(buffer)
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
        // 引擎会话结束：把系统默认输入还原到接管前，清空监听。
        releaseInputDeviceRouting()
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
