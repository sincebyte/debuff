import SwiftUI

@main
struct SedentaryDebuffApp: App {
    @StateObject private var services = AppServices()

    var body: some Scene {
        WindowGroup {
            MainSettingsView()
                .environmentObject(services.monitor)
                .environmentObject(services.panelBridge)
                .frame(minWidth: 520, idealWidth: 520, minHeight: 420, idealHeight: 420)
        }
        .defaultSize(width: 520, height: 420)
        .windowResizability(.contentSize)
    }
}
