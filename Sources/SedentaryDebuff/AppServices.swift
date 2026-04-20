import SwiftUI

/// 共享 `SedentaryMonitor` 与浮窗桥接，保证二者引用同一会话
final class AppServices: ObservableObject {
    let monitor: SedentaryMonitor
    let panelBridge: DebuffPanelBridge

    init() {
        let m = SedentaryMonitor()
        monitor = m
        panelBridge = DebuffPanelBridge(monitor: m)
    }
}
