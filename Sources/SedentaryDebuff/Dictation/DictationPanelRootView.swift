import SwiftUI

/// 悬浮窗根视图：按设置切换两种风格。两种风格共用同一个 `DictationWaveformViewState`，
/// 所以切风格不会打断转写、缓冲、逐字揭示或提交链路，只换外观与排布。
struct DictationPanelRootView: View {
    let data: DictationWaveformData
    let state: DictationWaveformViewState
    let style: DictationSettings.PanelStyle
    /// 经典条把文字所需宽度上报给面板，由面板决定窗口的最终宽度。
    /// 竖版不关心这个回调。
    var onClassicWidthNeeded: ((CGFloat) -> Void)? = nil

    var body: some View {
        switch style {
        case .glass:
            DictationWaveformView(data: data, state: state)
        case .classic:
            DictationClassicBarView(
                data: data,
                state: state,
                onWidthNeeded: onClassicWidthNeeded
            )
        }
    }
}
