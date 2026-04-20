import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainSettingsView: View {
    @EnvironmentObject private var monitor: SedentaryMonitor
    @EnvironmentObject private var panelBridge: DebuffPanelBridge

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("久坐 Debuff")
                .font(.title2.weight(.semibold))

            Text(
                "在本窗口调节阈值与图标。计时从启动或清除 debuff 后开始；超时后出现 debuff 浮窗（border.png 外框 + 图标）。图标下方为进入 debuff 后的累计分钟（一位小数 + m）。双击浮窗可清除并重新计时。"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            GroupBox("出现 debuff 前的久坐时间") {
                HStack {
                    Slider(value: $monitor.thresholdMinutes, in: 0.1...240, step: 0.1)
                    Text(String(format: "%.1f 分钟", monitor.thresholdMinutes))
                        .monospacedDigit()
                        .frame(minWidth: 100, maxHeight: 100, alignment: .trailing)
                }
                .padding(4)
            }

            GroupBox("Debuff 图标") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("选择图片…") {
                            pickIcon()
                        }
                        if monitor.customIconPath != nil {
                            Button("恢复默认") {
                                monitor.customIconPath = nil
                            }
                        }
                    }
                    if let p = monitor.customIconPath {
                        Text(p)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(4)
            }

            GroupBox("状态") {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("当前久坐") {
                        Text(String(format: "%.1f 分钟", monitor.sitElapsed / 60))
                            .monospacedDigit()
                    }
                    LabeledContent("Debuff") {
                        Text(monitor.showDebuff ? "显示中" : "未触发")
                    }
                }
                .padding(4)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: 400, alignment: .topLeading)
        .onChange(of: monitor.debuffVisible) { _ in
            panelBridge.sync()
        }
        .onAppear {
            panelBridge.sync()
        }
    }

    private func pickIcon() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "选择 Debuff 图标"
        if panel.runModal() == .OK, let url = panel.url {
            monitor.customIconPath = url.path
        }
    }
}
