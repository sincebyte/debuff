import Foundation

final class DictationWaveformViewState: ObservableObject {
    /// 是否处于「激活/输入」状态：音柱显示绿色并实时跳动。
    @Published var isActive = false
    /// 引擎是否在监听（激活或非激活待命）：驱动音柱在灰色待命时也实时跳动。
    @Published var isListening = false
    /// 转写进行中（loading）：波形区铺满进度条，表示大模型正在转译。
    /// 只要有在途转写即显示（VAD 切片、收尾段一并触发），全部返回即消失。
    @Published var isTranscribing = false
    /// 清整理进行中（第二阶段）：把转写文本交给大模型纠正错别字/去重复词。
    @Published var isCleaning = false
    /// 是否启用「转译 → 清整理」两段式进度融合：启用时第一阶段占前段、第二阶段占后段。
    @Published var cleanupFused = false
    /// 本段音频的预计转写耗时（秒），用于把进度条缓动曲线按语音长短伸缩。
    @Published var loadingEstimatedDuration: TimeInterval = 2.0
    /// 本次清整理的预计耗时（秒），用于第二阶段进度条的缓动曲线。
    @Published var cleaningEstimatedDuration: TimeInterval = 2.0
    /// 临近最大切段的倒计时：距强制切段还剩几秒（5…1），nil 表示不在预警窗口。
    @Published var cutCountdown: Int?

    /// 右侧麦克风提示：绿色=可以说话；灰色=先别说话（临近切段或未激活）。
    enum MicHint {
        case go
        case hold
    }

    var micHint: MicHint {
        if cutCountdown != nil { return .hold }
        return isActive ? .go : .hold
    }

    /// 处理进行中（转译或清整理任一阶段）：进度条覆盖整段波形区域。
    /// 进度条始终是一条自然曲线：阶段切换只改变推进速度，不重置也不跳变。
    var showsLoading: Bool { isTranscribing || isCleaning }
    @Published var activeOpacity: Double = 1.0

    /// 缓冲文本：激活期间逐段累积，提交时整段粘贴到当前光标后清空。
    @Published var bufferLines: [String] = []
    /// 缓冲非空时在光波下方展开滚动文本区。
    @Published var showsBuffer = false
    /// 缓冲为空时是否保留文本框/按钮的非激活占位（false 则收起，只留波形）。
    @Published var keepsEmptyPlaceholder = true
}
