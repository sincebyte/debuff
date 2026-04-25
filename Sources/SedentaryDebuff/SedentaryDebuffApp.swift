import SwiftUI

@main
struct SedentaryDebuffApp: App {
    @NSApplicationDelegateAdaptor(SedentaryDebuffAppDelegate.self) private var appDelegate
    @StateObject private var services = AppServices()

    var body: some Scene {
        // 菜单栏图标始终保留；显隐只由 `DebuffHUDVisibility` 控制 Debuff 浮窗
        MenuBarExtra {
            MainSettingsView()
                .environmentObject(services.monitor)
                .environmentObject(services.weChat)
                .environmentObject(services.panelBridge)
                .environmentObject(services.debuffHUDVisibility)
        } label: {
            Image(nsImage: BundledAssets.menuBarIcon())
        }
        .menuBarExtraStyle(.menu)
    }
}
