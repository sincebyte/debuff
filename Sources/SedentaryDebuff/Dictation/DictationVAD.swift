import Foundation

final class DictationVAD {
    struct Config {
        /// 语音判定能量下限（环境再安静也不低于它，保证轻语也能触发）。
        var floorMin: Float = 0.012
        /// 语音能量须达到环境底噪的倍数：高于此才算"说话"，避免环境音打断停顿计时。
        var noiseGain: Float = 2.0
    }

    private let config: Config
    private(set) var hasSpeech = false
    private var lastSpeechTime: TimeInterval = 0
    /// 环境底噪缓慢估计：只在"听起来像静音"的帧上更新，让门槛随环境自适应。
    private var noiseFloor: Float = 0.004

    init(config: Config = Config()) {
        self.config = config
    }

    func reset() {
        hasSpeech = false
        lastSpeechTime = 0
    }

    /// 自适应门槛：平时为环境底噪的若干倍；环境吵时自动抬高，避免把噪音当说话。
    private var speechThreshold: Float {
        max(config.floorMin, noiseFloor * config.noiseGain)
    }

    func feed(rms: Float, at now: TimeInterval, silenceSeconds: Double) -> Bool {
        if rms >= speechThreshold {
            hasSpeech = true
            lastSpeechTime = now
            return false
        }
        // 低能量帧：顺势缓慢更新底噪估计（只收敛不飙升，静音期间噪音不再打断计时）。
        noiseFloor = max(noiseFloor * 0.97 + rms * 0.03, 0.0005)
        guard hasSpeech else { return false }
        return now - lastSpeechTime >= silenceSeconds
    }
}
