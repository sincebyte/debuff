import Combine
import Foundation

/// 久坐会话：从启动或清除 debuff 后重新计时；超过阈值进入 debuff，双击清除后重置。
final class SedentaryMonitor: ObservableObject {
    @Published private(set) var sessionStart: Date
    /// 供界面 `onChange` 监听 debuff 显示/隐藏（计算属性 `showDebuff` 无法触发 `onChange`）
    @Published private(set) var debuffVisible: Bool = false

    @Published var thresholdMinutes: Double {
        didSet { UserDefaults.standard.set(thresholdMinutes, forKey: Self.thresholdKey) }
    }

    @Published var customIconPath: String? {
        didSet { UserDefaults.standard.set(customIconPath, forKey: Self.iconPathKey) }
    }

    private var ticker: AnyCancellable?

    private static let thresholdKey = "sedentaryThresholdMinutes"
    private static let iconPathKey = "customDebuffIconPath"

    init() {
        let def = UserDefaults.standard
        thresholdMinutes = def.object(forKey: Self.thresholdKey) as? Double ?? 45
        customIconPath = def.string(forKey: Self.iconPathKey)
        sessionStart = Date()
        debuffVisible = showDebuff
        startTicker()
    }

    private func startTicker() {
        ticker = Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                // 仅在实际跨越阈值时发布，避免 `Menu`/子菜单因高频 `objectWillChange` 被拆掉（闪烁、无法点选）
                let v = self.showDebuff
                if self.debuffVisible != v {
                    self.debuffVisible = v
                }
            }
    }

    var thresholdSeconds: TimeInterval {
        thresholdMinutes * 60
    }

    /// 当前久坐时长（秒）
    var sitElapsed: TimeInterval {
        Date().timeIntervalSince(sessionStart)
    }

    /// 是否应显示 debuff（久坐超过阈值）
    var showDebuff: Bool {
        sitElapsed >= thresholdSeconds
    }

    /// HUD 展示用：本次会话久坐总时长（分钟），自 `sessionStart` 起算
    var debuffMinutesForDisplay: Double {
        guard showDebuff else { return 0 }
        return sitElapsed / 60
    }

    /// 双击：清除 debuff，从当前时刻重新计时
    func clearDebuffAndRestart() {
        sessionStart = Date()
    }
}
