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
    private let cleaner = DictationCleaner()
    private let journal: VoiceJournal
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
    /// 当前片段距最大切段的剩余秒数（5…1，进入预警窗口时非 nil；engineQueue 独占访问）。
    private var cutCountdown: Int?
    /// 激活期间累积的待提交文本：只显示在光波下方，按提交键整段贴到当前光标后清空。
    /// 每段转写是一个 block，带「是否已清整理」标记：清整理时把所有未整理的 block
    /// 拉通拼在一起交给大模型处理，成功后合并回一个已整理 block，避免重复送模型。
    private var bufferBlocks: [BufferBlock] = []
    /// 清整理在途标记与请求令牌（令牌用于在停麦/清空后作废过期回调）。
    private var cleanupInFlight = false
    private var cleanupToken = 0
    /// 已请求提交：等所有在途转写（含收尾段）落地后，一次性粘贴并转非激活。
    private var commitRequested = false
    /// 语音「发送」提交后是否补一次回车。
    private var sendAfterCommit = false
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
    /// 应用退出前还原系统默认输入设备（若录音期间被我们临时切走）。
    private var terminationObserver: NSObjectProtocol?

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
    /// 距离最大切段还剩多少秒时进入预警（指示点变灰）。
    private static let cutWarningSeconds: Double = 5

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

    /// 缓冲里的一段文本：转写先以「未整理」入队，清整理成功后合并为「已整理」。
    private struct BufferBlock {
        let id: UUID
        var text: String
        var isCleaned: Bool
    }

    init(settings: DictationSettings) {
        self.settings = settings
        journal = VoiceJournal(settings: settings)
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
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.recorder.stop()
        }
        applyHotkey()
        waveformPanel.setActiveOpacity(settings.activeOpacity)
        waveformPanel.setEmptyBufferBehavior(settings.emptyBufferBehavior)
        waveformPanel.setCleanupFused(cleanupReady)
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
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
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

    /// 当前快捷键的展示名（主快捷键 + 固定的 End 键），用于待命提示文案。
    private var hotkeyLabel: String {
        let main = DictationHotKey.label(keyCode: settings.hotkeyKeyCode, flags: settings.hotkeyFlags)
        return "\(main)/\(DictationHotKey.fixedEndLabel)"
    }

    // MARK: - 快捷键 / 引擎开关

    func applyHotkey() {
        DictationHotKey.register(
            keyCode: settings.hotkeyKeyCode,
            flags: settings.hotkeyFlags
        ) { [weak self] in
            self?.toggle()
        }
        DictationHotKey.registerFixedEnd { [weak self] in
            self?.toggle()
        }
        // 固定 Home 键：清空尚未提交的缓冲文本。
        DictationHotKey.registerFixedHome { [weak self] in
            self?.clearBufferedText()
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
                self.requestCommit()
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

    /// 固定 Home 键：清空尚未提交的缓冲文本。
    func clearBufferedText() {
        engineQueue.async { [weak self] in
            self?.performClearCommand()
        }
    }

    func applyActiveOpacity() {
        waveformPanel.setActiveOpacity(settings.activeOpacity)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isInputActive else { return }
            self.waveformPanel.setActive(true)
        }
    }

    /// 菜单更改「空文本时」处理方式后调用：立即刷新面板占位/收起。
    func applyEmptyBufferBehavior() {
        waveformPanel.setEmptyBufferBehavior(settings.emptyBufferBehavior)
    }

    /// 菜单更改「清整理」配置后调用：刷新进度条两段式融合，并对尚未整理的缓冲补一次清整理。
    func applyCleanupSettings() {
        waveformPanel.setCleanupFused(cleanupReady)
        engineQueue.async { [weak self] in
            self?.scheduleCleanupIfNeeded()
        }
    }

    /// 菜单选择麦克风后调用：更新本次/下次会话要用的麦克风（nil = 跟随系统默认）。
    /// 正在监听时原地重建重启引擎，让系统默认输入切到新选设备并立即生效；
    /// 引擎未开时只记录目标，下次 start 时由 recorder 临时切换默认输入。
    func applyMicrophoneInput() {
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.recorder.setInputDevice(uid: self.settings.microphoneUID)
            guard self.currentState == .active || self.currentState == .inactive else { return }
            CrashLog.write("[\(Date())] 切换麦克风：\(self.settings.microphoneUID ?? "跟随系统默认")，原地重启引擎\n")
            self.segmentSamples.removeAll()
            self.segmentStart = nil
            self.vad.reset()
            self.recorder.rebuildEngine()
            self.recorder.resetBufferClock()
            do {
                try self.recorder.start()
                self.engineStartedAt = Date()
                self.waveformData.reset(sampleRate: self.recorder.sampleRate)
                CrashLog.write("[\(Date())] 切换麦克风后已重启引擎 state=\(self.currentState)\n")
                self.setStatus(self.currentState == .active ? "输入中…" : "待命（按 \(self.hotkeyLabel) 重新激活）")
            } catch {
                // 设备可能刚切走尚未就绪：不打断状态，健康检查会随后自动续上。
                CrashLog.write("[\(Date())] 切换麦克风后重启失败：\(error.localizedDescription)\n")
                self.setStatus("麦克风切换中，正在自动恢复…")
            }
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
        // 本次会话要用的麦克风（nil = 跟随系统默认）；start 时 recorder 据此临时切换默认输入。
        recorder.setInputDevice(uid: settings.microphoneUID)
        segmentSamples.removeAll()
        segmentStart = nil
        vad.reset()
        pending = 0
        isFlushing = false
        discardPendingOnStop = false
        lastError = nil
        commitRequested = false
        sendAfterCommit = false
        resetCleanupBookkeeping()
        clearBuffer()
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
                // 收尾：停掉可能的残留路由，把系统默认输入还原。
                recorder.stop()
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
            self.waveformPanel.setEmptyBufferBehavior(self.settings.emptyBufferBehavior)
            self.waveformPanel.setListening(true)
            self.waveformPanel.setWidth(CGFloat(self.settings.waveformWidth))
            self.waveformPanel.setCleanupFused(self.cleanupReady)
            self.waveformPanel.setTranscribing(false)
            self.waveformPanel.setCleaning(false)
            self.waveformPanel.show()
            self.waveformPanel.setActive(isActive)
        }
    }

    private func stopDictation() {
        guard currentState == .active || currentState == .inactive else { return }
        let wasActive = currentState == .active
        CrashLog.write("[\(Date())] 停止引擎：state=\(currentState)\n")
        resetEngineBookkeeping()
        commitRequested = false
        sendAfterCommit = false
        isFlushing = true
        discardPendingOnStop = !wasActive
        setState(.flushing)
        setStatus("正在收尾转写…")
        recorder.stop()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 不在这里收起 loading：由在途转写是否清空决定，收尾段转写期间继续显示。
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
        // 无论当前状态都停一次：释放可能残留的“切默认输入”路由，引擎未运行时 stop 是安全空操作。
        recorder.stop()
        guard currentState != .off else { return }
        CrashLog.write("[\(Date())] 锁屏：停止监听 state=\(currentState)\n")
        segmentSamples.removeAll()
        segmentStart = nil
        vad.reset()
        isFlushing = false
        discardPendingOnStop = true
        generation += 1 // 使锁屏前在途的转写结果失效，避免解锁后误上屏/误执行
        pending = 0
        lastError = nil
        commitRequested = false
        sendAfterCommit = false
        resetCleanupBookkeeping()
        clearBuffer()
        setState(.off)
        setStatus("空闲")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.waveformPanel.setTranscribing(false)
            self.waveformPanel.setCleaning(false)
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
            commitRequested = false
            sendAfterCommit = false
            clearBuffer()
            currentState = .off
            requestStart()
            return
        }
        CrashLog.write("[\(Date())] 状态：非激活 → 激活\n")
        segmentSamples.removeAll()
        segmentStart = nil
        vad.reset()
        updateCutCountdown(nil)
        resetCleanupBookkeeping()
        clearBuffer()
        setState(.active)
        setStatus("输入中…")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.waveformPanel.setTranscribing(false)
            self.waveformPanel.setCleaning(false)
            self.waveformPanel.setCutCountdown(nil)
            self.waveformPanel.show()
            self.waveformPanel.setActive(true)
        }
    }

    /// 激活 → 提交（语音「over」或快捷键 ⌥D/End）。先把切换前还没触发转写的尾句
    /// 强制送一次转写，等积压的在途转写全部落地后，再把整个缓冲一次性粘到当前光标，
    /// 清空缓冲并进入非激活待命。光标此刻在哪就贴到哪，避免说的时候没聚焦输入框而白说。
    private func requestCommit() {
        guard currentState == .active || currentState == .inactive else { return }
        guard !commitRequested else { return }
        CrashLog.write("[\(Date())] 请求提交：state=\(currentState)\n")
        commitRequested = true
        // loading 不在这里单独触发：统一由「是否有在途转写」驱动（见 finalizeSegment /
        // handleResult），因此 VAD 切片与收尾段都能在波形右侧显示转写进行中。
        flushFinalSegment()
        tryFinishCommit()
    }

    /// 主线程更新面板的「转写进行中」loading：只要还有在途转写就显示，全部返回即消失。
    private func setTranscribing(_ transcribing: Bool, estimatedDuration: TimeInterval? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.waveformPanel.setTranscribing(transcribing, estimatedDuration: estimatedDuration)
        }
    }

    /// 主线程更新面板的「清整理进行中」loading（第二阶段）。
    private func setCleaning(_ cleaning: Bool, estimatedDuration: TimeInterval? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.waveformPanel.setCleaning(cleaning, estimatedDuration: estimatedDuration)
        }
    }

    /// 由音频时长估算一段转写的预计耗时（秒）：固定开销 + 与音频长度成正比的部分。
    /// 只用于 loading 进度条的缓动曲线，估不准也无妨（结果返回时统一拉到 100%）。
    private static func estimatedTranscribeSeconds(audioSeconds: Double) -> TimeInterval {
        let fixedOverhead: TimeInterval = 0.8
        let perAudioSecond: TimeInterval = 0.10
        return fixedOverhead + max(0, audioSeconds) * perAudioSecond
    }

    /// 由待整理文本长度估算清整理耗时（秒）：固定开销 + 与字数成正比的部分。
    private static func estimatedCleanSeconds(characters: Int) -> TimeInterval {
        let fixedOverhead: TimeInterval = 1.2
        let perCharacter: TimeInterval = 0.03
        return fixedOverhead + Double(max(0, characters)) * perCharacter
    }

    /// 在途转写全部返回、且待整理文本都已清整理后执行提交（由 handleResult /
    /// handleCleanupResult 在条件满足时调用）。
    private func tryFinishCommit() {
        guard commitRequested, pending == 0 else { return }
        if cleanupPending {
            scheduleCleanupIfNeeded()
            if cleanupInFlight { return }
            // 未配置或请求已结束仍有残留：放弃等待，直接按原文提交。
            markAllBlocksCleaned()
        }
        finishCommit()
    }

    private func finishCommit() {
        commitRequested = false
        segmentSamples.removeAll()
        segmentStart = nil
        vad.reset()
        resetCleanupBookkeeping()
        // 取出并清空缓冲：整段文本先贴到当前光标，随后光波下方的文本区清空，
        // 避免提交后旧内容一直留在面板上。
        let text = takeBufferText()
        let shouldSend = sendAfterCommit
        sendAfterCommit = false
        setState(.inactive)
        setStatus("待命（按 \(hotkeyLabel) 重新激活）")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 顺序：先收起 loading（波形复位），再切非激活灰，最后把文本贴进当前输入框。
            self.waveformPanel.setTranscribing(false)
            self.waveformPanel.setCleaning(false)
            self.waveformPanel.setActive(false)
            if !text.isEmpty {
                self.enqueuePaste(text)
            }
            if shouldSend {
                self.pressReturnWhenPasteDrained(attempt: 0)
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
        recorder.stop()
        segmentSamples.removeAll()
        segmentStart = nil
        vad.reset()
        isFlushing = false
        discardPendingOnStop = true
        generation += 1
        pending = 0
        lastError = nil
        commitRequested = false
        sendAfterCommit = false
        resetCleanupBookkeeping()
        clearBuffer()
        setState(.off)
        setStatus("麦克风不可用，语音输入已停止（可稍后重新开始）")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.waveformPanel.setTranscribing(false)
            self.waveformPanel.setCleaning(false)
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
        // 非激活待命只驱动波形：不做上屏切段/STT 转写，也不喂给语音日记，
        // 避免把待命期环境杂音后台转写进日记。
        guard currentState == .active else { return }
        segmentSamples.append(contentsOf: samples)
        if segmentStart == nil {
            segmentStart = Date()
        }

        let now = Date()
        // 临近最大切段（倒计时剩 5 秒）时显示倒计时数字，提示即将强制切时间片。
        if let start = segmentStart {
            let remaining = settings.maxSegmentSeconds - now.timeIntervalSince(start)
            if settings.maxSegmentSeconds > Self.cutWarningSeconds, remaining <= Self.cutWarningSeconds {
                updateCutCountdown(max(1, Int(ceil(remaining))))
            } else {
                updateCutCountdown(nil)
            }
        }
        let rms = Self.rms(samples: samples)
        if vad.feed(rms: rms, at: now.timeIntervalSinceReferenceDate, silenceSeconds: settings.pauseSilenceSeconds) {
            finalizeSegment(force: false)
            return
        }
        if let start = segmentStart, now.timeIntervalSince(start) >= settings.maxSegmentSeconds {
            finalizeSegment(force: false)
        }
    }

    /// 更新「临近最大切段」倒计时秒数（engineQueue 上调用，仅在变化时推主线程）。
    private func updateCutCountdown(_ seconds: Int?) {
        guard cutCountdown != seconds else { return }
        cutCountdown = seconds
        DispatchQueue.main.async { [weak self] in
            self?.waveformPanel.setCutCountdown(seconds)
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
        updateCutCountdown(nil)

        guard !samples.isEmpty else { return }
        let minCount = Int(recorder.sampleRate * Self.minSegmentSeconds)
        if samples.count < minCount && !force {
            CrashLog.write("[\(Date())] 段落过短被丢弃 samples=\(samples.count)/\(minCount)\n")
            return
        }

        let wav = WAVWriter.pcm16Data(samples: samples, sampleRate: Int(recorder.sampleRate))
        let gen = generation
        pending += 1
        // 有在途转写：波形区铺满转译进度条，直到结果返回。进度条按本段音频时长伸缩，
        // VAD 切片同样触发，借此可观察切片时机与该段转写耗时。
        let audioSeconds = recorder.sampleRate > 0 ? Double(samples.count) / recorder.sampleRate : 0
        setTranscribing(true, estimatedDuration: Self.estimatedTranscribeSeconds(audioSeconds: audioSeconds))
        transcriber.transcribe(wavData: wav, urlString: settings.sttURLString) { [weak self] result in
            guard let self else { return }
            self.engineQueue.async {
                self.handleResult(result, generation: gen)
            }
        }
    }

    private func flushFinalSegment() {
        guard !segmentSamples.isEmpty else { return }
        // 停顿触发切段后，残留的收尾段通常只是尾随静音。若能量极低还发去转写，
        // 提交/发送就得白等一个 STT 网络往返（约 1 秒）才粘贴，手感发滞。
        let peak = segmentSamples.reduce(Float(0)) { max($0, abs($1)) }
        CrashLog.write("[\(Date())] 收尾段 samples=\(segmentSamples.count) peak=\(peak)\n")
        if peak < Self.silencePeakThreshold {
            CrashLog.write("[\(Date())] 收尾段近乎静音，跳过转写\n")
            segmentSamples.removeAll()
            return
        }
        finalizeSegment(force: true)
    }

    /// 收尾段判定为「静音可跳过」的峰值门限，明显低于正常说话电平。
    private static let silencePeakThreshold: Float = 0.01

    // MARK: - 转写结果

    /// 清理转写文本首尾无意义的空白，但保留句尾用于段间分段的换行：
    /// 服务端在每个转写结果末尾追加空行（"\n\n"），让连续几句粘贴后读成独立段落；
    /// 若按旧的整段 trim 把句尾换行一并裁掉，句与句之间就会黏成一段。
    private func cleanedTranscribedText(_ text: String) -> String {
        let base = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return "" }
        var trailingNewlines = 0
        for character in text.reversed() {
            guard character.isNewline else { break }
            trailingNewlines += 1
        }
        return base + String(repeating: "\n", count: trailingNewlines)
    }

    private func handleResult(_ result: Result<String, Error>, generation gen: Int) {
        // 过期代数（锁屏停麦/重启引擎前的转写）一律丢弃，避免误上屏或误执行指令。
        guard gen == generation else {
            CrashLog.write("[\(Date())] 丢弃过期转写（gen \(gen) != \(generation)）\n")
            return
        }
        pending -= 1
        // 所有在途转写都返回后才收起右侧 loading：loading 时长即该段转写耗时。
        if pending == 0 {
            setTranscribing(false)
        }
        switch result {
        case .success(let text):
            let cleaned = cleanedTranscribedText(text)
            CrashLog.write("[\(Date())] 转写结果: 「\(cleaned)」 state=\(currentState)\n")
            if !cleaned.isEmpty {
                handleTranscribed(cleaned)
            }
        case .failure(let error):
            lastError = error.localizedDescription
            setStatus("转写失败：\(error.localizedDescription)")
        }
        tryFinishCommit()
        finishIfNeeded()
    }

    /// 按当前状态决定一段转写文本的去向：激活期间只累积到缓冲，提交时才整段上屏。
    private func handleTranscribed(_ text: String) {
        switch currentState {
        case .active, .inactive:
            if let match = Self.detectCommand(text) {
                // 「发送」贴在句子末尾命中时，先把命令词前面的正文加入缓冲，
                // 提交流程会把缓冲内容整体粘贴后统一回车。
                if let body = match.body {
                    appendBuffer(body)
                    journal.append(activeText: body)
                }
                perform(match.command)
            } else {
                appendBuffer(text)
                journal.append(activeText: text)
            }
        case .flushing:
            // 从激活停止时收尾的文本仍要落盘；从非激活停止时丢弃待命期间的转写。
            if !discardPendingOnStop {
                appendBuffer(text)
                journal.append(activeText: text)
            }
        case .off:
            break
        }
    }

    // MARK: - 缓冲

    /// 追加一段转写文本到面板缓冲（同段落内的换行保留，首尾空行裁掉）。
    /// 未启用/未配置清整理时直接标记为已整理，避免积压待整理文本。
    private func appendBuffer(_ text: String) {
        let line = text.trimmingCharacters(in: .newlines)
        guard !line.isEmpty else { return }
        bufferBlocks.append(BufferBlock(id: UUID(), text: line, isCleaned: !cleanupReady))
        updateBufferUI()
        scheduleCleanupIfNeeded()
    }

    /// 取出并清空缓冲文本：各段以换行拼接后整段粘贴，保持逐句成行。
    private func takeBufferText() -> String {
        let text = bufferBlocks.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
        clearBuffer()
        return text
    }

    private func clearBuffer() {
        bufferBlocks.removeAll()
        // 缓冲已清空：作废在途清整理，避免过期结果落回新缓冲。
        resetCleanupBookkeeping()
        updateBufferUI()
    }

    private func updateBufferUI() {
        let lines = bufferBlocks.map(\.text)
        DispatchQueue.main.async { [weak self] in
            self?.waveformPanel.setBuffer(lines)
        }
    }

    // MARK: - 清整理（大模型）

    /// 清整理是否已启用且配置完整（有 Key）。
    private var cleanupReady: Bool {
        settings.cleanupEnabled && !settings.cleanupAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 是否还有未整理的缓冲文本。
    private var hasUncleanedBlocks: Bool {
        bufferBlocks.contains { !$0.isCleaned }
    }

    /// 是否仍在等待清整理落地（提交/停止时需等待，保证粘贴出去的是整理后的文本）。
    private var cleanupPending: Bool {
        cleanupReady && (cleanupInFlight || hasUncleanedBlocks)
    }

    private func cleanupConfiguration() -> DictationCleaner.Configuration {
        DictationCleaner.Configuration(
            urlString: settings.cleanupURLString,
            apiKey: settings.cleanupAPIKey,
            model: settings.cleanupModel
        )
    }

    /// 待整理文本之外，额外带给大模型的「上文」字符上限（注意是字符，不是 token）。
    /// 只取已整理前文的最后 500 个字，足以理解被切断处的语境，又不会让成本随会话变长而膨胀。
    private static let cleanupContextCharacterLimit = 500

    /// 带上下文地整理尚未处理的 block：把已整理的前文（截取最后 500 字）作为【上文】
    /// 一并送出，让被切断的新段能借助语境纠正；返回后只替换这批未整理的 block，前文不动。
    /// 请求在途时新到的段落留到下一轮一起带上。
    private func scheduleCleanupIfNeeded() {
        guard cleanupReady, !cleanupInFlight else { return }
        let dirty = bufferBlocks.filter { !$0.isCleaned }
        guard !dirty.isEmpty else { return }

        let context = Self.cleanupContext(
            from: bufferBlocks.filter { $0.isCleaned }.map(\.text)
        )
        let ids = dirty.map(\.id)
        let joined = dirty.map(\.text).joined(separator: "\n")
        cleanupToken += 1
        let token = cleanupToken
        cleanupInFlight = true
        setCleaning(true, estimatedDuration: Self.estimatedCleanSeconds(characters: joined.count + context.count))
        let gen = generation
        cleaner.clean(text: joined, context: context, configuration: cleanupConfiguration()) { [weak self] result in
            guard let self else { return }
            self.engineQueue.async {
                self.handleCleanupResult(result, originalText: joined, ids: ids, generation: gen, token: token)
            }
        }
    }

    /// 取已整理前文的最后若干**字符**作为上文（按字符计数，非 token）。
    private static func cleanupContext(from cleanedTexts: [String]) -> String {
        guard !cleanedTexts.isEmpty else { return "" }
        let joined = cleanedTexts.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return "" }
        if joined.count <= cleanupContextCharacterLimit { return joined }
        return String(joined.suffix(cleanupContextCharacterLimit))
    }

    /// 清整理返回：成功后用整理文本替换被送整理的那批 block，失败则保留原文并标记，
    /// 避免同一段文本反复重试；随后补跑在途期间新到的未整理 block，并推进提交流程。
    private func handleCleanupResult(
        _ result: Result<String, Error>,
        originalText: String,
        ids: [UUID],
        generation gen: Int,
        token: Int
    ) {
        if token == cleanupToken {
            cleanupInFlight = false
        }
        setCleaning(false)
        guard gen == generation else {
            CrashLog.write("[\(Date())] 丢弃过期清整理结果（gen \(gen) != \(generation)）\n")
            return
        }
        switch result {
        case .success(let cleaned):
            let value = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty || Self.looksLikeNonRewrite(original: originalText, cleaned: value) {
                // 模型没在整理（例如把「修改」当成指令反问用户），保留原始转写，绝不把
                // 这类内容替换进缓冲。
                if !value.isEmpty {
                    CrashLog.write("[\(Date())] 清整理疑似非改写，保留原文：「\(value)」\n")
                }
                markBlocksCleaned(ids)
            } else {
                replaceBlocks(ids, with: value)
            }
        case .failure(let error):
            CrashLog.write("[\(Date())] 清整理失败：\(error.localizedDescription)\n")
            setStatus("清整理失败，已保留原文：\(error.localizedDescription)")
            markBlocksCleaned(ids)
        }
        updateBufferUI()
        scheduleCleanupIfNeeded()
        tryFinishCommit()
        finishIfNeeded()
    }

    /// 判断模型返回的是否明显不是「校对改写」。清整理只会做等长左右的替换，若输入是
    /// 很短的词/口令（如「修改」「翻译」）而输出明显变长，通常是模型把它当指令来回答，
    /// 此时应保留原始转写。
    private static func looksLikeNonRewrite(original: String, cleaned: String) -> Bool {
        let inputCount = original.count
        let outputCount = cleaned.count
        guard inputCount > 0 else { return false }
        if inputCount <= 4 && outputCount > inputCount + 2 { return true }
        let metaMarkers = ["请提供", "请发送", "需要校对", "未提供", "没有提供", "请把需要"]
        if inputCount <= 12, outputCount > inputCount + 4, metaMarkers.contains(where: { cleaned.contains($0) }) {
            return true
        }
        return false
    }

    /// 用整理后的文本替换被送整理的那批 block（合并为一个已整理 block）。
    /// 断句续写优化：这批新段紧跟在已整理前文之后，且前文没有句末标点时，说明上一句
    /// 被 ASR 切断了——把整理结果直接续写到前文末尾（不换行），避免句子中间多出换行。
    private func replaceBlocks(_ ids: [UUID], with text: String) {
        let idSet = Set(ids)
        guard let insertAt = bufferBlocks.firstIndex(where: { idSet.contains($0.id) }) else { return }

        if insertAt > 0,
           !text.contains("\n"),
           !Self.startsWithListMarker(text),
           bufferBlocks[insertAt - 1].isCleaned,
           !Self.hasTerminalPunctuation(bufferBlocks[insertAt - 1].text) {
            bufferBlocks[insertAt - 1].text += text
            bufferBlocks.removeAll { idSet.contains($0.id) }
            return
        }

        bufferBlocks.removeAll { idSet.contains($0.id) }
        let index = min(insertAt, bufferBlocks.count)
        bufferBlocks.insert(BufferBlock(id: UUID(), text: text, isCleaned: true), at: index)
    }

    /// 文本是否以句末/分句标点结尾（用于判断上一句是否已经说完）。
    private static func hasTerminalPunctuation(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return "。！？!?；;：:…".contains(last)
    }

    /// 整理结果是否以列表标记开头（如「1.」「1、」「- 」「•」）；是则不并入上一段。
    private static func startsWithListMarker(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return false }
        if first == "-" || first == "*" || first == "•" || first == "·" { return true }
        var index = trimmed.startIndex
        var digits = 0
        while index < trimmed.endIndex, trimmed[index].isNumber {
            digits += 1
            index = trimmed.index(after: index)
        }
        guard digits > 0, index < trimmed.endIndex else { return false }
        return [".", "、", ")", "）", "．"].contains(trimmed[index])
    }

    private func markBlocksCleaned(_ ids: [UUID]) {
        let idSet = Set(ids)
        for index in bufferBlocks.indices where idSet.contains(bufferBlocks[index].id) {
            bufferBlocks[index].isCleaned = true
        }
    }

    private func markAllBlocksCleaned() {
        for index in bufferBlocks.indices {
            bufferBlocks[index].isCleaned = true
        }
    }

    /// 作废在途清整理请求（停麦/提交/清空缓冲时调用），避免过期回调改动新会话缓冲。
    private func resetCleanupBookkeeping() {
        cleanupToken += 1
        cleanupInFlight = false
    }

    /// 语音指令识别：整段转写文本去掉首尾空白、标点并忽略大小写后，恰好等于某个指令词。
    /// 「发送」和「清空/clear」例外：允许贴在句子末尾——去掉 STT 自动追加的尾随标点后，
    /// 末两字为「发送」即视为发送指令（前面的正文作为 body 随发送一起上屏）；末尾为
    /// 「清空/clear」即视为清空指令（不必单独说一个词，前面的正文一律丢弃不上屏）。
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
        if normalized.hasSuffix("清空") || normalized.hasSuffix("clear") {
            return CommandMatch(command: .clear, body: nil)
        }
        guard normalized.hasSuffix("发送") else { return nil }
        // 用原文取「发送」前的正文，保留原始大小写与内部标点，避免把正文转成小写。
        return CommandMatch(command: .send, body: originalBody(in: text, commandLength: 2))
    }

    /// 从原文首尾去空白/标点后，取命令词前面的正文（保留原始大小写）。
    private static func originalBody(in text: String, commandLength: Int) -> String? {
        let trimSet = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let trimmed = text.trimmingCharacters(in: trimSet)
        guard trimmed.count > commandLength else { return nil }
        let body = String(trimmed.dropLast(commandLength)).trimmingCharacters(in: trimSet)
        return body.isEmpty ? nil : body
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
            requestCommit()
        case .send:
            performSendCommand()
        case .deleteWord:
            performDeleteWordCommand()
        case .clear:
            performClearCommand()
        }
    }

    /// 识别到「清空/clear」指令：清空 debuff 缓冲区里尚未提交的文本，继续输入。
    private func performClearCommand() {
        CrashLog.write("[\(Date())] 指令：清空 → 清空缓冲区 blocks=\(bufferBlocks.count) state=\(currentState)\n")
        clearBuffer()
    }

    /// 识别到「删除/撤销」指令：在当前焦点按一次 ⌥⌫ 删除一个词，继续输入。
    private func performDeleteWordCommand() {
        CrashLog.write("[\(Date())] 指令：删除/撤销 → 主线程发 ⌥⌫ state=\(currentState)\n")
        DispatchQueue.main.async {
            DictationPasteBoard.pressDeleteWord()
            CrashLog.write("[\(Date())] 已调用 pressDeleteWord\n")
        }
    }

    /// 识别到「发送」指令：把缓冲整段粘贴到当前光标后发一次回车，并进入非激活待命。
    /// 先请求提交（等收尾段落地、一次性粘贴），队列清空后再补回车。
    private func performSendCommand() {
        guard currentState == .active || currentState == .inactive else { return }
        guard !commitRequested else { return }
        CrashLog.write("[\(Date())] 指令：发送 → 提交粘贴后回车\n")
        sendAfterCommit = true
        requestCommit()
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
        if cleanupPending {
            scheduleCleanupIfNeeded()
            if cleanupInFlight { return }
            // 未配置或请求已结束仍有残留：放弃等待，直接按原文落盘。
            markAllBlocksCleaned()
        }
        // 停止引擎时，把缓冲里还没提交的内容整段落盘，避免没按键就停麦导致白说。
        let text = takeBufferText()
        isFlushing = false
        resetCleanupBookkeeping()
        setState(.off)
        if let lastError {
            setStatus("完成（部分失败：\(lastError)）")
        } else {
            setStatus("完成")
        }
        self.lastError = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.waveformPanel.setTranscribing(false)
            self.waveformPanel.setCleaning(false)
            if !text.isEmpty {
                self.enqueuePaste(text)
            }
            self.waveformPanel.hide()
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

    func checkCleanupConnection(completion: @escaping (Bool, String) -> Void) {
        cleaner.checkHealth(configuration: cleanupConfiguration(), completion: completion)
    }

    // MARK: - 发布到主线程

    private func setState(_ newState: State) {
        guard currentState != newState else { return }
        currentState = newState
        // 离开激活态即撤销切段预警，避免残留的灰点提示。
        if newState != .active {
            updateCutCountdown(nil)
        }
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
