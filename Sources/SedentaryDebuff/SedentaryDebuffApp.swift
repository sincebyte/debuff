import SwiftUI

@main
struct SedentaryDebuffApp: App {
    @StateObject private var services = AppServices()

    var body: some Scene {
        Window("Debuff", id: "settings") {
            MainSettingsView()
                .environmentObject(services.monitor)
                .environmentObject(services.panelBridge)
                .frame(minWidth: 280, idealWidth: 280, minHeight: 260, idealHeight: 260)
        }
        .defaultSize(width: 280, height: 260)
        .windowResizability(.automatic)
    }
}
