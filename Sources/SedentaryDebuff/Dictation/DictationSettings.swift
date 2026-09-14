import Carbon.HIToolbox
import Combine
import Foundation

final class DictationSettings: ObservableObject {
    @Published var sttURLString: String {
        didSet { UserDefaults.standard.set(sttURLString, forKey: Self.sttURLKey) }
    }

    @Published var hotkeyKeyCode: UInt32 {
        didSet { UserDefaults.standard.set(NSNumber(value: hotkeyKeyCode), forKey: Self.hotkeyKeyCodeKey) }
    }

    @Published var hotkeyFlags: UInt32 {
        didSet { UserDefaults.standard.set(NSNumber(value: hotkeyFlags), forKey: Self.hotkeyFlagsKey) }
    }

    @Published var pauseSilenceSeconds: Double {
        didSet { UserDefaults.standard.set(pauseSilenceSeconds, forKey: Self.pauseSilenceKey) }
    }

    @Published var maxSegmentSeconds: Double {
        didSet { UserDefaults.standard.set(maxSegmentSeconds, forKey: Self.maxSegmentKey) }
    }

    @Published var activeOpacity: Double {
        didSet { UserDefaults.standard.set(activeOpacity, forKey: Self.activeOpacityKey) }
    }

    @Published var waveformWidth: Double {
        didSet { UserDefaults.standard.set(waveformWidth, forKey: Self.waveformWidthKey) }
    }

    /// 选中的麦克风 uid；nil = 跟随系统当前默认输入设备。仅录音期间临时生效。
    @Published var microphoneUID: String? {
        didSet {
            if let microphoneUID {
                UserDefaults.standard.set(microphoneUID, forKey: Self.microphoneKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.microphoneKey)
            }
        }
    }

    /// 语音日记：开启后，激活语音转写并上屏/发送的内容会追加到 ~/Desktop/语音日记/当天日期.txt；
    /// 非激活待命不后台录音转写。今日转写字数/累计节约时间统计与开关无关，始终累计。
    @Published var journalEnabled: Bool {
        didSet { UserDefaults.standard.set(journalEnabled, forKey: Self.journalEnabledKey) }
    }

    /// 缓冲为空时文本框与按钮的处理方式。
    enum EmptyBufferBehavior: String, CaseIterable {
        /// 保留文本框与按钮，仅以非激活（降低透明度）状态呈现。
        case inactive
        /// 收起文本框与按钮，只保留波形。
        case collapse
    }

    @Published var emptyBufferBehavior: EmptyBufferBehavior {
        didSet { UserDefaults.standard.set(emptyBufferBehavior.rawValue, forKey: Self.emptyBufferBehaviorKey) }
    }

    static let defaultURL = "http://127.0.0.1:8001/v1/audio/transcriptions"
    static let defaultKeyCode: UInt32 = 2 // kVK_ANSI_D
    static let defaultFlags: UInt32 = UInt32(optionKey) // ⌥D
    static let pausePresets: [Double] = [0.4, 0.6, 0.8, 1.0, 1.5, 2.0, 3.0, 4.0, 5.0]
    static let maxSegmentPresets: [Double] = [5, 10, 15, 20, 30]
    static let activeOpacityPresets: [Double] = [0.5, 0.65, 0.8, 1.0]
    static let waveformWidthPresets: [Double] = [35, 60, 100, 167, 240, 320]

    private static let sttURLKey = "dictation.sttURL"
    private static let hotkeyKeyCodeKey = "dictation.hotkeyKeyCode"
    private static let hotkeyFlagsKey = "dictation.hotkeyFlags"
    private static let hotkeyMigratedKey = "dictation.hotkeyMigrated"
    private static let pauseSilenceKey = "dictation.pauseSilence"
    private static let maxSegmentKey = "dictation.maxSegment"
    private static let activeOpacityKey = "dictation.activeOpacity"
    private static let waveformWidthKey = "dictation.waveform.width"
    private static let microphoneKey = "dictation.microphone.uid"
    private static let journalEnabledKey = "dictation.journal.enabled"
    private static let emptyBufferBehaviorKey = "dictation.emptyBufferBehavior"

    init() {
        let def = UserDefaults.standard
        sttURLString = def.string(forKey: Self.sttURLKey) ?? Self.defaultURL
        hotkeyKeyCode = (def.object(forKey: Self.hotkeyKeyCodeKey) as? NSNumber)?.uint32Value ?? Self.defaultKeyCode
        hotkeyFlags = (def.object(forKey: Self.hotkeyFlagsKey) as? NSNumber)?.uint32Value ?? Self.defaultFlags
        pauseSilenceSeconds = def.object(forKey: Self.pauseSilenceKey) as? Double ?? 1.0
        maxSegmentSeconds = def.object(forKey: Self.maxSegmentKey) as? Double ?? 10.0
        activeOpacity = def.object(forKey: Self.activeOpacityKey) as? Double ?? 1.0
        waveformWidth = def.object(forKey: Self.waveformWidthKey) as? Double ?? 167.0
        microphoneUID = def.string(forKey: Self.microphoneKey)
        journalEnabled = def.object(forKey: Self.journalEnabledKey) as? Bool ?? true
        emptyBufferBehavior = def.string(forKey: Self.emptyBufferBehaviorKey)
            .flatMap(EmptyBufferBehavior.init(rawValue:)) ?? .inactive
        migrateHotkeyIfNeeded()
    }

    /// 快捷键默认随版本演进：v1 ⌥⇧F2 → v2 ⌥⌘D → v3 ⌥D。存版本号，版本不一致时应用当前默认。
    private func migrateHotkeyIfNeeded() {
        let def = UserDefaults.standard
        let current = def.string(forKey: Self.hotkeyMigratedKey) ?? ""
        guard current != "3" else { return }
        def.set("3", forKey: Self.hotkeyMigratedKey)
        hotkeyKeyCode = Self.defaultKeyCode
        hotkeyFlags = Self.defaultFlags
    }
}
