import Combine
import Foundation

/// 久坐会话：从启动或清除 debuff 后重新计时；超过阈值进入 debuff，双击清除后重置。
final class SedentaryMonitor: ObservableObject {
    @Published private(set) var sessionStart: Date
    @Published private(set) var debuffAnchor: Date?
    /// 供界面 `onChange` 监听 debuff 显示/隐藏（计算属性 `showDebuff` 无法触发 `onChange`）
    @Published private(set) var debuffVisible: Bool = false
    /// 定时递增，驱动 debuff 时长等 UI 刷新（久坐进行中时 `debuffVisible` 可能不变）
    @Published private(set) var tick: UInt64 = 0

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
        debuffAnchor = nil
        debuffVisible = showDebuff
        startTicker()
    }

    private func startTicker() {
        ticker = Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.syncDebuffAnchorIfNeeded()
                self.debuffVisible = self.showDebuff
                // 仅在 debuff 显示时递增 tick，避免设置页每 0.25s 整页刷新打断数值输入
                if self.showDebuff {
                    self.tick &+= 1
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

    /// debuff 开始时刻（久坐刚达阈值的时刻）
    private var computedDebuffStart: Date {
        sessionStart.addingTimeInterval(thresholdSeconds)
    }

    /// 用于展示的 debuff 持续分钟数（自进入 debuff 起算）
    var debuffMinutesForDisplay: Double {
        guard showDebuff else { return 0 }
        let start = debuffAnchor ?? computedDebuffStart
        return Date().timeIntervalSince(start) / 60
    }

    /// 同步 debuff 锚点：首次进入 debuff 时固定起点，避免阈值改动导致显示跳变
    func syncDebuffAnchorIfNeeded() {
        if showDebuff {
            if debuffAnchor == nil {
                debuffAnchor = computedDebuffStart
            }
        } else {
            debuffAnchor = nil
        }
    }

    /// 双击：清除 debuff，从当前时刻重新计时
    func clearDebuffAndRestart() {
        sessionStart = Date()
        debuffAnchor = nil
    }
}
