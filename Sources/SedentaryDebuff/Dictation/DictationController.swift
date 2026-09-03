import AppKit
import AVFoundation
import Combine
import Foundation

final class DictationController: ObservableObject {
    enum State: Equatable {
        case off       // 引擎关闭：麦克风未开启（空闲，控件隐藏）
        case active    // 激活：语音上屏，删除/清空/over/发送等指令生效
        case inactive  // 非激活：常驻待命监听，语音不上屏，仅「输入」可唤醒
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
    /// 引擎代数：每启动一次监听自增，过期转写结果按代数丢弃，避免跨会话串扰。
    private var generation = 0
    /// 锁屏时若在监听，记录解锁后要恢复的模式。
    private var shouldRestoreAfterUnlock = false
    private var restoreModeOnUnlock: State = .inactive

    private var pasteQueue: [String] = []
    private var pasteBusy = false
    /// 引擎因输入/输出硬件变化（切换麦克风等）自行 stop 时回调，用于原地续麦。
    private var engineConfigChangeObserver: NSObjectProtocol?

    private let waveformData = DictationWaveformData()
    private let waveformPanel: DictationWaveformPanel

    private static let minSegmentSeconds = 0.5

    /// 识别到的语音指令：每条指令对应一个固定动作。
    private enum VoiceCommand {
        case activate    // 「输入」：非激活 → 激活
        case deactivate  // 「over」：激活 → 非激活
        case send        // 「发送」：回车发送 + 切到非激活
        case deleteWord  // 「删除/撤销」
        case clear       // 「清空/clear」
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
            object: recorder.audioEngine,
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
    }

    func applyWaveformWidth() {
        waveformPanel.setWidth(CGFloat(settings.waveformWidth))
    }

    deinit {
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
        recorder.requestPermission { [weak self] granted in
            guard let self else { return }
            self.engineQueue.async {
                self.awaitingPermission = false
                if granted {
                    self.beginRecording(mode: initialMode)
                } else {
                    self.setStatus("未授权麦克风，请在系统设置中允许")
                }
            }
        }
    }

    private func beginRecording(mode: State = .active) {
        do {
            try recorder.start()
        } catch {
            setStatus("启动麦克风失败：\(error.localizedDescription)")
            return
        }
        segmentSamples.removeAll()
        segmentStart = nil
        vad.reset()
        pending = 0
        isFlushing = false
        discardPendingOnStop = false
        lastError = nil
        unpasted.removeAll()
        generation += 1
        waveformData.reset(sampleRate: recorder.sampleRate)
        let initial = mode == .active ? State.active : .inactive
        setState(initial)
        setStatus(initial == .active ? "输入中…" : "待命中（说「输入/激活」开始）")
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
                // 非激活停麦：待命期间说的话本就无意上屏，直接丢弃残留段。
                self.segmentSamples.removeAll()
                self.segmentStart = nil
                self.vad.reset()
            }
            self.finishIfNeeded()
        }
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
    private func stopForScreenLock() {
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

    /// 非激活 → 激活（语音「输入」或快捷键）。
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
        setStatus("待命中（说「输入/激活」开始）")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.waveformPanel.setActive(false)
            for text in pendingPaste {
                self.enqueuePaste(text)
            }
        }
    }

    // MARK: - 硬件变化（切换输入设备）

    /// 输入/输出硬件变化（如切换麦克风）时引擎被系统自行 stop，inputNode 上残留旧 tap。
    /// 非关闭态下按原状态原地续麦，避免下一次启动时 installTap 撞上残留 tap 而崩溃。
    private func handleEngineConfigurationChange() {
        guard currentState == .active || currentState == .inactive else { return }
        CrashLog.write("[\(Date())] 输入设备变化：引擎被系统停止，原地续麦 state=\(currentState)\n")
        segmentSamples.removeAll()
        segmentStart = nil
        vad.reset()
        do {
            try recorder.start()
        } catch {
            CrashLog.write("[\(Date())] 输入设备变化后重启麦克风失败：\(error.localizedDescription)\n")
            currentState = .off
            setState(.off)
            setStatus("切换输入设备后重启麦克风失败：\(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.waveformPanel.setActive(false)
                self.waveformPanel.setListening(false)
                self.waveformPanel.hide()
            }
            return
        }
        waveformData.reset(sampleRate: recorder.sampleRate)
    }

    // MARK: - 音频处理

    private func process(buffer: AVAudioPCMBuffer) {
        let samples = readSamples(buffer)
        guard !samples.isEmpty else { return }
        segmentSamples.append(contentsOf: samples)
        waveformData.append(samples)
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

    /// 按当前状态决定一段转写文本的去向：激活才上屏/执行指令；非激活只识别「输入」。
    private func handleTranscribed(_ text: String) {
        switch currentState {
        case .active:
            if let command = Self.detectCommand(text) {
                perform(command)
            } else {
                unpasted.append(text)
                if settings.livePaste {
                    pasteNextUnpasted()
                }
            }
        case .inactive:
            // 非激活：普通语音不上屏；仅唤醒词（输入/激活）可重新激活。
            if Self.isActivateUtterance(text) {
                setVoiceActive()
            }
        case .flushing:
            // 从激活停止时收尾的文本仍要落盘；从非激活停止时丢弃待命期间的转写。
            if !discardPendingOnStop {
                unpasted.append(text)
            }
        case .off:
            break
        }
    }

    /// 整段转写文本去掉首尾空白、标点并忽略大小写后，恰好等于某个指令词。
    private static func detectCommand(_ text: String) -> VoiceCommand? {
        switch normalizedCommand(text) {
        case "输入", "激活":
            return .activate
        case "over":
            return .deactivate
        case "发送":
            return .send
        case "删除", "撤销":
            return .deleteWord
        case "清空", "clear":
            return .clear
        default:
            return nil
        }
    }

    private static func normalizedCommand(_ text: String) -> String {
        text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
    }

    /// 非激活时的唤醒判断：单独说出「输入/激活」即可，也容忍 STT 偶发把语气词或周边字并进来。
    private static func isActivateUtterance(_ text: String) -> Bool {
        let normalized = normalizedCommand(text)
        if normalized == "输入" || normalized == "激活" {
            return true
        }
        // STT 合并噪声（如「西湖输入」「激活一下」）：内容较短且含唤醒词也算命中。
        guard normalized.count <= 6 else { return false }
        return normalized.contains("输入") || normalized.contains("激活")
    }

    /// 执行识别到的指令（仅激活状态会走到这里）。
    private func perform(_ command: VoiceCommand) {
        switch command {
        case .activate:
            break // 已在激活，忽略
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
        setStatus("已发送（待命）")
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
