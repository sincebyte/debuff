import AppKit
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
    private var workspaceObservers: [NSObjectProtocol] = []

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

        // 显示器熄屏/唤醒、系统睡眠/唤醒（含合盖）：同样交给语音输入处理。语音正在
        // 录音时熄屏期间保持录音不停麦，屏幕唤醒后原样继续；非录音态才按旧逻辑停麦恢复。
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            workspaceObservers.append(workspaceCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                self?.dictation.handleScreenLock()
            })
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(workspaceCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                self?.dictation.handleScreenUnlock()
            })
        }
    }

    deinit {
        if let screenLockObserver {
            DistributedNotificationCenter.default().removeObserver(screenLockObserver)
        }
        if let screenUnlockObserver {
            DistributedNotificationCenter.default().removeObserver(screenUnlockObserver)
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspaceCenter.removeObserver(observer)
        }
    }

    private func handleScreenLocked() {
        // 熄屏/锁屏：录音进行中则保持录音不停麦（见 DictationController.handleScreenLock），
        // 只有非录音态才停麦待解锁恢复。
        dictation.handleScreenLock()
    }

    private func handleScreenUnlocked() {
        monitor.clearDebuffAndRestart()
        panelBridge.sync()
        dictation.handleScreenUnlock()
    }
}
