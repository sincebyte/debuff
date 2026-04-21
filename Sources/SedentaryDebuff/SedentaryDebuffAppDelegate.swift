import AppKit

/// 关闭主设置窗口后不退出应用；从 Dock 再次点击时回到前台并显示已隐藏的窗口。
final class SedentaryDebuffAppDelegate: NSObject, NSApplicationDelegate {
    /// 须与 `SedentaryDebuffApp` 里 `Window("debuff", id: "settings")` 的标题一致。
    private static let settingsWindowTitle = "debuff"

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 与 HUD 浮窗并存时，`hasVisibleWindows` 可能为 true，仍要把 orderOut 掉的主设置窗叫回。
        for window in sender.windows where window.title == Self.settingsWindowTitle {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            if !window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }
}
