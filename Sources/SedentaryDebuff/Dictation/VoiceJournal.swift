import Foundation

/// 语音日记：麦克风监听期间（引擎开启），把说过的话按 VAD 切片转写，以
/// 「[yyyy-MM-dd HH:mm:ss] 内容」的形式追加到 ~/Desktop/语音日记/yyyy-MM-dd.txt。
///
/// 激活状态由 DictationController 复用上屏转写调用 append(activeText:)（不重复转写）；
/// 非激活待命状态由 append(samples:) 独立做 VAD 切段 + 转写（原本待命期不做任何识别）。
/// 全部状态都在单条串行队列 workQueue 上维护，引擎音频回调只做入队，不阻塞。
final class VoiceJournal {
    private let settings: DictationSettings
    private let transcriber = DictationTranscriber()
    private let workQueue = DispatchQueue(label: "voicejournal.write")
    private let vad = DictationVAD(config: DictationVAD.Config())

    private var segmentSamples: [Float] = []
    private var segmentSampleRate: Double = 16000
    private var segmentStart: Date?

    /// 会话代数：每次引擎开启自增，作废跨会话在途的独立转写，避免写进新会话的脏内容。
    private var generation = 0

    private static let minSegmentSeconds = 0.5

    private static let folderName = "语音日记"
    private static let fileDateFormat = "yyyy-MM-dd"
    private static let stampFormat = "yyyy-MM-dd HH:mm:ss"

    private let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = VoiceJournal.fileDateFormat
        return f
    }()

    private let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = VoiceJournal.stampFormat
        return f
    }()

    init(settings: DictationSettings) {
        self.settings = settings
    }

    // MARK: - 会话生命周期（引擎队列调用，内部入队串行执行）

    /// 引擎开启：作废上一个会话残留的在途转写。
    func startSession() {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.generation += 1
            self.resetSegment()
        }
    }

    /// 引擎停止 / 锁屏停麦：把还没切段的尾句强制送一次转写，让整句话都能落盘。
    /// 已送出、仍在途的转写结果不在此作废（它们属于刚结束的这段会话）。
    func stopSession() {
        workQueue.async { [weak self] in
            self?.finalize(force: true)
        }
    }

    /// 非激活 → 激活瞬间：先把切换前已经说出来的尾句强制落盘，避免丢话。
    func flushPartial() {
        workQueue.async { [weak self] in
            self?.finalize(force: true)
        }
    }

    // MARK: - 音频 / 文本入口（引擎队列调用）

    /// 非激活待命期的原始音频：内部按 VAD 停顿/最大时长切段并转写。
    func append(samples: [Float], sampleRate: Double) {
        workQueue.async { [weak self] in
            guard let self, self.settings.journalEnabled else { return }
            self.feedSamples(samples, sampleRate: sampleRate)
        }
    }

    /// 激活状态复用上屏转写：直接把已转写好的文本写入日记，不再转一遍。
    func append(activeText: String) {
        workQueue.async { [weak self] in
            guard let self, self.settings.journalEnabled else { return }
            self.writeLine(text: activeText)
        }
    }

    // MARK: - 待命期独立切段

    private func feedSamples(_ newSamples: [Float], sampleRate: Double) {
        guard !newSamples.isEmpty else { return }
        if segmentSamples.isEmpty {
            segmentSampleRate = sampleRate
        }
        segmentSamples.append(contentsOf: newSamples)
        if segmentStart == nil {
            segmentStart = Date()
        }

        let now = Date()
        let rms = Self.rms(samples: newSamples)
        if vad.feed(rms: rms, at: now.timeIntervalSinceReferenceDate, silenceSeconds: settings.pauseSilenceSeconds) {
            finalize(force: false)
            return
        }
        if let start = segmentStart, now.timeIntervalSince(start) >= settings.maxSegmentSeconds {
            finalize(force: false)
        }
    }

    private func finalize(force: Bool) {
        let samples = segmentSamples
        let sampleRate = segmentSampleRate
        resetSegment()
        guard settings.journalEnabled, !samples.isEmpty else { return }

        let minCount = Int(sampleRate * Self.minSegmentSeconds)
        if samples.count < minCount && !force {
            return
        }

        let wav = WAVWriter.pcm16Data(samples: samples, sampleRate: Int(sampleRate))
        let gen = generation
        transcriber.transcribe(wavData: wav, urlString: settings.sttURLString) { [weak self] result in
            guard let self else { return }
            self.workQueue.async {
                // 会话已切换（引擎重开）才丢弃；会话内停止不丢，让结尾几段照常落盘。
                guard gen == self.generation, self.settings.journalEnabled else { return }
                switch result {
                case .success(let text):
                    self.writeLine(text: text)
                case .failure(let error):
                    CrashLog.write("[\(Date())] 语音日记转写失败：\(error.localizedDescription)\n")
                }
            }
        }
    }

    private func resetSegment() {
        segmentSamples.removeAll()
        segmentSampleRate = 16000
        segmentStart = nil
        vad.reset()
    }

    private static func rms(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return sqrt(sum / Float(samples.count))
    }

    // MARK: - 写入

    private func writeLine(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let now = Date()
        let day = fileDateFormatter.string(from: now)
        let stamp = stampFormatter.string(from: now)
        let directory = desktopDirectory().appendingPathComponent(Self.folderName, isDirectory: true)
        let file = directory.appendingPathComponent("\(day).txt")

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            CrashLog.write("[\(Date())] 语音日记建目录失败：\(error.localizedDescription)\n")
            return
        }

        let line = "[\(stamp)] \(trimmed)\n"
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: file.path) {
            guard let handle = try? FileHandle(forWritingTo: file) else {
                CrashLog.write("[\(Date())] 语音日记打不开文件：\(file.path)\n")
                return
            }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            do {
                try data.write(to: file, options: .atomic)
            } catch {
                CrashLog.write("[\(Date())] 语音日记写文件失败：\(error.localizedDescription)\n")
            }
        }
    }

    private func desktopDirectory() -> URL {
        if let url = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            return url
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop", isDirectory: true)
    }
}
