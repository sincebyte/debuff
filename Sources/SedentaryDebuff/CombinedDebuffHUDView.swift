import SwiftUI

/// 整组贴右（`float: right`）；微信/飞书按「后出现的在左、先出现的靠右」排列；久坐始终在组内最右侧。
/// 每种 debuff **只**在一处构建视图，避免动画交替时同屏叠两层。
struct CombinedDebuffHUDView: View {
    @ObservedObject var weChat: WeChatDebuffMonitor
    @ObservedObject var feishu: FeishuDebuffMonitor
    @ObservedObject var monitor: SedentaryMonitor
    var onSedentaryDoubleClick: () -> Void

    private var weChatOn: Bool { weChat.showWeChatDebuff }
    private var feishuOn: Bool { feishu.showFeishuDebuff }
    private var sitOn: Bool { monitor.showDebuff }

    /// 非久坐槽位：按 `hudShownAt` 降序（新 → 左）；同刻用固定次序稳定排序
    private enum NonSitSlot: Int, Hashable {
        case weChat = 0
        case feishu = 1
    }

    private var orderedNonSitSlots: [NonSitSlot] {
        var pairs: [(NonSitSlot, Date)] = []
        if weChatOn {
            pairs.append((.weChat, weChat.hudShownAt ?? .distantPast))
        }
        if feishuOn {
            pairs.append((.feishu, feishu.hudShownAt ?? .distantPast))
        }
        return pairs.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.rawValue < $1.0.rawValue
        }.map(\.0)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 6) {
                ForEach(orderedNonSitSlots, id: \.self) { slot in
                    switch slot {
                    case .weChat:
                        WeChatDebuffHUDView(weChat: weChat)
                            .id("hudWeChatDebuff")
                    case .feishu:
                        FeishuDebuffHUDView(feishu: feishu)
                            .id("hudFeishuDebuff")
                    }
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
