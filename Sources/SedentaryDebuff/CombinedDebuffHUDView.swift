import SwiftUI

/// 微信在左、久坐在右，整组 `float right`。
/// 微信、久坐各**只**在一个 `if` 里建一份视图，避免「左格/右格各一套」在动画交替时同屏叠两层。
struct CombinedDebuffHUDView: View {
    @ObservedObject var weChat: WeChatDebuffMonitor
    @ObservedObject var monitor: SedentaryMonitor
    var onSedentaryDoubleClick: () -> Void

    private var weChatOn: Bool { weChat.showWeChatDebuff }
    private var sitOn: Bool { monitor.showDebuff }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 6) {
                if weChatOn {
                    WeChatDebuffHUDView(weChat: weChat)
                        .id("hudWeChatDebuff")
                }
                if sitOn {
                    DebuffHUDView(monitor: monitor, onDoubleClick: onSedentaryDoubleClick)
                        .id("hudSedentaryDebuff")
                }
            }
        }
        // 占满浮窗内容区，左侧留空、图标组贴右（float right）
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
