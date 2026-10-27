import AppKit
import SwiftUI

/// 经典横版胶囊的尺寸与排布常量：视图层和面板层共用，保证窗口尺寸、胶囊宽度
/// 与文字所需宽度始终一致。
enum DictationClassicBarMetrics {
    /// 胶囊本体高度（不含四周留给阴影的透明边距）：在 37pt 基础上再降低约五分之一，
    /// 文字字号保持不变，只压缩上下留白。
    static let barHeight: CGFloat = 29
    /// 窗口四周的阴影留白：尽量收紧，避免窗口边界看起来像一圈大边框。
    static let shadowInset: CGFloat = 4
    /// 胶囊内缘到波形/文字的左右留白。
    static let horizontalLeading: CGFloat = 14
    static let horizontalTrailing: CGFloat = 16
    /// 左侧小波形宽度，以及波形与文字之间的间距。
    static let waveformWidth: CGFloat = 40
    static let waveformSpacing: CGFloat = 12
    /// 文本正好放下时多留 2pt，避免字体测量取整后最后一字贴边。
    static let fitFudge: CGFloat = 2
    /// 会话起始宽度：最大宽度的一半，且不小于 160pt。
    static let initialMinWidth: CGFloat = 160
    /// 「最大宽度」= 用户拖右缘设定的值，默认 320，范围 160…416。
    static var defaultMaxWidth: CGFloat { CGFloat(DictationSettings.defaultClassicPanelWidth) }
    static var minMaxWidth: CGFloat { CGFloat(DictationSettings.classicPanelWidthRange.lowerBound) }
    static var maxMaxWidth: CGFloat { CGFloat(DictationSettings.classicPanelWidthRange.upperBound) }

    /// 每次开始录音时的起始宽度：最大宽度的一半，最低 160pt。
    static func initialWidth(forMax maxWidth: CGFloat) -> CGFloat {
        let clamped = min(maxMaxWidth, max(minMaxWidth, maxWidth))
        return min(clamped, max(initialMinWidth, clamped * 0.5))
    }

    /// 单行文字完整放下所需的最小胶囊宽度（含波形、间距与左右留白）。
    static func neededWidth(forTextWidth textWidth: CGFloat) -> CGFloat {
        horizontalLeading + waveformWidth + waveformSpacing + textWidth + horizontalTrailing + fitFudge
    }
}

/// type4me 经典录音条风格：横版深色胶囊，左侧绿色小波形 + 单行实时文字。
/// 不显示右侧取消/关闭按钮，也没有红球/红点；失败/完成等状态仍由既有菜单与
/// 声音反馈承担，这里只负责录音、实时文字、逐字揭示与清整理进度。
struct DictationClassicBarView: View {
    let data: DictationWaveformData
    @ObservedObject var state: DictationWaveformViewState
    /// 把「当前文字完整放下所需的胶囊宽度」上报给面板；面板据此把窗口从起始宽度
    /// 平滑撑到最大宽度。经典条不再使用固定宽度。
    var onWidthNeeded: ((CGFloat) -> Void)?
    @State private var tick = 0
    /// 清整理阶段的覆盖层：转译阶段不再显示 loading，只有「整理中」才盖住文字。
    @State private var showsCleaningOverlay = false
    @State private var cleaningProgress: CGFloat = 0
    @State private var cleaningIdleTicks = 0
    /// 上一次上报的所需宽度，避免每帧重复回调。
    @State private var lastReportedWidth: CGFloat = -1

    private let displaySeconds = 0.6
    private let baseGain: Float = 15.0
    private let noiseFloor: Float = 0.001
    private let standbyOpacity = 0.55
    private let activeBarColor = Color(red: 0.3, green: 0.92, blue: 0.6)
    private let standbyBarColor = Color(red: 0.72, green: 0.72, blue: 0.75)
    /// 整理阶段的背景进度色：偏黑的深灰，不透明，避免左端胶囊圆角处透出底层玻璃造成色差。
    private let cleaningFillColor = Color(red: 0.17, green: 0.18, blue: 0.20)
    private let cleaningProgressCap: CGFloat = 0.96
    private let cleaningTickInterval: Double = 0.033
    private let panelGlassTint = Color.black.opacity(0.6)
    private let borderGradient = LinearGradient(
        colors: [
            Color.white.opacity(0.34),
            Color.white.opacity(0.10),
            Color.white.opacity(0.20),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    private let timer = Timer.publish(every: 0.033, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            normalContent
                .opacity(showsCleaningOverlay ? 0 : 1)
            if showsCleaningOverlay {
                cleaningContent
            }
        }
        // 宽度不再写死：窗口多宽，胶囊就铺满减去阴影留白后的内容区。
        .frame(maxWidth: .infinity)
        .frame(height: DictationClassicBarMetrics.barHeight)
        .background(capsuleBackground)
        .clipShape(Capsule())
        .overlay {
            Capsule().strokeBorder(borderGradient, lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.32), radius: 3, x: 0, y: 1)
        .padding(DictationClassicBarMetrics.shadowInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: state.isCleaning) { cleaning in
            if cleaning {
                // 每次进入清整理都从 0 起一条新的进度曲线；转译阶段的 loading 不再显示。
                cleaningProgress = 0
                cleaningIdleTicks = 0
                showsCleaningOverlay = true
            }
        }
        .onAppear {
            state.revealedBufferText = bufferTargetText
            if state.isCleaning {
                cleaningProgress = 0
                showsCleaningOverlay = true
            }
            reportNeededWidth()
        }
        .onReceive(timer) { _ in
            advanceReveal()
            updateCleaningPresentation()
            reportNeededWidth()
            // 转译阶段不再有 loading 覆盖层，文字直接接在后面出现；
            // 音柱/清整理进度只在对应阶段持续刷新。
            guard state.isActive || state.isListening || state.isCleaning || showsCleaningOverlay || state.cutCountdown != nil else { return }
            tick += 1
        }
    }

    // MARK: - 录音中

    private var normalContent: some View {
        HStack(spacing: DictationClassicBarMetrics.waveformSpacing) {
            waveform
                .frame(
                    width: DictationClassicBarMetrics.waveformWidth,
                    height: 20
                )
                .opacity(state.isActive ? state.activeOpacity : standbyOpacity)
                .animation(.easeInOut(duration: 0.2), value: state.isActive)
            transcriptLane
                .frame(maxWidth: .infinity, maxHeight: 24)
        }
        // 波形靠左但不贴边；右侧只留收尾空间，整体比之前更紧凑。
        .padding(.leading, DictationClassicBarMetrics.horizontalLeading)
        .padding(.trailing, DictationClassicBarMetrics.horizontalTrailing)
    }

    /// 单行实时文本：短文本居中，变长后自然过渡到「尾部跟随」，超出部分从左侧裁掉
    /// 并做一点渐隐，保证最新说出的字始终完整可见。文字没超出时不加渐隐，避免
    /// 胶囊刚撑到刚好放下时把第一个字淡掉。
    private var transcriptLane: some View {
        GeometryReader { geo in
            let text = displayedText
            let width = Self.textWidth(text)
            let overflows = width > geo.size.width + 0.5
            let line = Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(text.isEmpty ? 0.0 : 0.96))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                // GeometryReader 的子视图默认落在左上角；显式给一个与文字区同高的
                // frame，让单行文字在胶囊里真正垂直居中。
                .frame(height: geo.size.height, alignment: .center)
                .offset(x: width <= geo.size.width
                    ? max(0, (geo.size.width - width) / 2)
                    : geo.size.width - width)
                // 让后续遮罩以「文字区」而不是「文字本身」为坐标，左侧渐隐宽度才不会
                // 随文本变长而越来越宽。
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            if overflows {
                line.mask { leadingFade }
            } else {
                line
            }
        }
        .frame(height: 22)
        .clipped()
    }

    private var leadingFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.05),
                .init(color: .black, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var displayedText: String {
        let revealed = state.revealedBufferText.replacingOccurrences(of: "\n", with: " ")
        if !revealed.isEmpty { return revealed }
        // 还没出字时给一个轻提示；经典条没有 loading 覆盖层，文字直接接在后面出现。
        if state.isActive || state.isListening { return "正在聆听…" }
        return ""
    }

    /// 与视图层一致的 14pt medium；按同一字体测量，避免居中/尾随切换时抖动。
    private static let laneFont = NSFont.systemFont(ofSize: 14, weight: .medium)

    private static func textWidth(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return ceil((text as NSString).size(withAttributes: [.font: laneFont]).width)
    }

    /// 把「当前文字完整放下需要的胶囊宽度」上报给面板。只在宽度变化超过 0.5pt 时
    /// 回调，避免逐帧重复触发布局。
    private func reportNeededWidth() {
        let needed = DictationClassicBarMetrics.neededWidth(
            forTextWidth: Self.textWidth(displayedText)
        )
        guard abs(needed - lastReportedWidth) > 0.5 else { return }
        lastReportedWidth = needed
        onWidthNeeded?(needed)
    }

    // MARK: - 整理中

    /// 只覆盖清整理阶段：转译阶段不显示 loading，文字直接实时出现；
    /// 进入「整理中」后用整块胶囊背景做从左到右的进度填充。
    private var cleaningContent: some View {
        GeometryReader { geo in
            ZStack {
                // 用矩形从最左侧开始铺满整条高度，左端圆角交给外层 Capsule 裁切。
                // 这样填充色的左边缘与胶囊左边缘完全重合，不会露出浅色/异色的圆边。
                Rectangle()
                    .fill(cleaningFillColor)
                    .frame(
                        width: max(0, geo.size.width * cleaningProgress),
                        height: geo.size.height
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                Text("整理中")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.95))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func updateCleaningPresentation() {
        guard state.isCleaning else {
            guard showsCleaningOverlay else { return }
            cleaningIdleTicks += 1
            if cleaningIdleTicks > 7 {
                showsCleaningOverlay = false
                cleaningProgress = 0
            }
            return
        }
        cleaningIdleTicks = 0
        showsCleaningOverlay = true
        let total = max(0.8, state.cleaningEstimatedDuration)
        let tau = max(0.45, total / 3.0)
        let alpha = CGFloat(1 - exp(-cleaningTickInterval / tau))
        let creep: CGFloat = 0.0006
        cleaningProgress = min(
            cleaningProgressCap,
            cleaningProgress + max(creep, (cleaningProgressCap - cleaningProgress) * alpha)
        )
    }

    // MARK: - 逐字揭示

    private var bufferTargetText: String {
        state.bufferLines.joined()
    }

    private func advanceReveal() {
        let target = bufferTargetText
        let revealed = state.revealedBufferText
        guard target != revealed else { return }
        guard target.hasPrefix(revealed) else {
            // 清整理替换或清空：直接落到目标，不逐字。
            state.revealedBufferText = target
            return
        }
        let remaining = target.count - revealed.count
        let step: Int
        if remaining > 90 {
            step = 4
        } else if remaining > 30 {
            step = 2
        } else {
            step = 1
        }
        state.revealedBufferText = String(target.prefix(min(target.count, revealed.count + step)))
    }

    // MARK: - 音柱

    private var waveform: some View {
        Canvas { context, size in
            let _ = tick
            drawBars(in: &context, size: size)
        }
    }

    private func drawBars(in context: inout GraphicsContext, size: CGSize) {
        let frameCount = max(2, Int(data.sampleRate * displaySeconds))
        let raw = data.readLast(count: frameCount)
        guard !raw.isEmpty else { return }

        let inset: CGFloat = 1
        let contentWidth = max(4, size.width - inset * 2)
        let barWidth: CGFloat = 2.4
        let baseSpacing: CGFloat = 2.2
        let count = min(9, max(5, Int(contentWidth / (barWidth + baseSpacing))))
        let amplitudes = amplitudeBars(raw, count: count)

        let used = CGFloat(count) * barWidth + CGFloat(count - 1) * baseSpacing
        let extraGap = max(0, contentWidth - used) / CGFloat(max(1, count - 1))
        let spacing = baseSpacing + extraGap

        let midY = size.height / 2
        let maxHalf = max(3, size.height * 0.44)
        let minHalf: CGFloat = 1.2

        var path = Path()
        for (index, amplitude) in amplitudes.enumerated() {
            let half = max(CGFloat(amplitude) * maxHalf, minHalf)
            let x = inset + CGFloat(index) * (barWidth + spacing)
            let rect = CGRect(x: x, y: midY - half, width: barWidth, height: max(half * 2, 1))
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
        }
        context.fill(path, with: .color(state.isActive ? activeBarColor : standbyBarColor))
    }

    private func amplitudeBars(_ samples: [Float], count: Int) -> [Float] {
        var bars = [Float](repeating: 0, count: count)
        let bucket = max(1, samples.count / count)
        let gain = baseGain * Float(DictationSettings.waveformGainFactor(state.sensitivity))
        for i in 0..<count {
            let lo = i * bucket
            let hi = min(lo + bucket, samples.count)
            guard lo < hi else { continue }
            var peak: Float = 0
            for j in lo..<hi {
                peak = max(peak, abs(samples[j]))
            }
            bars[i] = min(1, max(0, peak - noiseFloor) * gain)
        }
        return bars
    }

    // MARK: - 底板

    @ViewBuilder
    private var capsuleBackground: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular.tint(panelGlassTint), in: Capsule())
        } else {
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(Color.black.opacity(0.6))
            }
        }
    }
}
