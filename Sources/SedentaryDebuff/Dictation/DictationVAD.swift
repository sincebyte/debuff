import Foundation

final class DictationVAD {
    struct Config {
        var rmsThreshold: Float = 0.012
    }

    private let config: Config
    private(set) var hasSpeech = false
    private var lastSpeechTime: TimeInterval = 0

    init(config: Config = Config()) {
        self.config = config
    }

    func reset() {
        hasSpeech = false
        lastSpeechTime = 0
    }

    func feed(rms: Float, at now: TimeInterval, silenceSeconds: Double) -> Bool {
        if rms >= config.rmsThreshold {
            hasSpeech = true
            lastSpeechTime = now
            return false
        }
        guard hasSpeech else { return false }
        return now - lastSpeechTime >= silenceSeconds
    }
}
