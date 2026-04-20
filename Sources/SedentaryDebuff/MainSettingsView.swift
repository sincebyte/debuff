import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainSettingsView: View {
    @EnvironmentObject private var monitor: SedentaryMonitor
    @EnvironmentObject private var panelBridge: DebuffPanelBridge

    /// 未保存的编辑：仅「保存」后写入 monitor
    @State private var draftThresholdMinutes: Double = 45
    @State private var draftCustomIconPath: String?

    @State private var statusClock = Date()
    @State private var thresholdText = ""
    @FocusState private var thresholdFieldFocused: Bool

    private var hasUnsavedChanges: Bool {
        Self.clampThresholdMinutes(draftThresholdMinutes) != Self.clampThresholdMinutes(monitor.thresholdMinutes)
            || draftCustomIconPath != monitor.customIconPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Debuff")
                .font(.title2.weight(.semibold))

            Text("阈值与图标在下方修改后，需点击「保存」才会应用到计时与 debuff 浮窗。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SettingsSectionBlock(title: "久坐阈值") {
                HStack(spacing: 8) {
                    TextField("分钟", text: $thresholdText)
                        .focused($thresholdFieldFocused)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 96)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .onSubmit { commitThresholdInput() }
                    Text("分钟")
                        .foregroundStyle(.secondary)
                }
                Text("约 0.1～240 分钟；改完后点「保存」生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsSectionBlock(title: "icon图片") {
                HStack {
                    Button("选择图片…") {
                        pickIcon()
                    }
                    if draftCustomIconPath != nil {
                        Button("恢复默认") {
                            draftCustomIconPath = nil
                        }
                    }
                }
                if let p = draftCustomIconPath {
                    Text(p)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            SettingsSectionBlock(title: "当前状态") {
                let sitMin = statusClock.timeIntervalSince(monitor.sessionStart) / 60
                LabeledContent("当前久坐") {
                    Text(String(format: "%.1f 分钟", sitMin))
                        .monospacedDigit()
                }
                LabeledContent("Debuff") {
                    Text(Self.showDebuff(at: statusClock, monitor: monitor) ? "显示中" : "未触发")
                }
                LabeledContent("已保存阈值") {
                    Text(String(format: "%.1f 分钟", monitor.thresholdMinutes))
                        .monospacedDigit()
                }
            }

            Button("保存") {
                applySavedConfiguration()
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(.borderedProminent)
            .disabled(!hasUnsavedChanges)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { date in
            statusClock = date
        }
        .onAppear {
            loadDraftFromMonitor()
            panelBridge.sync()
        }
        .onChange(of: draftThresholdMinutes) { newValue in
            if !thresholdFieldFocused {
                thresholdText = Self.formatMinutes(newValue)
            }
        }
        .onChange(of: thresholdFieldFocused) { focused in
            if !focused {
                commitThresholdInput()
            }
        }
        .onChange(of: monitor.debuffVisible) { _ in
            panelBridge.sync()
        }
    }

    private func loadDraftFromMonitor() {
        draftThresholdMinutes = monitor.thresholdMinutes
        draftCustomIconPath = monitor.customIconPath
        syncThresholdTextFromDraft()
    }

    private func applySavedConfiguration() {
        let t = Self.clampThresholdMinutes(draftThresholdMinutes)
        draftThresholdMinutes = t
        monitor.thresholdMinutes = t
        monitor.customIconPath = draftCustomIconPath
        syncThresholdTextFromDraft()
        panelBridge.sync()
    }

    private func syncThresholdTextFromDraft() {
        thresholdText = Self.formatMinutes(draftThresholdMinutes)
    }

    private func commitThresholdInput() {
        let normalized = thresholdText.replacingOccurrences(of: ",", with: ".")
        guard let v = Double(normalized) else {
            syncThresholdTextFromDraft()
            return
        }
        draftThresholdMinutes = Self.clampThresholdMinutes(v)
        syncThresholdTextFromDraft()
    }

    private static func formatMinutes(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    static func clampThresholdMinutes(_ value: Double) -> Double {
        let clamped = min(240, max(0.1, value))
        return (clamped * 10).rounded() / 10
    }

    private static func showDebuff(at date: Date, monitor: SedentaryMonitor) -> Bool {
        date.timeIntervalSince(monitor.sessionStart) >= monitor.thresholdSeconds
    }

    private func pickIcon() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "选择 Debuff 图标"
        if panel.runModal() == .OK, let url = panel.url {
            draftCustomIconPath = url.path
        }
    }
}

/// 设置页分段：标题行加粗放大，背景横向铺满。
private struct SettingsSectionBlock<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title3.weight(.bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(nsColor: .separatorColor).opacity(0.14))
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}
