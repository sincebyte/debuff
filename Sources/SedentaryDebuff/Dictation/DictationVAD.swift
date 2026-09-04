import Foundation

/// 语音停顿检测。
///
/// 旧实现只用「绝对电平门限」判停顿：门限下限固定为 floorMin，而麦克风在“安静”房间里
/// 的残留电平常与 floorMin 同量级，导致停顿期间的帧仍被判为“有声”，停顿计时被不断
/// 刷新，永远等不到切段，只能拖到最长时长才转写。
///
/// 新实现以「相对本句说话音量」为准：
/// - 记录本句说话的近期峰值（快升慢衰）；
/// - 电平跌到该峰值的 pauseDropRatio 以下，才认为是停顿（静音也会收到缓冲，因此
///   “电平远低于说话声”才是可靠的停顿判据），与环境绝对电平高低无关；
/// - 环境底噪只用于“开始说话”的判定，且只在真正低于说话声的间隙里学习，不会追着
///   说话声抬高门限。
final class DictationVAD {
    struct Config {
        /// 语音判定下限：开始说话所需的最低电平（防误触），一般低于真实说话电平即可。
        var floorMin: Float = 0.006
        /// 开始说话的门限：环境底噪的倍数（仅用于判定“开始说话”）。
        var noiseGain: Float = 2.0
        /// 电平跌到本句说话峰值的此比例以下，视为停顿/静音。
        var pauseDropRatio: Float = 0.18
        /// 说话峰值的慢衰时间常数（秒）：停顿越久门槛越低，避免长时间停顿后误判。
        var peakReleaseSeconds: Float = 2.5
    }

    private let config: Config
    private(set) var hasSpeech = false
    private var lastSpeechTime: TimeInterval = 0
    /// 环境底噪估计：只在“明显低于说话声”的间隙里学习，快降慢升。
    private var noiseFloor: Float = 0.004
    /// 本句说话音量峰值（快升慢衰），作为判停的相对基准。
    private var speechPeak: Float = 0
    /// 连续“有声”帧计数：滤掉按键、偶发杂音等单点触发，需持续约 0.2s 才算真说话。
    private var voicedStreak = 0
    private var lastFrameAt: TimeInterval?
    /// 连续有声多少帧确认进入“说话”（约 0.2s 量级，取决于缓冲时长）。
    private let confirmStreak = 3

    init(config: Config = Config()) {
        self.config = config
    }

    func reset() {
        hasSpeech = false
        lastSpeechTime = 0
        speechPeak = 0
        voicedStreak = 0
        lastFrameAt = nil
        // 每段从零估计，避免上一段/长时间停顿积累的底噪带偏下一段。
        noiseFloor = 0.004
    }

    /// 喂入一帧能量。当已开始说话且静音持续满 `silenceSeconds` 返回 true（应切段并 reset）。
    func feed(rms: Float, at now: TimeInterval, silenceSeconds: Double) -> Bool {
        // 相邻帧间隔（秒），用于按真实时间衰减说话峰值；首帧用默认值。
        let dt: Double
        if let prev = lastFrameAt {
            dt = min(max(now - prev, 0.01), 1.0)
        } else {
            dt = 0.1
        }
        lastFrameAt = now

        // 说话峰值：快升（当前帧能量更高立即抬升）慢衰（低于峰值按时间衰减）。
        if rms > speechPeak {
            speechPeak = rms
        } else {
            speechPeak *= expf(-Float(dt) / config.peakReleaseSeconds)
        }

        let belowDrop = rms < speechPeak * config.pauseDropRatio
        // 环境底噪只在明显低于说话声的间隙里学习：快降追静音，慢升适应变吵的房间。
        if belowDrop {
            if rms < noiseFloor {
                noiseFloor = max(rms * 0.5 + noiseFloor * 0.5, 0.0003)
            } else {
                noiseFloor += (rms - noiseFloor) * Float(min(dt, 0.5) * 0.1)
                noiseFloor = max(noiseFloor, 0.0003)
            }
        }

        // “有声”：既高于开始说话的门限，又没明显掉到本句说话峰值之下。
        let startThreshold = max(config.floorMin, noiseFloor * config.noiseGain)
        let voiced = rms >= startThreshold && !belowDrop

        if voiced {
            voicedStreak += 1
            if voicedStreak >= confirmStreak {
                if !hasSpeech { hasSpeech = true }
                lastSpeechTime = now
            }
        } else {
            voicedStreak = 0
        }

        guard hasSpeech else { return false }
        return now - lastSpeechTime >= silenceSeconds
    }
}
