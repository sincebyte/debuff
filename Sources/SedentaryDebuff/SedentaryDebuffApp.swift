import SwiftUI

@main
struct SedentaryDebuffApp: App {
    @NSApplicationDelegateAdaptor(SedentaryDebuffAppDelegate.self) private var appDelegate
    @StateObject private var services = AppServices()

    var body: some Scene {
        MenuBarExtra {
            settingsContent
        } label: {
            Image(nsImage: BundledAssets.menuBarIcon())
        }
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private var settingsContent: some View {
        ScrollView {
            MainSettingsView()
                .environmentObject(services.monitor)
                .environmentObject(services.panelBridge)
                .frame(maxWidth: 280, alignment: .topLeading)
        }
        .frame(width: 200, height: 360)
        .fixedSize(horizontal: true, vertical: true)
    }
}
