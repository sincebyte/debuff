import SwiftUI

/// 将久坐状态与置顶 debuff 浮窗关联
final class DebuffPanelBridge: ObservableObject {
    let monitor: SedentaryMonitor
    private let panel = DebuffPanelController()

    init(monitor: SedentaryMonitor) {
        self.monitor = monitor
    }

    func sync() {
        panel.update(show: monitor.showDebuff, monitor: monitor) { [weak self] in
            self?.monitor.clearDebuffAndRestart()
            self?.sync()
        }
    }
}
