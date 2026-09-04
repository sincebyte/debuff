import AppKit
import AVFoundation
import Combine
import Foundation

final class DictationController: ObservableObject {
    enum State: Equatable {
        case off       // 引擎关闭：麦克风未开启（空闲，控件隐藏）
        case active    // 激活：语音上屏，删除/清空/over/发送等指令生效
        case inactive  // 非激活：待命监听只驱动灰色波形，不切段不转写；仅快捷键重新激活
        case flushing  // 停止引擎时的收尾转写
    }

    @Published private(set) var state: State = .off
    @Published private(set) var statusText: String = "空闲"

    let settings: DictationSettings

    private let recorder = DictationAudioRecorder()
    private let transcriber = DictationTranscriber()
    private let engineQueue = DispatchQueue(label: "dictation.engine")
    private let vad = DictationVAD(config: DictationVAD.Config())

    private var currentState: State = .off
    private var currentStatus = "空闲"

    private var segmentSamples: [Float] = []
    private var segmentStart: Date?

    private var pending = 0
    private var isFlushing = false
    private var discardPendingOnStop = false
    private var lastError: String?
    private var unpasted: [String] = []
    private var awaitingPermission = false
    /// 权限弹窗期间是否仍期望开启（锁屏/停止会清掉，避免授权回来后在锁屏时悄悄开麦）。
    private var shouldStartOnPermission = false
    /// 引擎代数：每启动一次监听自增，过期转写结果按代数丢弃，避免跨会话串扰。
    private var generation = 0
    /// 锁屏时若在监听，记录解锁后要恢复的模式。
    private var shouldRestoreAfterUnlock = false
    private var restoreModeOnUnlock: State = .inactive

    private var pasteQueue: [String] = []
    private var pasteBusy = false
    /// 引擎因输入/输出硬件变化（切换麦克风等）自行 stop 时回调，用于原地续麦。
    private var engineConfigChangeObserver: NSObjectProtocol?

    // MARK: 引擎健康自愈
    /// 锁屏/唤醒、设备重连后设备往往延迟就绪：start() 可能抛错，或“start 成功却不回调
    /// 任何输入缓冲”（引擎僵死）。以下字段 + 周期健康检查用于把僵死引擎重建重启，
    /// 让录音在麦克风就绪后自动恢复，而不是停留在“开着却录不进声音”。
    /// 周期性健康检查定时器（engineQueue 上，只在监听期间动作）。
    private var healthTimer: DispatchSourceTimer?
    /// 最近一次引擎 start 成功的时刻，用于区分“刚启动”与“早已僵死”。
    private var engineStartedAt: Date?
    /// 连续启动/自愈失败次数，成功或观测到数据流时清零，超阈值放弃自愈。
    private var startFailureStreak = 0
    /// 全新开启（从 off 启动）的自动重试标记与目标状态。
    private var autoBootPending = false
    private var autoBootMode: State = .active
    private var autoBootAttempt = 0

    /// 首次开启失败时的最大重试次数（退避延迟累加，合计约一分钟）。
    private static let maxBootAttempts = 20
    /// 监听中原地自愈（引擎未运行 / 运行但无数据）的连续失败上限，超过后停止监听避免空转。
    private static let maxRecoveryStreak = 6
    /// 健康检查周期。
    private static let healthCheckInterval: TimeInterval = 3
    /// 引擎运行后超过该时长仍收不到输入缓冲即判定僵死。
    private static let noBufferStallSeconds: TimeInterval = 6

    private let waveformData = DictationWaveformData()
    private let waveformPanel: DictationWaveformPanel

    private static let minSegmentSeconds = 0.5

    /// 识别到的语音指令（仅激活状态识别）：每条指令对应一个固定动作。
    private enum VoiceCommand {
        case deactivate  // 「over」：激活 → 非激活
        case send        // 「发送」：回车发送 + 切到非激活
        case deleteWord  // 「删除/撤销」
        case clear       // 「清空/clear」
    }

    /// 一段转写里识别出的指令：`command` 是要执行的动作；`body` 仅「发送」贴在
    /// 正文末尾命中时才有值，即命令词前面的正文，随发送一起落盘。
    private struct CommandMatch {
        let command: VoiceCommand
        let body: String?
    }

    init(settings: DictationSettings) {
        self.settings = settings
        waveformPanel = DictationWaveformPanel(data: waveformData)
        recorder.onBuffer = { [weak self] buffer in
            guard let self else { return }
            self.engineQueue.async {
                self.process(buffer: buffer)
            }
        }
        engineConfigChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.engineQueue.async {
                self?.handleEngineConfigurationChange()
            }
        }
        applyHotkey()
        waveformPanel.setActiveOpacity(settings.activeOpacity)
        waveformPanel.onWidthChange = { [weak self] width in
            self?.settings.waveformWidth = Double(width)
        }
        waveformPanel.setWidth(CGFloat(settings.waveformWidth))
        startHealthTimer()
    }

    /// 周期检查引擎健康：麦克风应开未开、或引擎僵死（开着却没数据流）时自动重建重启。
    private func startHealthTimer() {
        let timer = DispatchSource.makeTimerSource(queue: engineQueue)
        timer.schedule(deadline: .now() + Self.healthCheckInterval, repeating: Self.healthCheckInterval)
        timer.setEventHandler { [weak self] in
            self?.healthCheck()
        }
        timer.resume()
        healthTimer = timer
    }

    func applyWaveformWidth() {
        waveformPanel.setWidth(CGFloat(settings.waveformWidth))
    }

    deinit {
        healthTimer?.cancel()
        healthTimer = nil
        if let engineConfigChangeObserver {
            NotificationCenter.default.removeObserver(engineConfigChangeObserver)
        }
        DictationHotKey.unregister()
    }

    // MARK: - 状态

    var isEngineOn: Bool {
        state != .off
    }

    var isInputActive: Bool {
        state == .active
    }

    var isAccessibilityTrusted: Bool {
        DictationPasteBoard.isAccessibilityTrusted
    }

    /// 当前快捷键的展示名，用于待命提示文案。
    private var hotkeyLabel: String {
        DictationHotKey.label(keyCode: settings.hotkeyKeyCode, flags: settings.hotkeyFlags)
    }

    // MARK: - 快捷键 / 引擎开关

    func applyHotkey() {
        DictationHotKey.register(
            keyCode: settings.hotkeyKeyCode,
            flags: settings.hotkeyFlags
        ) { [weak self] in
            self?.toggle()
        }
    }

    /// 快捷键：仅在「激活 / 非激活」之间切换；引擎未开启时先开启引擎并激活。
    func toggle() {
        engineQueue.async { [weak self] in
            guard let self else { return }
            switch self.currentState {
            case .off:
                self.requestStart()
            case .active:
                self.setVoiceInactive()
            case .inactive:
                self.setVoiceActive()
            case .flushing:
                break
            }
        }
    }

    /// 菜单「开始/停止语音输入」：引擎总开关。
    func startStop() {
        engineQueue.async { [weak self] in
            guard let self else { return }
            switch self.currentState {
            case .off:
                self.requestStart()
            default:
                self.stopDictation()
            }
        }
    }

    func startDictation() {
        engineQueue.async { [weak self] in
            self?.requestStart()
        }
    }

    func applyActiveOpacity() {
        waveformPanel.setActiveOpacity(settings.activeOpacity)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isInputActive else { return }
            self.waveformPanel.setActive(true)
        }
    }

    private func requestStart(initialMode: State = .active) {
        guard currentState == .off, !awaitingPermission else { return }
        guard DictationPasteBoard.isAccessibilityTrusted else {
            setStatus("需辅助功能授权才能使用语音输入")
            DispatchQueue.main.async {
                DictationPasteBoard.promptAccessibility()
            }
            return
        }
        awaitingPermission = true
        shouldStartOnPermission = true
        recorder.requestPermission { [weak self] granted in
            guard let self else { return }
            self.engineQueue.async {
                self.awaitingPermission = false
                if granted {
                    // 若期间已锁屏/已停止，此处应放弃开启，避免在锁屏状态下开麦。
                    guard self.shouldStartOnPermission else { return }
                    self.shouldStartOnPermission = false
                    self.beginRecording(mode: initialMode)
                } else {
                    self.shouldStartOnPermission = false
                    self.setStatus("未授权麦克风，请在系统设置中允许")
                }
            }
        }
    }

    /// 全新开启（从 off 启动，含解锁后恢复）：重置会话状态后启动引擎。
    /// 麦克风在锁屏/唤醒瞬间往往尚未就绪，start 可能抛错，这里交给自动退避重试自愈。
    private func beginRecording(mode: State = .active) {
        segmentSamples.removeAll()
        segmentStart = nil
        vad.reset()
        pending = 0
        isFlushing = false
        discardPendingOnStop = false
        lastError = nil
        unpasted.removeAll()
        generation += 1
        // 取消上一次可能仍在排队的启动重试，改用本次目标状态。
        autoBootPending = false
        autoBootAttempt = 0
        bootAndEnter(mode: mode)
    }

    /// 记录一次“想要开启引擎”的目标，随后立即尝试；失败由 attemptBootOnce 自动退避重试。
    private func bootAndEnter(mode: State) {
        guard currentState == .off, !autoBootPending else { return }
        autoBootMode = mode
        autoBootPending = true
        attemptBootOnce()
    }

    /// 从 off 状态启动引擎：失败则按指数退避自动重试（解锁/唤醒瞬间设备未就绪也能自动恢复）。
    /// 重试期间保持 off（面板隐藏），一旦成功再进入目标监听状态。
    private func attemptBootOnce() {
        guard currentState == .off, autoBootPending else { return }
        do {
            recorder.rebuildEngine()
            try recorder.start()
        } catch {
            autoBootAttempt += 1
            guard autoBootAttempt <= Self.maxBootAttempts else {
                CrashLog.write("[\(Date())] 启动麦克风连续失败 \(autoBootAttempt) 次，放弃\n")
                autoBootPending = false
                autoBootAttempt = 0
                setStatus("启动麦克风失败：\(error.localizedDescription)")
                return
            }
            CrashLog.write("[\(Date())] 启动麦克风失败（第 \(autoBootAttempt) 次，稍后重试）：\(error.localizedDescription)\n")
            setStatus("启动麦克风失败，正在等待麦克风就绪自动重试…（\(autoBootAttempt)）")
            let delay = min(0.3 * pow(2.0, Double(autoBootAttempt - 1)), 4.0)
            engineQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.autoBootPending else { return }
                self.attemptBootOnce()
            }
            return
        }
        autoBootPending = false
        autoBootAttempt = 0
        engineStartedAt = Date()
        let mode = autoBootMode
        CrashLog.write("[\(Date())] 引擎启动成功，进入 \(mode == .active ? "激活" : "非激活")\n")
        enterListeningState(mode)
    }

    /// 引擎启动成功后的 UI 收尾：进入指定状态并展示波形面板。
    private func enterListeningState(_ mode: State) {
        waveformData.reset(sampleRate: recorder.sampleRate)
        let initial = mode == .active ? State.active : .inactive
        setState(initial)
        setStatus(initial == .active ? "输入中…" : "待命（按 \(hotkeyLabel) 重新激活）")
        let isActive = initial == .active
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.waveformPanel.setActiveOpacity(self.settings.activeOpacity)
            self.waveformPanel.setListening(true)
            self.waveformPanel.setWidth(CGFloat(self.settings.waveformWidth))
            self.waveformPanel.show()
            self.waveformPanel.setActive(isActive)
        }
    }

    private func stopDictation() {
        guard currentState == .active || currentState == .inactive else { return }
        let wasActive = currentState == .active
        CrashLog.write("[\(Date())] 停止引擎：state=\(currentState)\n")
        resetEngineBookkeeping()
        isFlushing = true
        discardPendingOnStop = !wasActive
        setState(.flushing)
        setStatus("正在收尾转写…")
        recorder.stop()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.waveformPanel.setActive(false)
            self.waveformPanel.setListening(false)
        }
        engineQueue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            if wasActive {
                self.flushFinalSegment()
            } else {
                // 非激活停麦：待命期间不切段不转写，没有残留段需上屏。
                self.segmentSamples.removeAll()
                self.segmentStart = nil
                self.vad.reset()
            }
            self.finishIfNeeded()
        }
    }

    /// 重置引擎健康自愈相关簿记（停止/锁屏时调用，避免残留的重试与计数干扰下一轮）。
    private func resetEngineBookkeeping() {
        autoBootPending = false
        autoBootAttempt = 0
        startFailureStreak = 0
        engineStartedAt = nil
        shouldStartOnPermission = false
        recorder.resetBufferClock()
    }

    // MARK: - 锁屏 / 解锁

    /// 锁屏：若正在监听，关停麦克风并记录解锁后要恢复的模式。
    func handleScreenLock() {
        engineQueue.async { [weak self] in
            guard let self else { return }
            if self.currentState == .active || self.currentState == .inactive {
                self.shouldRestoreAfterUnlock = true
                self.restoreModeOnUnlock = self.currentState
            } else {
                self.shouldRestoreAfterUnlock = false
            }
            self.stopForScreenLock()
        }
    }

    /// 解锁：若锁屏前在监听，恢复到之前的模式（激活/非激活）。
    func handleScreenUnlock() {
        engineQueue.async { [weak self] in
            guard let self else { return }
            guard self.shouldRestoreAfterUnlock else { return }
            self.shouldRestoreAfterUnlock = false
            let mode = self.restoreModeOnUnlock
            CrashLog.write("[\(Date())] 解锁：恢复监听 mode=\(mode)\n")
            self.requestStart(initialMode: mode)
        }
    }

    /// 立即停麦（用于锁屏）：丢弃未上屏与在途转写，切到关闭态。
    /// 即使当前是 off（全新开启的自动重试仍在排队），也要先取消排队，避免锁屏期间悄悄开麦。
    private func stopForScreenLock() {
        resetEngineBookkeeping()
        guard currentState != .off else { return }
        CrashLog.write("[\(Date())] 锁屏：停止监听 state=\(currentState)\n")
        if recorder.isRunning {
            recorder.stop()
        }
        segmentSamples.removeAll()
        segmentStart = nil
        vad.reset()
        isFlushing = false
        discardPendingOnStop = true
        generation += 1 // 使锁屏前在途的转写结果失效，避免解锁后误上屏/误执行
        pending = 0
        lastError = nil
        unpasted.removeAll()
        setState(.off)
        setStatus("空闲")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.waveformPanel.setActive(false)
            self.waveformPanel.setListening(false)
            self.waveformPanel.hide()
        }
    }

    // MARK: - 激活 / 非激活

    /// 非激活 → 激活（仅快捷键）。
    private func setVoiceActive() {
        guard currentState == .inactive else { return }
        guard recorder.isRunning else {
            // 引擎异常中断：复位到关闭态，按标准流程重新开启麦克风。
            segmentSamples.removeAll()
            segmentStart = nil
            vad.reset()
            pending = 0
            isFlushing = false
            discardPendingOnStop = false
            lastError = nil
            unpasted.removeAll()
            currentState = .off
            requestStart()
            return
        }
        CrashLog.write("[\(Date())] 状态：非激活 → 激活\n")
        segmentSamples.removeAll()
        segmentStart = nil
        vad.reset()
        setState(.active)
        setStatus("输入中…")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.waveformPanel.show()
            self.waveformPanel.setActive(true)
        }
    }

    /// 激活 → 非激活（语音「over」或快捷键）。先把积压文本（非「边说边贴」模式）落盘，再进入待命。
    private func setVoiceInactive() {
        guard currentState == .active else { return }
        CrashLog.write("[\(Date())] 状态：激活 → 非激活\n")
        segmentSamples.removeAll()
        segmentStart = nil
        vad.reset()
        let pendingPaste = unpasted
        unpasted.removeAll()
        setState(.inactive)
        setStatus("待命（按 \(hotkeyLabel) 重新激活）")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.waveformPanel.setActive(false)
            for text in pendingPaste {
                self.enqueuePaste(text)
            }
        }
    }

    // MARK: - 硬件变化（切换输入设备）与引擎健康自愈

    /// 输入/输出硬件变化（如切换麦克风、锁屏/唤醒）时引擎被系统自行 stop。
    /// 先重建引擎，让 inputNode 丢弃旧设备的缓存格式、重新绑定当前硬件——
    /// 否则用过期格式 installTap 会抛 NSException（format mismatch）崩溃。
    /// 锁屏前的停麦（stopForScreenLock）会先置为 off，此处不会重复续麦。
    /// 注意：设备重连后设备往往还没就绪，立即续麦可能 start 抛错或“开着却无数据”，
    /// 失败不置 off，交由周期健康检查继续自愈，直到麦克风真正就绪、数据流入。
    private func handleEngineConfigurationChange() {
        // 无论是否在监听都重建，保证下次 start() 用的是新硬件的格式。
        recorder.rebuildEngine()
        recorder.resetBufferClock()
        guard currentState == .active || currentState == .inactive else { return }
        CrashLog.write("[\(Date())] 输入设备变化：引擎被系统停止，原地续麦 state=\(currentState)\n")
        segmentSamples.removeAll()
        segmentStart = nil
        vad.reset()
        do {
            try recorder.start()
            engineStartedAt = Date()
            waveformData.reset(sampleRate: recorder.sampleRate)
            CrashLog.write("[\(Date())] 输入设备变化后已续麦 state=\(currentState)\n")
        } catch {
            // 此刻设备可能尚未就绪：不打断当前状态，健康检查会在就绪后自动续上。
            CrashLog.write("[\(Date())] 输入设备变化后重启麦克风失败，等待自动恢复：\(error.localizedDescription)\n")
            setStatus("麦克风切换后正在自动恢复…")
        }
    }

    /// 周期健康检查（engineQueue 上运行）：麦克风应开未开、或引擎僵死（开着却没
    /// 数据流）时原地重建重启，让锁屏/唤醒、设备重连后的录音自动恢复。
    private func healthCheck() {
        guard currentState == .active || currentState == .inactive else { return }
        // 刚启动/刚重建后的观察期：给设备就绪留缓冲，期间不做判定（避免反复重建）。
        if let started = engineStartedAt,
           Date().timeIntervalSince(started) <= Self.healthCheckInterval {
            return
        }
        if engineIsProducing() {
            // 数据正常流入：清空失败计数，保持健康。
            if startFailureStreak != 0 { startFailureStreak = 0 }
            return
        }
        startFailureStreak += 1
        if startFailureStreak >= Self.maxRecoveryStreak {
            CrashLog.write("[\(Date())] 麦克风持续不可用（连续 \(startFailureStreak) 次），停止监听避免空转\n")
            stopAfterHardwareFailure()
            return
        }
        if recorder.isRunning {
            CrashLog.write("[\(Date())] 健康检查：引擎运行但收不到输入数据（第 \(startFailureStreak) 次），重建重启\n")
            recoverEngineInPlace(reason: "运行中无音频数据（设备疑似未就绪）")
        } else {
            CrashLog.write("[\(Date())] 健康检查：引擎意外停止（第 \(startFailureStreak) 次），重启\n")
            recoverEngineInPlace(reason: "引擎意外停止")
        }
    }

    /// 引擎是否正在产出音频：须持续收到输入缓冲才算健康（静音也会收到缓冲，
    /// 因此“无数据”即意味着 tap 僵死）。观察期由 healthCheck 单独处理。
    private func engineIsProducing() -> Bool {
        guard recorder.isRunning, let started = engineStartedAt else { return false }
        guard let last = recorder.lastBufferAt else { return false }
        return Date().timeIntervalSince(started) > Self.healthCheckInterval
            && Date().timeIntervalSince(last) <= Self.noBufferStallSeconds
    }

    /// 监听中原地恢复引擎（保留当前激活/非激活状态与波形面板）。失败时交由下一轮
    /// 健康检查继续，不打断现有状态。
    private func recoverEngineInPlace(reason: String) {
        guard currentState == .active || currentState == .inactive else { return }
        CrashLog.write("[\(Date())] 原地重建重启引擎：\(reason) state=\(currentState)\n")
        segmentSamples.removeAll()
        segmentStart = nil
        vad.reset()
        recorder.rebuildEngine()
        do {
            try recorder.start()
            engineStartedAt = Date()
            waveformData.reset(sampleRate: recorder.sampleRate)
            CrashLog.write("[\(Date())] 原地重启成功 state=\(currentState)\n")
        } catch {
            CrashLog.write("[\(Date())] 原地重启失败：\(error.localizedDescription)，等下一轮重试\n")
            setStatus("麦克风恢复中，请稍候…")
        }
    }

    /// 长时间无法获取麦克风数据时收尾：复位并停到 off，给出可操作的提示。
    private func stopAfterHardwareFailure() {
        resetEngineBookkeeping()
        if recorder.isRunning {
            recorder.stop()
        }
        segmentSamples.removeAll()
        segmentStart = nil
        vad.reset()
        isFlushing = false
        discardPendingOnStop = true
        generation += 1
        pending = 0
        lastError = nil
        unpasted.removeAll()
        setState(.off)
        setStatus("麦克风不可用，语音输入已停止（可稍后重新开始）")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.waveformPanel.setActive(false)
            self.waveformPanel.setListening(false)
            self.waveformPanel.hide()
        }
    }

    // MARK: - 音频处理

    private func process(buffer: AVAudioPCMBuffer) {
        let samples = readSamples(buffer)
        guard !samples.isEmpty else { return }
        waveformData.append(samples)
        // 非激活待命只驱动灰色波形跳动，不做切段/STT 转写，省掉待命期的识别消耗。
        guard currentState == .active else { return }
        segmentSamples.append(contentsOf: samples)
        if segmentStart == nil {
            segmentStart = Date()
        }

        let now = Date()
        let rms = Self.rms(samples: samples)
        if vad.feed(rms: rms, at: now.timeIntervalSinceReferenceDate, silenceSeconds: settings.pauseSilenceSeconds) {
            finalizeSegment(force: false)
            return
        }
        if let start = segmentStart, now.timeIntervalSince(start) >= settings.maxSegmentSeconds {
            finalizeSegment(force: false)
        }
    }

    private func readSamples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channels = buffer.floatChannelData else { return [] }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 0, frameCount > 0 else { return [] }
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: frameCount))
        }
        var samples = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += channels[channel][frame]
            }
            samples[frame] = sum / Float(channelCount)
        }
        return samples
    }

    private static func rms(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return sqrt(sum / Float(samples.count))
    }

    private func finalizeSegment(force: Bool) {
        let samples = segmentSamples
        segmentSamples.removeAll()
        segmentStart = nil
        vad.reset()

        guard !samples.isEmpty else { return }
        let minCount = Int(recorder.sampleRate * Self.minSegmentSeconds)
        if samples.count < minCount && !force {
            CrashLog.write("[\(Date())] 段落过短被丢弃 samples=\(samples.count)/\(minCount)\n")
            return
        }

        let wav = WAVWriter.pcm16Data(samples: samples, sampleRate: Int(recorder.sampleRate))
        let gen = generation
        pending += 1
        transcriber.transcribe(wavData: wav, urlString: settings.sttURLString) { [weak self] result in
            guard let self else { return }
            self.engineQueue.async {
                self.handleResult(result, generation: gen)
            }
        }
    }

    private func flushFinalSegment() {
        guard !segmentSamples.isEmpty else { return }
        finalizeSegment(force: true)
    }

    // MARK: - 转写结果

    private func handleResult(_ result: Result<String, Error>, generation gen: Int) {
        // 过期代数（锁屏停麦/重启引擎前的转写）一律丢弃，避免误上屏或误执行指令。
        guard gen == generation else {
            CrashLog.write("[\(Date())] 丢弃过期转写（gen \(gen) != \(generation)）\n")
            return
        }
        pending -= 1
        switch result {
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            CrashLog.write("[\(Date())] 转写结果: 「\(trimmed)」 state=\(currentState)\n")
            if !trimmed.isEmpty {
                handleTranscribed(trimmed)
            }
        case .failure(let error):
            lastError = error.localizedDescription
            setStatus("转写失败：\(error.localizedDescription)")
        }
        finishIfNeeded()
    }

    /// 按当前状态决定一段转写文本的去向：激活才上屏/执行指令；其余状态一律不识别唤醒词。
    private func handleTranscribed(_ text: String) {
        switch currentState {
        case .active:
            if let match = Self.detectCommand(text) {
                // 「发送」贴在句子末尾命中时，先把命令词前面的正文加入积压，
                // 发送流程会把积压内容全部粘贴后统一回车。
                if let body = match.body {
                    unpasted.append(body)
                }
                perform(match.command)
            } else {
                unpasted.append(text)
                if settings.livePaste {
                    pasteNextUnpasted()
                }
            }
        case .inactive:
            // 非激活待命不切段不转写（见 process()），此处只会收到「激活→非激活」跨越瞬间
            // 已在途的转写结果，一律丢弃，避免误上屏或误触发。
            break
        case .flushing:
            // 从激活停止时收尾的文本仍要落盘；从非激活停止时丢弃待命期间的转写。
            if !discardPendingOnStop {
                unpasted.append(text)
            }
        case .off:
            break
        }
    }

    /// 语音指令识别：整段转写文本去掉首尾空白、标点并忽略大小写后，恰好等于某个指令词。
    /// 「发送」例外：允许贴在句子末尾——去掉 STT 自动追加的尾随标点后，末两字为「发送」
    /// 即视为发送指令（不必单独说「发送」），前面的正文作为 body 随发送一起上屏。
    private static func detectCommand(_ text: String) -> CommandMatch? {
        let normalized = normalizedCommand(text)
        switch normalized {
        case "over":
            return CommandMatch(command: .deactivate, body: nil)
        case "删除", "撤销":
            return CommandMatch(command: .deleteWord, body: nil)
        case "清空", "clear":
            return CommandMatch(command: .clear, body: nil)
        default:
            break
        }
        guard normalized.hasSuffix("发送") else { return nil }
        let body = String(normalized.dropLast(2))
        return CommandMatch(command: .send, body: body.isEmpty ? nil : body)
    }

    private static func normalizedCommand(_ text: String) -> String {
        text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
    }

    /// 执行识别到的指令（仅激活状态会走到这里）。
    private func perform(_ command: VoiceCommand) {
        switch command {
        case .deactivate:
            setVoiceInactive()
        case .send:
            performSendCommand()
        case .deleteWord:
            performDeleteWordCommand()
        case .clear:
            performClearCommand()
        }
    }

    /// 识别到「清空/clear」指令：清空当前输入框全部内容，继续输入。
    private func performClearCommand() {
        CrashLog.write("[\(Date())] 指令：清空 → 主线程发 ⌘A+⌫ state=\(currentState)\n")
        DispatchQueue.main.async {
            DictationPasteBoard.pressClearAll()
            CrashLog.write("[\(Date())] 已调用 pressClearAll\n")
        }
    }

    /// 识别到「删除/撤销」指令：在当前焦点按一次 ⌥⌫ 删除一个词，继续输入。
    private func performDeleteWordCommand() {
        CrashLog.write("[\(Date())] 指令：删除/撤销 → 主线程发 ⌥⌫ state=\(currentState)\n")
        DispatchQueue.main.async {
            DictationPasteBoard.pressDeleteWord()
            CrashLog.write("[\(Date())] 已调用 pressDeleteWord\n")
        }
    }

    /// 识别到「发送」指令：粘贴积压文本后发一次回车，并把控件切到非激活待命（不再退出）。
    private func performSendCommand() {
        guard currentState == .active else { return }
        CrashLog.write("[\(Date())] 指令：发送 → 回车并进入非激活\n")
        segmentSamples.removeAll()
        segmentStart = nil
        vad.reset()
        let pendingPaste = unpasted
        unpasted.removeAll()
        setState(.inactive)
        setStatus("已发送（按 \(hotkeyLabel) 继续输入）")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.waveformPanel.setActive(false)
            for text in pendingPaste {
                self.enqueuePaste(text)
            }
            self.pressReturnWhenPasteDrained(attempt: 0)
        }
    }

    /// 等粘贴队列里先前的内容落盘后，再发一次回车，避免回车比粘贴先到而漏发。
    private func pressReturnWhenPasteDrained(attempt: Int) {
        if !pasteBusy, pasteQueue.isEmpty {
            CrashLog.write("[\(Date())] 粘贴队列已空 → 发回车\n")
            DictationPasteBoard.pressReturn()
            return
        }
        guard attempt < 40 else {
            CrashLog.write("[\(Date())] 等待粘贴超时 → 仍发回车\n")
            DictationPasteBoard.pressReturn()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.pressReturnWhenPasteDrained(attempt: attempt + 1)
        }
    }

    private func finishIfNeeded() {
        guard isFlushing, pending == 0 else { return }
        while !unpasted.isEmpty {
            pasteNextUnpasted()
        }
        isFlushing = false
        setState(.off)
        if let lastError {
            setStatus("完成（部分失败：\(lastError)）")
        } else {
            setStatus("完成")
        }
        self.lastError = nil
        DispatchQueue.main.async { [weak self] in
            self?.waveformPanel.hide()
        }
    }

    private func pasteNextUnpasted() {
        guard !unpasted.isEmpty else { return }
        let text = unpasted.removeFirst()
        DispatchQueue.main.async { [weak self] in
            self?.enqueuePaste(text)
        }
    }

    private func enqueuePaste(_ text: String) {
        if !DictationPasteBoard.isAccessibilityTrusted {
            setStatus("需辅助功能授权才能粘贴")
        }
        pasteQueue.append(text)
        drainPasteQueue()
    }

    private func drainPasteQueue() {
        guard !pasteBusy else { return }
        pasteBusy = true
        func next() {
            if pasteQueue.isEmpty {
                pasteBusy = false
                return
            }
            let text = pasteQueue.removeFirst()
            CrashLog.write("[\(Date())] 粘贴: 「\(text)」\n")
            DictationPasteBoard.paste(text)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                next()
            }
        }
        next()
    }

    // MARK: - 连通性

    func checkConnection(completion: @escaping (Bool, String) -> Void) {
        transcriber.checkHealth(urlString: settings.sttURLString) { ok in
            DispatchQueue.main.async {
                if ok {
                    completion(true, "STT 服务连接正常")
                } else {
                    completion(false, "无法连接 STT 服务：\(self.settings.sttURLString)")
                }
            }
        }
    }

    // MARK: - 发布到主线程

    private func setState(_ newState: State) {
        guard currentState != newState else { return }
        currentState = newState
        let value = newState
        DispatchQueue.main.async { [weak self] in
            self?.state = value
        }
    }

    private func setStatus(_ text: String) {
        guard currentStatus != text else { return }
        currentStatus = text
        let value = text
        DispatchQueue.main.async { [weak self] in
            self?.statusText = value
        }
    }
}
