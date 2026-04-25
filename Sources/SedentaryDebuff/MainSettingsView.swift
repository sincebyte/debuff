import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct MainSettingsView: View {
    @EnvironmentObject private var monitor: SedentaryMonitor
    @EnvironmentObject private var panelBridge: DebuffPanelBridge

    /// 打开菜单时刷新一次；避免在 NSMenu 内用 `TimelineView` 高频重绘（易闪退）
    @State private var statusSitLine = ""
    @State private var statusDebuffLine = ""
    @State private var statusThresholdLine = ""

    /// 主菜单展开期间保持固定，子菜单内不读 `monitor.thresholdMinutes`，避免 `@Published`
    /// 在子菜单仍打开时刷新整棵 `NSMenu` 导致二级菜单被拆掉。
    @State private var thresholdChoicesSnapshot: [Double] = []
    @State private var thresholdShownAsSelected: Double = 45

    var body: some View {
        Group {
            Section {
                ThresholdSubmenu(
                    choices: thresholdChoicesSnapshot,
                    shownSelected: thresholdShownAsSelected,
                    onPick: { m in
                        let v = Self.clampThresholdMinutes(m)
                        DispatchQueue.main.async {
                            monitor.thresholdMinutes = v
                            thresholdShownAsSelected = v
                            var s = Set(Self.baseThresholdMinutes)
                            s.insert(v)
                            thresholdChoicesSnapshot = s.sorted()
                            panelBridge.sync()
                            refreshStatusSnapshot()
                        }
                    }
                )
            }

            Section {
                Button("选择图片…") {
                    pickIcon()
                }
                if monitor.customIconPath != nil {
                    Button("恢复默认图标") {
                        monitor.customIconPath = nil
                        panelBridge.sync()
                        refreshStatusSnapshot()
                    }
                }
                if let p = monitor.customIconPath {
                    Text((p as NSString).lastPathComponent)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text(statusSitLine)
            }

            Divider()

            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
        }
        .onAppear {
            let clamped = Self.clampThresholdMinutes(monitor.thresholdMinutes)
            thresholdShownAsSelected = clamped
            var s = Set(Self.baseThresholdMinutes)
            s.insert(clamped)
            thresholdChoicesSnapshot = s.sorted()
            panelBridge.sync()
            refreshStatusSnapshot()
        }
        // MenuBarExtra 内 .onAppear / .task 常在首次后不再触发；用 NSMenu 开始跟踪时刷新
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            refreshStatusSnapshot()
        }
    }

    private func refreshStatusSnapshot() {
        let now = Date()
        let sitMin = now.timeIntervalSince(monitor.sessionStart) / 60
        statusSitLine = String(format: "当前久坐 %.1f 分钟", sitMin)
        statusDebuffLine = Self.showDebuff(at: now, monitor: monitor) ? "Debuff：显示中" : "Debuff：未触发"
        statusThresholdLine = "当前阈值 \(Self.formatMinutes(monitor.thresholdMinutes)) 分钟"
    }

    fileprivate static func formatMinutes(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// 与原先输入框一致的档位：0.1～240，步进 0.1
    fileprivate static func clampThresholdMinutes(_ value: Double) -> Double {
        let clamped = min(240, max(0.1, value))
        return (clamped * 10).rounded() / 10
    }

    private static func showDebuff(at date: Date, monitor: SedentaryMonitor) -> Bool {
        date.timeIntervalSince(monitor.sessionStart) >= monitor.thresholdSeconds
    }

    /// 菜单内可滚动的有限档位；含小数与常用整数
    fileprivate static let baseThresholdMinutes: [Double] = {
        var v: [Double] = [0.1, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60]
        return v
    }()

    private func pickIcon() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "选择 Debuff 图标"
        if panel.runModal() == .OK, let url = panel.url {
            monitor.customIconPath = url.path
            panelBridge.sync()
            refreshStatusSnapshot()
        }
    }

    /// 二级菜单本体：只依赖传入的快照与闭包，子菜单里不出现对 `monitor` 的读取。
    private struct ThresholdSubmenu: View {
        let choices: [Double]
        let shownSelected: Double
        let onPick: (Double) -> Void

        var body: some View {
            Menu {
                ForEach(choices, id: \.self) { m in
                    Button {
                        onPick(m)
                    } label: {
                        HStack {
                            Group {
                                if isMarked(m) {
                                    Image(systemName: "checkmark")
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(width: 12, alignment: .leading)
                            Text(MainSettingsView.formatMinutes(m))
                        }
                    }
                }
            } label: {
                Text("定时：\(MainSettingsView.formatMinutes(shownSelected)) 分钟")
            }
        }

        private func isMarked(_ m: Double) -> Bool {
            MainSettingsView.clampThresholdMinutes(m) == MainSettingsView.clampThresholdMinutes(shownSelected)
        }
    }
}
