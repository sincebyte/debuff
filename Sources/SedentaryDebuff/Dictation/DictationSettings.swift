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

    @Published var livePaste: Bool {
        didSet { UserDefaults.standard.set(livePaste, forKey: Self.livePasteKey) }
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

    static let defaultURL = "http://127.0.0.1:8001/v1/audio/transcriptions"
    static let defaultKeyCode: UInt32 = 2 // kVK_ANSI_D
    static let defaultFlags: UInt32 = UInt32(optionKey) // ⌥D
    static let pausePresets: [Double] = [0.6, 0.8, 1.0, 1.5, 2.0]
    static let maxSegmentPresets: [Double] = [5, 10, 15, 20, 30]
    static let activeOpacityPresets: [Double] = [0.5, 0.65, 0.8, 1.0]

    private static let sttURLKey = "dictation.sttURL"
    private static let hotkeyKeyCodeKey = "dictation.hotkeyKeyCode"
    private static let hotkeyFlagsKey = "dictation.hotkeyFlags"
    private static let hotkeyMigratedKey = "dictation.hotkeyMigrated"
    private static let livePasteKey = "dictation.livePaste"
    private static let pauseSilenceKey = "dictation.pauseSilence"
    private static let maxSegmentKey = "dictation.maxSegment"
    private static let activeOpacityKey = "dictation.activeOpacity"

    init() {
        let def = UserDefaults.standard
        sttURLString = def.string(forKey: Self.sttURLKey) ?? Self.defaultURL
        hotkeyKeyCode = (def.object(forKey: Self.hotkeyKeyCodeKey) as? NSNumber)?.uint32Value ?? Self.defaultKeyCode
        hotkeyFlags = (def.object(forKey: Self.hotkeyFlagsKey) as? NSNumber)?.uint32Value ?? Self.defaultFlags
        livePaste = def.object(forKey: Self.livePasteKey) as? Bool ?? true
        pauseSilenceSeconds = def.object(forKey: Self.pauseSilenceKey) as? Double ?? 1.0
        maxSegmentSeconds = def.object(forKey: Self.maxSegmentKey) as? Double ?? 10.0
        activeOpacity = def.object(forKey: Self.activeOpacityKey) as? Double ?? 1.0
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
