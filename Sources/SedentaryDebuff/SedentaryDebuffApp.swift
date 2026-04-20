import SwiftUI

@main
struct SedentaryDebuffApp: App {
    @StateObject private var services = AppServices()

    var body: some Scene {
        WindowGroup {
            MainSettingsView()
                .environmentObject(services.monitor)
                .environmentObject(services.panelBridge)
        }
        .defaultSize(width: 520, height: 440)
    }
}
