import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainSettingsView: View {
    @EnvironmentObject private var monitor: SedentaryMonitor
    @EnvironmentObject private var panelBridge: DebuffPanelBridge

    /// 未保存的编辑：仅「保存」后写入 monitor
    @State private var draftThresholdMinutes: Double = 45
    @State private var draftCustomIconPath: String?

    @State private var thresholdText = ""
    @FocusState private var thresholdFieldFocused: Bool

    /// 是否与已保存阈值不同（以输入框 `thresholdText` 为准；未失焦时 draft 不会更新，不能只看 draft）
    private var thresholdDiffersFromSaved: Bool {
        let normalized = thresholdText.replacingOccurrences(of: ",", with: ".")
        if let v = Double(normalized) {
            return Self.clampThresholdMinutes(v) != Self.clampThresholdMinutes(monitor.thresholdMinutes)
        }
        return thresholdText != Self.formatMinutes(monitor.thresholdMinutes)
    }

    private var hasUnsavedChanges: Bool {
        thresholdDiffersFromSaved || draftCustomIconPath != monitor.customIconPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsSectionBlock(title: "久坐阈值", titleBarFill: Color.accentColor.opacity(0.14)) {
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

                SettingsSectionBlock(title: "icon图片", titleBarFill: Color.accentColor.opacity(0.14)) {
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

                SettingsSectionBlock(title: "当前状态", titleBarFill: Color.accentColor.opacity(0.14)) {
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        let sitMin = context.date.timeIntervalSince(monitor.sessionStart) / 60
                        LabeledContent("当前久坐") {
                            Text(String(format: "%.1f 分钟", sitMin))
                                .monospacedDigit()
                        }
                        LabeledContent("Debuff") {
                            Text(Self.showDebuff(at: context.date, monitor: monitor) ? "显示中" : "未触发")
                        }
                        LabeledContent("已保存阈值") {
                            Text(String(format: "%.1f 分钟", monitor.thresholdMinutes))
                                .monospacedDigit()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Button("保存") {
                applySavedConfiguration()
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(.borderedProminent)
            .disabled(!hasUnsavedChanges)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
        // 文本框绑定的是 thresholdText；若用户未失焦/未回车，draft 可能仍是旧值，保存前必须先提交输入。
        commitThresholdInput()
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

private enum SettingsSectionTitleMetrics {
    /// 中英混排标题行高会不一致，固定条高与各段对齐
    static let barHeight: CGFloat = 44
}

/// 设置页分段：标题行加粗放大；`titleBarFill` 为 nil 时用浅分隔色整宽条。
private struct SettingsSectionBlock<Content: View>: View {
    let title: String
    var titleBarFill: Color? = nil
    @ViewBuilder var content: () -> Content

    private var resolvedTitleBarFill: Color {
        titleBarFill ?? Color(nsColor: .separatorColor).opacity(0.14)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, 12)
                Spacer(minLength: 0)
            }
            .frame(height: SettingsSectionTitleMetrics.barHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Rectangle().fill(resolvedTitleBarFill))
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: 0, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 0, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}
