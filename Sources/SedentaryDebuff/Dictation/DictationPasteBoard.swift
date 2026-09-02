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

    // MARK: - 无障碍菜单粘贴

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func copyElements(_ element: AXUIElement, _ name: String) -> [AXUIElement]? {
        guard let value = attribute(element, name), CFGetTypeID(value) == CFArrayGetTypeID() else { return nil }
        return value as? [AXUIElement]
    }

    /// 递归在目标 App 的菜单栏里找「粘贴 / Paste」菜单项。
    private static func pasteMenuItem(in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 6, let children = copyElements(element, kAXChildrenAttribute) else { return nil }
        for child in children {
            let title = (attribute(child, kAXTitleAttribute) as? String ?? "").lowercased()
            if (attribute(child, kAXRoleAttribute) as? String) == kAXMenuItemRole,
               title.contains("paste") || title.contains("粘贴") {
                return child
            }
            if let found = pasteMenuItem(in: child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    /// 若前台 App 菜单栏里有可用的「编辑→粘贴」，就点它执行粘贴。
    /// Electron/Chromium 类应用（飞书、各类浏览器）不吃注入的 ⌘V，但一定响应自己的菜单命令。
    /// 返回是否按下成功；找不到或不可用返回 false，由调用方退回 ⌘V。
    private static func pressFrontmostPasteMenu() -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        let app = AXUIElementCreateApplication(pid)
        guard let menuBar = attribute(app, kAXMenuBarAttribute), CFGetTypeID(menuBar) == AXUIElementGetTypeID() else {
            CrashLog.write("[\(Date())] 粘贴：菜单路径无菜单栏\n")
            return false
        }
        guard let item = pasteMenuItem(in: menuBar as! AXUIElement, depth: 0) else {
            CrashLog.write("[\(Date())] 粘贴：菜单路径找不到 Paste 菜单项\n")
            return false
        }
        let enabled = attribute(item, kAXEnabledAttribute) as? Bool ?? true
        guard enabled else {
            CrashLog.write("[\(Date())] 粘贴：菜单路径 Paste 项不可用\n")
            return false
        }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    /// 先写剪贴板，再按前台 App 的「编辑→粘贴」菜单；菜单不可用时退回注入 ⌘V。
    static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let trusted = isAccessibilityTrusted
        let front = NSWorkspace.shared.frontmostApplication
        let bundle = front?.bundleIdentifier ?? "?"
        if trusted, pressFrontmostPasteMenu() {
            CrashLog.write("[\(Date())] 粘贴：菜单栏 Paste 生效（front=\(bundle)）\n")
            return
        }
        CrashLog.write("[\(Date())] 粘贴：注入 ⌘V（trusted=\(trusted) front=\(bundle)）\n")
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
