import Foundation
import SwiftUI

/// 共享 `SedentaryMonitor` 与浮窗桥接，保证二者引用同一会话
final class AppServices: ObservableObject {
    let monitor: SedentaryMonitor
    let weChat: WeChatDebuffMonitor
    let panelBridge: DebuffPanelBridge

    private var screenUnlockObserver: NSObjectProtocol?

    init() {
        let m = SedentaryMonitor()
        let w = WeChatDebuffMonitor()
        monitor = m
        weChat = w
        panelBridge = DebuffPanelBridge(monitor: m, weChat: w)

        screenUnlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenUnlocked()
        }
    }

    deinit {
        if let screenUnlockObserver {
            DistributedNotificationCenter.default().removeObserver(screenUnlockObserver)
        }
    }

    private func handleScreenUnlocked() {
        monitor.clearDebuffAndRestart()
        panelBridge.sync()
    }
}
