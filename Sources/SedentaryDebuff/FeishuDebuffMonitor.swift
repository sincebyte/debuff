import AppKit
import ApplicationServices
import Combine
import Foundation

/// 飞书未读：自收到未读/新消息起计时，并在 HUD 显示未读（读 Dock 角标，与微信一致）。
/// 每 2 秒轮询角标；无未读时隐藏浮窗、清空角标与计时时长。
final class FeishuDebuffMonitor: ObservableObject {
    @Published private(set) var feishuDebuffVisible: Bool = false
    /// 本次 debuff 在 HUD 上变为可见的时刻，用于与微信等并排时「新出现的靠左」排序
    @Published private(set) var hudShownAt: Date?

    /// 当前从 Dock 读到的未读角标文案，无未读时为 `nil`（供状态展示与“清理数值”）
    @Published private(set) var feishuUnreadBadgeText: String?

    @Published var feishuCustomIconPath: String? {
        didSet { UserDefaults.standard.set(feishuCustomIconPath, forKey: Self.feishuIconPathKey) }
    }

    private var poll: AnyCancellable?
    private var lastRawBadge: String?
    private var lastIntCount: Int?
    private var messageEpochStart: Date?
    private var seenTrustedPrompt = false

    private static let feishuIconPathKey = "feishuCustomDebuffIconPath"

    init() {
        feishuCustomIconPath = UserDefaults.standard.string(forKey: Self.feishuIconPathKey)
        requestAXIfNeeded()
        startPolling()
    }

    private func requestAXIfNeeded() {
        if AXIsProcessTrusted() { return }
        if seenTrustedPrompt { return }
        seenTrustedPrompt = true
        let o: [String: Any] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(o as CFDictionary)
    }

    private func startPolling() {
        // 与 Dock 角标同步，未读消失则关闭 HUD 并清空数值
        poll = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.pollTick()
            }
    }

    private func pollTick() {
        if !AXIsProcessTrusted() {
            requestAXIfNeeded()
        }
        let label = FeishuDockBadgeReader.readStatusLabel()
        let normalized = normalize(label)
        applyBadgeChange(normalized)
    }

    private func normalize(_ label: String?) -> String? {
        guard var s = label else { return nil }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s == "0" { return nil }
        // 仅圆点/点状提示、无数字时，与「无未读」一致，不当作 debuff
        if s == "·" || s == "•" || s == "●" || s == "◦" || s == "⊙" { return nil }
        return s
    }

    private func parseCount(_ raw: String) -> Int? {
        if raw == "99+" { return 99 }
        if raw.allSatisfy(\.isNumber) { return Int(raw) }
        return nil
    }

    private func applyBadgeChange(_ newBadge: String?) {
        // 无未读：清角标、清计时、隐藏飞书 debuff 图标
        guard let b = newBadge else {
            lastRawBadge = nil
            lastIntCount = nil
            messageEpochStart = nil
            feishuUnreadBadgeText = nil
            if feishuDebuffVisible {
                feishuDebuffVisible = false
                hudShownAt = nil
            }
            return
        }
        let prevR = lastRawBadge
        let n = parseCount(b)
        var resetEpoch = false
        if prevR == nil { resetEpoch = true } else {
            if let a = n, let last = lastIntCount, a > last { resetEpoch = true }
            else if n == nil, b != (prevR ?? "") { resetEpoch = true }
        }
        if resetEpoch {
            messageEpochStart = Date()
        }
        lastRawBadge = b
        lastIntCount = n
        if feishuUnreadBadgeText != b {
            feishuUnreadBadgeText = b
        }
        // 未读仍成立时别每 2s 发 `objectWillChange`，否则 `MainSettingsView` 重绘会拆掉子菜单
        if !feishuDebuffVisible {
            feishuDebuffVisible = true
            hudShownAt = Date()
        }
    }

    var showFeishuDebuff: Bool { feishuDebuffVisible }

    var elapsedForDisplay: TimeInterval {
        guard feishuDebuffVisible, let t = messageEpochStart else { return 0 }
        return Date().timeIntervalSince(t)
    }

    var feishuMinutesForDisplay: Double { elapsedForDisplay / 60 }
}
