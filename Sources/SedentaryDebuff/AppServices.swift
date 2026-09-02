import Foundation
import SwiftUI

/// 共享 `SedentaryMonitor` 与浮窗桥接，保证二者引用同一会话
final class AppServices: ObservableObject {
    let monitor: SedentaryMonitor
    let weChat: WeChatDebuffMonitor
    let feishu: FeishuDebuffMonitor
    let debuffHUDVisibility: DebuffHUDVisibility
    let panelBridge: DebuffPanelBridge
    let dictation: DictationController

    private var screenLockObserver: NSObjectProtocol?
    private var screenUnlockObserver: NSObjectProtocol?

    init() {
        let m = SedentaryMonitor()
        let w = WeChatDebuffMonitor()
        let f = FeishuDebuffMonitor()
        let v = DebuffHUDVisibility()
        monitor = m
        weChat = w
        feishu = f
        debuffHUDVisibility = v
        panelBridge = DebuffPanelBridge(monitor: m, weChat: w, feishu: f, debuffHUDVisibility: v)
        dictation = DictationController(settings: DictationSettings())

        screenLockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenLocked()
        }
        screenUnlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenUnlocked()
        }
    }

    deinit {
        if let screenLockObserver {
            DistributedNotificationCenter.default().removeObserver(screenLockObserver)
        }
        if let screenUnlockObserver {
            DistributedNotificationCenter.default().removeObserver(screenUnlockObserver)
        }
    }

    private func handleScreenLocked() {
        // 锁屏即停麦：隐私考虑，麦克风切到关闭态，解锁后再恢复。
        dictation.handleScreenLock()
    }

    private func handleScreenUnlocked() {
        monitor.clearDebuffAndRestart()
        panelBridge.sync()
        dictation.handleScreenUnlock()
    }
}
