import AppKit
import ApplicationServices
import Combine
import Foundation

/// 微信未读：从收到未读/新消息起计时并立即在 HUD 展示（读 Dock 角标）。
final class WeChatDebuffMonitor: ObservableObject {
    @Published private(set) var weChatDebuffVisible: Bool = false

    private var poll: AnyCancellable?
    private var lastRawBadge: String?
    private var lastIntCount: Int?
    /// 当前「收到消息」计时起点
    private var messageEpochStart: Date?
    private var seenTrustedPrompt = false

    init() {
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
        // 与 Dock 角标同步，未读为 0 时隐藏并清零计时
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
        let label = WeChatDockBadgeReader.readStatusLabel()
        let normalized = normalize(label)
        applyBadgeChange(normalized)
    }

    private func normalize(_ label: String?) -> String? {
        guard var s = label else { return nil }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s == "0" { return nil }
        return s
    }

    private func parseCount(_ raw: String) -> Int? {
        if raw == "99+" { return 99 }
        if raw.allSatisfy(\.isNumber) { return Int(raw) }
        return nil
    }

    private func applyBadgeChange(_ newBadge: String?) {
        // 未读为 0：角标与 debuff 图标消失，计时从下次有未读起重新算
        guard let b = newBadge else {
            lastRawBadge = nil
            lastIntCount = nil
            messageEpochStart = nil
            if weChatDebuffVisible {
                weChatDebuffVisible = false
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
        weChatDebuffVisible = true
    }

    var showWeChatDebuff: Bool { weChatDebuffVisible }

    var elapsedForDisplay: TimeInterval {
        guard weChatDebuffVisible, let t = messageEpochStart else { return 0 }
        return Date().timeIntervalSince(t)
    }

    var weChatMinutesForDisplay: Double { elapsedForDisplay / 60 }
}
