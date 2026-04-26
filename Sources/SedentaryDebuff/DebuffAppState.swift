import Foundation

@MainActor
final class DebuffAppState: ObservableObject {
    let services: AppServices
    private let statusBar: DebuffStatusBarController

    init() {
        let s = AppServices()
        services = s
        statusBar = DebuffStatusBarController(services: s)
    }
}
