import Combine
import SwiftUI

/// 将久坐、微信未读与置顶 debuff 浮窗关联
final class DebuffPanelBridge: ObservableObject {
    let monitor: SedentaryMonitor
    let weChat: WeChatDebuffMonitor
    private let panel = DebuffPanelController()
    private var cancellables = Set<AnyCancellable>()

    init(monitor: SedentaryMonitor, weChat: WeChatDebuffMonitor) {
        self.monitor = monitor
        self.weChat = weChat

        // 菜单栏未展开时 `MainSettingsView` 可能未挂载，仅靠其中的 `onChange` 无法收到阈值触发；在此始终监听
        monitor.$debuffVisible
            .merge(with: weChat.$weChatDebuffVisible)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.sync()
            }
            .store(in: &cancellables)

        sync()
    }

    func sync() {
        let show = monitor.showDebuff || weChat.weChatDebuffVisible
        panel.update(
            show: show,
            weChat: weChat,
            monitor: monitor
        ) { [weak self] in
            self?.monitor.clearDebuffAndRestart()
            self?.sync()
        }
    }
}
