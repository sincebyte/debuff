import Combine
import SwiftUI

/// 将久坐、微信未读与置顶 debuff 浮窗关联
final class DebuffPanelBridge: ObservableObject {
    let monitor: SedentaryMonitor
    let weChat: WeChatDebuffMonitor
    let feishu: FeishuDebuffMonitor
    let debuffHUDVisibility: DebuffHUDVisibility
    private let panel = DebuffPanelController()
    private var cancellables = Set<AnyCancellable>()

    init(
        monitor: SedentaryMonitor,
        weChat: WeChatDebuffMonitor,
        feishu: FeishuDebuffMonitor,
        debuffHUDVisibility: DebuffHUDVisibility
    ) {
        self.monitor = monitor
        self.weChat = weChat
        self.feishu = feishu
        self.debuffHUDVisibility = debuffHUDVisibility

        // 菜单栏未展开时 `MainSettingsView` 可能未挂载，仅靠其中的 `onChange` 无法收到阈值触发；在此始终监听
        monitor.$debuffVisible
            .merge(with: weChat.$weChatDebuffVisible)
            .merge(with: feishu.$feishuDebuffVisible)
            .merge(with: debuffHUDVisibility.$isEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.sync()
            }
            .store(in: &cancellables)

        sync()
    }

    func sync() {
        let hasDebuffToShow = monitor.showDebuff || weChat.weChatDebuffVisible || feishu.feishuDebuffVisible
        let show = debuffHUDVisibility.isEnabled && hasDebuffToShow
        panel.update(
            show: show,
            weChat: weChat,
            feishu: feishu,
            monitor: monitor
        ) { [weak self] in
            self?.monitor.clearDebuffAndRestart()
            self?.sync()
        }
    }
}
