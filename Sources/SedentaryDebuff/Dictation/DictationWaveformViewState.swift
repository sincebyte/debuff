import Foundation

final class DictationWaveformViewState: ObservableObject {
    /// 是否处于「激活/输入」状态：音柱显示绿色并实时跳动。
    @Published var isActive = false
    /// 引擎是否在监听（激活或非激活待命）：驱动音柱在灰色待命时也实时跳动。
    @Published var isListening = false
    @Published var activeOpacity: Double = 1.0

    /// 缓冲文本：激活期间逐段累积，提交时整段粘贴到当前光标后清空。
    @Published var bufferLines: [String] = []
    /// 缓冲非空时在光波下方展开滚动文本区。
    @Published var showsBuffer = false
    /// 缓冲为空时是否保留文本框/按钮的非激活占位（false 则收起，只留波形）。
    @Published var keepsEmptyPlaceholder = true
}
