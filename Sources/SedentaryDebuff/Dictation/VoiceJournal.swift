import Foundation

/// 语音日记：记录「激活状态」下语音转写并上屏/发送的那份文本（复用 DictationController
/// 的上屏转写，不重复转写），以「[yyyy-MM-dd HH:mm:ss] 内容」的形式追加到
/// ~/Desktop/语音日记/yyyy-MM-dd.txt，并同步累计今日转写字数与「节约时间」统计。
///
/// 非激活待命期不再喂音频做后台切段/转写——原先正是这条通路把环境杂音写进了日记；
/// 现在只在激活状态产出内容，提交/收尾时由 commit(activeText:) 整段落盘。录音期间每段
/// 转写落地即把未提交整段覆盖写入草稿文件，异常退出后下次启动由 recoverDraftIfNeeded()
/// 追加回日记，尽量不丢内容。全部写入在单条串行队列上维护，调用方线程只做入队，不阻塞。
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

    /// 未提交缓冲的草稿文件（位于语音日记目录下、隐藏文件名）。录音期间每段转写后
    /// 增量覆盖写入，正常提交/停止时随落盘一起删除；崩溃、断电、强杀等异常退出后，
    /// 下次启动由 recoverDraftIfNeeded() 追加回语音日记，尽量不丢已转写内容。
    private static let draftFileName = ".pending-voice.txt"

    init(settings: DictationSettings) {
        self.settings = settings
        // 启动即尝试恢复上次异常退出遗留的草稿（内部入队串行执行，不阻塞启动）。
        workQueue.async { [weak self] in
            self?.recoverDraftIfNeeded()
        }
    }

    // MARK: - 文本入口（引擎队列调用，内部入队串行执行）

    /// 提交整段缓冲：写入语音日记并清除草稿。两步在同一串行块内完成，保证正常提交
    /// 不会遗留草稿。
    func commit(activeText: String) {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.record(text: activeText)
            self.removeDraftIfExists()
        }
    }

    // MARK: - 未提交草稿（异常退出的兜底）

    /// 增量覆盖写入未提交缓冲（空串则删除草稿）。每段转写落地后调用一次，把当前
    /// 尚未提交的整段文本落盘，异常退出后损失最多只有最后一段。
    func updateDraft(_ text: String) {
        workQueue.async { [weak self] in
            self?.writeDraft(text)
        }
    }

    /// 删除草稿（缓冲被有意清空时调用，如「清空」指令或开启新一轮会话）。
    func clearDraft() {
        workQueue.async { [weak self] in
            self?.removeDraftIfExists()
        }
    }

    private func draftURL() -> URL {
        desktopDirectory()
            .appendingPathComponent(Self.folderName, isDirectory: true)
            .appendingPathComponent(Self.draftFileName)
    }

    private func writeDraft(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            removeDraftIfExists()
            return
        }
        let url = draftURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard let data = text.data(using: .utf8) else { return }
            try data.write(to: url, options: .atomic)
        } catch {
            CrashLog.write("[\(Date())] 语音草稿写入失败：\(error.localizedDescription)\n")
        }
    }

    private func removeDraftIfExists() {
        let url = draftURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            CrashLog.write("[\(Date())] 语音草稿删除失败：\(error.localizedDescription)\n")
        }
    }

    /// 启动时把上次异常退出遗留的草稿追加回语音日记（按当前时间打时间戳）后删除。
    private func recoverDraftIfNeeded() {
        let url = draftURL()
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        CrashLog.write("[\(Date())] 发现上次异常退出的语音草稿，追加到语音日记 len=\(text.count)\n")
        record(text: text)
        removeDraftIfExists()
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
