import Foundation

final class DictationWaveformViewState: ObservableObject {
    /// 是否处于「激活/输入」状态：音柱显示绿色并实时跳动。
    @Published var isActive = false
    /// 引擎是否在监听（激活或非激活待命）：驱动音柱在灰色待命时也实时跳动。
    @Published var isListening = false
    @Published var activeOpacity: Double = 1.0
}
