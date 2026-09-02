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

    static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}
