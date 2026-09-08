import Foundation

/// 语音日记：记录「激活状态」下语音转写并上屏/发送的那份文本（复用 DictationController
/// 的上屏转写，不重复转写），以「[yyyy-MM-dd HH:mm:ss] 内容」的形式追加到
/// ~/Desktop/语音日记/yyyy-MM-dd.txt，并同步累计今日转写字数与「节约时间」统计。
///
/// 非激活待命期不再喂音频做后台切段/转写——原先正是这条通路把环境杂音写进了日记；
/// 现在只在激活状态产出一段文本时调用 append(activeText:)。全部写入在单条串行队列上
/// 维护，调用方线程只做入队，不阻塞。
final class VoiceJournal {
    private let settings: DictationSettings
    private let workQueue = DispatchQueue(label: "voicejournal.write")

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

    // MARK: - 文本入口（引擎队列调用，内部入队串行执行）

    /// 激活状态转写出的一段文本：计入节省时间统计；日记开关开启时再追加到桌面文件。
    func append(activeText: String) {
        workQueue.async { [weak self] in
            self?.record(text: activeText)
        }
    }

    private func record(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        VoiceJournalStats.record(content: trimmed)
        guard settings.journalEnabled else { return }
        writeLine(text: trimmed)
    }

    // MARK: - 写入

    private func writeLine(text: String) {
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

        let line = "[\(stamp)] \(text)\n"
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
