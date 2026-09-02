import Carbon.HIToolbox

enum DictationHotKey {
    struct Preset {
        let keyCode: UInt32
        let flags: UInt32
        let label: String
    }

    static let presets: [Preset] = [
        Preset(keyCode: 2, flags: UInt32(optionKey), label: "⌥D"),
        Preset(keyCode: 120, flags: UInt32(optionKey | shiftKey), label: "⌥⇧F2"),
        Preset(keyCode: 120, flags: UInt32(optionKey | controlKey | shiftKey), label: "⌃⌥⇧F2"),
        Preset(keyCode: 49, flags: UInt32(cmdKey | optionKey), label: "⌘⌥ 空格"),
        Preset(keyCode: 49, flags: UInt32(cmdKey | shiftKey), label: "⌘⇧ 空格"),
        Preset(keyCode: 99, flags: UInt32(optionKey | shiftKey), label: "⌥⇧F3"),
    ]

    private static var handler: (() -> Void)?
    private static var hotKeyRef: EventHotKeyRef?
    private static var eventHandlerRef: EventHandlerRef?

    @discardableResult
    static func register(keyCode: UInt32, flags: UInt32, onPress: @escaping () -> Void) -> Bool {
        unregister()
        handler = onPress

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyHandler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
        guard installStatus == noErr else {
            handler = nil
            return false
        }

        let hotKeyID = EventHotKeyID(signature: 0x44494354, id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            flags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if registerStatus != noErr {
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
                self.eventHandlerRef = nil
            }
            handler = nil
            return false
        }
        return true
    }

    static func unregister() {
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        handler = nil
    }

    fileprivate static func pressHandled() {
        let action = handler
        DispatchQueue.main.async {
            action?()
        }
    }

    static func label(keyCode: UInt32, flags: UInt32) -> String {
        var parts: [String] = []
        if flags & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if flags & UInt32(controlKey) != 0 { parts.append("⌃") }
        if flags & UInt32(optionKey) != 0 { parts.append("⌥") }
        if flags & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(keyLabels[keyCode] ?? "键\(keyCode)")
        return parts.joined(separator: "")
    }

    private static let keyLabels: [UInt32: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
        12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        49: "空格", 36: "回车", 48: "Tab", 53: "Esc",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        24: "=", 27: "-", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 42: "\\",
    ]
}

private func hotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ theEvent: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let theEvent else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        theEvent,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    if status == noErr {
        DictationHotKey.pressHandled()
    }
    return noErr
}
