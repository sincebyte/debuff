import SwiftUI

@main
struct SedentaryDebuffApp: App {
    @NSApplicationDelegateAdaptor(SedentaryDebuffAppDelegate.self) private var appDelegate
    @StateObject private var services = AppServices()

    var body: some Scene {
        MenuBarExtra {
            MainSettingsView()
                .environmentObject(services.monitor)
                .environmentObject(services.weChat)
                .environmentObject(services.panelBridge)
        } label: {
            Image(nsImage: BundledAssets.menuBarIcon())
        }
        .menuBarExtraStyle(.menu)
    }
}
