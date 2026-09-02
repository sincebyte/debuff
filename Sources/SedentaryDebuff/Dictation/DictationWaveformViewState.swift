import Foundation

final class DictationWaveformViewState: ObservableObject {
    @Published var isActive = false
    @Published var activeOpacity: Double = 1.0
}
