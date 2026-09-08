import Foundation

/// 语音输入「今日转写字数 → 节约时间」统计：激活语音每产出一段文本，就把其中
/// 不含空白的字符数计入当天；再以估算打字速度把全部历史字符折成「累计节约时间」。
/// 今日字数跨自然日清零重计，总字符与折算的节约时间跨天永久累计，供菜单栏展示。
///
/// 持久化在 UserDefaults，写入只发生在 VoiceJournal 的串行队列，读取线程安全。
enum VoiceJournalStats {
    /// 估算打字速度（字/分钟）：转写 N 字 ≈ 节约 N / 100 分钟。
    static let charsPerMinute = 100.0

    struct Snapshot {
        let todayChars: Int
        let totalChars: Int
    }

    private static let totalCharsKey = "dictation.journal.totalChars"
    private static let dayStampKey = "dictation.journal.dayStamp"
    private static let dayCharsKey = "dictation.journal.dayChars"

    private static let defaults = UserDefaults.standard

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 追加一段激活转写文本：字符数累计到当天，同时永久累计到总字符数。
    static func record(content: String) {
        let count = content.filter { !$0.isWhitespace }.count
        guard count > 0 else { return }
        let today = dayFormatter.string(from: Date())
        let storedDay = defaults.string(forKey: dayStampKey) ?? ""
        var dayChars = defaults.integer(forKey: dayCharsKey)
        if storedDay != today {
            // 跨天：今天的字数清零重计，仅总字符继续累计。
            dayChars = 0
            defaults.set(today, forKey: dayStampKey)
        }
        defaults.set(dayChars + count, forKey: dayCharsKey)
        defaults.set(defaults.integer(forKey: totalCharsKey) + count, forKey: totalCharsKey)
    }

    /// 当前快照：今日转写字数（未到过今天的自然日视为 0）与累计总字数。
    static func snapshot() -> Snapshot {
        let today = dayFormatter.string(from: Date())
        let storedDay = defaults.string(forKey: dayStampKey)
        let todayChars = storedDay == today ? defaults.integer(forKey: dayCharsKey) : 0
        return Snapshot(todayChars: todayChars, totalChars: defaults.integer(forKey: totalCharsKey))
    }

    /// 「累计节约时间」文案：不足 1 分钟显示秒，达到分钟显示分钟，达到小时显示小时，
    /// 达到天显示天（取最大两级时间单位，避免堆出一长串数字）。
    static func savedTimeText(totalChars: Int) -> String {
        let seconds = Int((Double(totalChars) * 60.0 / charsPerMinute).rounded())
        if seconds < 60 { return "\(seconds) 秒" }
        let totalMinutes = seconds / 60
        let minutesInDay = 60 * 24
        let days = totalMinutes / minutesInDay
        let hours = (totalMinutes % minutesInDay) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return hours > 0 ? "\(days) 天 \(hours) 小时" : "\(days) 天"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours) 小时 \(minutes) 分钟" : "\(hours) 小时"
        }
        return "\(minutes) 分钟"
    }
}
