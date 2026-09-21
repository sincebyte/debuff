import AppKit

/// 纯 AppKit 入口：菜单栏用 `NSStatusItem` 自绘，浮窗用 `NSPanel`。不使用 SwiftUI
/// `App`/`Scene`（`Settings` 场景会在启动/激活时弹出空白设置面板），因此这里直接
/// 手动创建 `NSApplication` 并持有应用状态。
@main
final class SedentaryDebuffAppDelegate: NSObject, NSApplicationDelegate {
    /// 应用启动时创建并长期持有（状态栏菜单、各监视器、语音输入等都由它组装）。
    private var appState: DebuffAppState?

    static func main() {
        let app = NSApplication.shared
        let delegate = SedentaryDebuffAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        CrashLog.install()
        BundledAssets.registerBundledFonts()
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            appState = DebuffAppState()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.activate(ignoringOtherApps: true)
        return true
    }
}
