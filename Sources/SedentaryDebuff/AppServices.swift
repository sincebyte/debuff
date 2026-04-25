import Foundation
import SwiftUI

/// 共享 `SedentaryMonitor` 与浮窗桥接，保证二者引用同一会话
final class AppServices: ObservableObject {
    let monitor: SedentaryMonitor
    let weChat: WeChatDebuffMonitor
    let debuffHUDVisibility: DebuffHUDVisibility
    let panelBridge: DebuffPanelBridge

    private var screenUnlockObserver: NSObjectProtocol?

    init() {
        let m = SedentaryMonitor()
        let w = WeChatDebuffMonitor()
        let v = DebuffHUDVisibility()
        monitor = m
        weChat = w
        debuffHUDVisibility = v
        panelBridge = DebuffPanelBridge(monitor: m, weChat: w, debuffHUDVisibility: v)

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
