import AppKit
import ApplicationServices

enum DictationPasteBoard {
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 醒目提示并引导到系统设置的辅助功能页。
    static func promptAccessibility() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "需要「辅助功能」授权"
        alert.informativeText = "语音输入需要辅助功能权限，才能读取输入光标的位置，并把转写文字粘贴到光标处。\n\n请在系统设置中打开 debuff 的「辅助功能」开关（这是唯一一次需要手动操作）。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "以后再说")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// 在当前焦点处按下并松开某个组合键。
    /// 补齐字符信息并留按键间隔，贴近真实按键，避免被目标应用忽略。
    private static func tapKey(_ virtualKey: CGKeyCode, flags: CGEventFlags, characters: String = "") {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        keyDown?.flags = flags
        if !characters.isEmpty {
            let utf16 = Array(characters.utf16)
            utf16.withUnsafeBufferPointer { buffer in
                keyDown?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
            }
        }
        keyDown?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
            keyUp?.flags = flags
            keyUp?.post(tap: .cghidEventTap)
        }
    }

    static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        tapKey(9, flags: .maskCommand, characters: "v")
    }

    /// 在当前焦点处敲一次回车，把输入框里的内容提交/发送出去。
    static func pressReturn() {
        tapKey(36, flags: [], characters: "\r")
    }

    /// 在当前焦点处按一次 ⌥⌫，删除光标前的一个词（macOS 原生删词快捷键）。
    static func pressDeleteWord() {
        tapKey(51, flags: .maskAlternate)
    }

    /// 清空当前输入框全部内容：⌘A 全选后按 ⌫ 删除。
    static func pressClearAll() {
        tapKey(0, flags: .maskCommand, characters: "a")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            tapKey(51, flags: [])
        }
    }
}
