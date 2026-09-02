import AppKit
import AVFoundation
import Combine
import Foundation

final class DictationController: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case flushing
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var statusText: String = "空闲"

    let settings: DictationSettings

    private let recorder = DictationAudioRecorder()
    private let transcriber = DictationTranscriber()
    private let engineQueue = DispatchQueue(label: "dictation.engine")
    private let vad = DictationVAD(config: DictationVAD.Config())

    private var currentState: State = .idle
    private var currentStatus = "空闲"

    private var segmentSamples: [Float] = []
    private var segmentStart: Date?

    private var pending = 0
    private var isFlushing = false
    private var lastError: String?
    private var unpasted: [String] = []
    private var awaitingPermission = false

    private var pasteQueue: [String] = []
    private var pasteBusy = false

    private let waveformData = DictationWaveformData()
    private let waveformPanel: DictationWaveformPanel

    private static let minSegmentSeconds = 0.5

    init(settings: DictationSettings) {
        self.settings = settings
        waveformPanel = DictationWaveformPanel(data: waveformData)
        recorder.onBuffer = { [weak self] buffer in
            guard let self else { return }
            self.engineQueue.async {
                self.process(buffer: buffer)
            }
        }
        applyHotkey()
        waveformPanel.setActiveOpacity(settings.activeOpacity)
        waveformPanel.onWidthChange = { [weak self] width in
            self?.settings.waveformWidth = Double(width)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.waveformPanel.setWidth(CGFloat(self.settings.waveformWidth))
            self.waveformPanel.show()
            self.waveformPanel.setActive(false)
        }
    }

    func applyWaveformWidth() {
        waveformPanel.setWidth(CGFloat(settings.waveformWidth))
    }

    deinit {
        DictationHotKey.unregister()
    }

    // MARK: - 状态

    var isRecording: Bool {
        state == .recording
    }

    var isAccessibilityTrusted: Bool {
        DictationPasteBoard.isAccessibilityTrusted
    }

    // MARK: - 快捷键

    func applyHotkey() {
        DictationHotKey.register(
            keyCode: settings.hotkeyKeyCode,
            flags: settings.hotkeyFlags
        ) { [weak self] in
            self?.toggle()
        }
    }

    func applyActiveOpacity() {
        waveformPanel.setActiveOpacity(settings.activeOpacity)
        if isRecording {
            DispatchQueue.main.async { [weak self] in
                self?.waveformPanel.setActive(true)
            }
        }
    }

    // MARK: - 动作

    func toggle() {
        engineQueue.async { [weak self] in
            guard let self else { return }
            switch self.currentState {
            case .idle:
                self.requestStart()
            case .recording:
                self.stopDictation()
            case .flushing:
                break
            }
        }
    }

    func startDictation() {
        engineQueue.async { [weak self] in
            self?.requestStart()
        }
    }

    private func requestStart() {
        guard currentState == .idle, !awaitingPermission else { return }
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
                    self.beginRecording()
                } else {
                    self.setStatus("未授权麦克风，请在系统设置中允许")
                }
            }
        }
    }

    private func beginRecording() {
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
        lastError = nil
        unpasted.removeAll()
        waveformData.reset(sampleRate: recorder.sampleRate)
        setState(.recording)
        setStatus("录音中…")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.waveformPanel.setActiveOpacity(self.settings.activeOpacity)
            self.waveformPanel.setActive(true)
        }
    }

    private func stopDictation() {
        guard currentState == .recording else { return }
        isFlushing = true
        setState(.flushing)
        setStatus("正在转写…")
        recorder.stop()
        DispatchQueue.main.async { [weak self] in
            self?.waveformPanel.setActive(false)
        }
        engineQueue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.flushFinalSegment()
            self.finishIfNeeded()
        }
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
        if samples.count < minCount && !force { return }

        let wav = WAVWriter.pcm16Data(samples: samples, sampleRate: Int(recorder.sampleRate))
        pending += 1
        transcriber.transcribe(wavData: wav, urlString: settings.sttURLString) { [weak self] result in
            guard let self else { return }
            self.engineQueue.async {
                self.handleResult(result)
            }
        }
    }

    private func flushFinalSegment() {
        guard !segmentSamples.isEmpty else { return }
        finalizeSegment(force: true)
    }

    // MARK: - 转写结果

    private func handleResult(_ result: Result<String, Error>) {
        pending -= 1
        switch result {
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                unpasted.append(trimmed)
                if settings.livePaste && currentState == .recording {
                    pasteNextUnpasted()
                }
            }
        case .failure(let error):
            lastError = error.localizedDescription
            setStatus("转写失败：\(error.localizedDescription)")
        }
        finishIfNeeded()
    }

    private func finishIfNeeded() {
        guard isFlushing, pending == 0 else { return }
        while !unpasted.isEmpty {
            pasteNextUnpasted()
        }
        isFlushing = false
        setState(.idle)
        if let lastError {
            setStatus("完成（部分失败：\(lastError)）")
        } else {
            setStatus("完成")
        }
        self.lastError = nil
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
