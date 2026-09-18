import AppKit
import SwiftUI

struct DictationWaveformView: View {
    let data: DictationWaveformData
    @ObservedObject var state: DictationWaveformViewState
    @State private var tick = 0
    /// 单一进度值（0…loadingCap）：转译与清整理共用同一条曲线，像一条普通进度条一样
    /// 匀速缓入、平滑逼近上限，中途不重置、不跳变、不改变推进速度。
    @State private var progress: CGFloat = 0
    /// loading 覆盖层是否可见。用「迟滞」方式开关：一旦开始处理立即显示，只有在
    /// 真正空闲一小段时间后才收起。这样转译结束与清整理开始之间那一瞬空档不会让
    /// 波形/麦克风图标闪出来，整条进度条从头到尾一气呵成。
    @State private var overlayVisible = false
    /// 连续空转的帧数（迟滞计时）。
    @State private var idleTicks = 0

    private let displaySeconds = 0.6
    private let gain: Float = 15.0
    private let noiseFloor: Float = 0.001
    /// 非激活(待命)状态的整体透明度：控件不再隐藏，常驻可见。
    private let standbyOpacity = 0.6
    /// 无缓冲文本时文本区的整体透明度：常驻但呈非激活态，而不是隐藏。
    private let emptyBufferOpacity = 0.35
    private let activeBarColor = Color(red: 0.3, green: 0.92, blue: 0.6)
    private let standbyBarColor = Color(red: 0.72, green: 0.72, blue: 0.75)
    /// 右侧麦克风图标占用的宽度：该处不绘制音柱，露出面板底板作为图标背景。
    private let micReserveWidth: CGFloat = 20
    /// 麦克风图标「先别说话」的灰色；绿色直接复用激活音柱色。
    private let micHoldColor = Color(red: 0.6, green: 0.6, blue: 0.64)
    private let micIconSize: CGFloat = 12
    /// 转写/清整理中的全宽进度条：单条曲线由快到慢自然逼近上限，结果返回时收起。
    /// 上限不到 100%，避免提前满格后长时间卡住。
    private let loadingCap: CGFloat = 0.94
    /// 计时器步长（秒），与上面的 0.033 定时器一致。
    private let tickInterval: Double = 0.033
    /// 比面板底色更深的进度条填充色。
    private let loadingFillColor = Color.black.opacity(0.45)
    private let loadingLabelSize: CGFloat = 11
    private let barHeight: CGFloat = 20
    /// 面板底板圆角。
    private let panelCornerRadius: CGFloat = 8
    /// 面板外围底板的内边距：底板完整包裹内容，录屏时中间无背景缝隙。
    private let boardPadding: CGFloat = 4
    /// 波形条与缓冲文本区间距（与布局层一致）。
    private let bufferSpacing: CGFloat = 2
    /// 缓冲文本滚动区高度。
    private let bufferAreaHeight: CGFloat = 93

    private let timer = Timer.publish(every: 0.033, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: bufferSpacing) {
            waveformBar
                .frame(height: barHeight)
            if state.showsBuffer || state.keepsEmptyPlaceholder {
                bufferScroll
                    .frame(height: bufferAreaHeight)
                    .opacity(state.showsBuffer ? 1.0 : emptyBufferOpacity)
                    .animation(.easeInOut(duration: 0.2), value: state.showsBuffer)
            }
        }
        .padding(boardPadding)
        // 顶对齐：面板增高/文字出现时波形固定在顶部，不会被内容重排挤动。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 转写进度条铺满波形区（含四周内边距），贴到面板左右/上最外缘、下抵文本区，
        // 不再留任何边框；靠这层裁剪让边缘落在圆角内。
        .overlay(alignment: .top) {
            if overlayVisible {
                transcribingProgress
                    .frame(height: loadingBandHeight)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
        .background(panelBackground)
        // 一旦开始处理立即显示覆盖层（不等下一帧），避免起点先闪一下波形；
        // 这里不重置进度：真正的新一轮由空闲迟滞归零，阶段交接不受影响。
        .onChange(of: state.showsLoading) { showing in
            if showing { overlayVisible = true }
        }
        .onAppear {
            if state.showsLoading { overlayVisible = true; progress = 0 }
        }
    }

    /// 统一底板：铺满整个面板，让波形与文本区之间没有透视到桌面的缝隙，
    /// 录屏时能稳定截取整块面板而不带背景干扰。无外边框，边界由内容自身处理。
    private var panelBackground: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color.black.opacity(0.6)
            GrainOverlay()
        }
        .clipShape(RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
    }

    private var waveformBar: some View {
        // 转写时整段波形让位，由 loading 覆盖；临近切段则在右缘叠加不透明倒计时。
        // 倒计时为叠加层，不参与布局，因此不会把波形挤窄。
        ZStack(alignment: .trailing) {
            Canvas { context, size in
                let _ = tick
                drawBars(in: &context, size: size)
            }
            // 直接画在统一底板上，不再单独给音柱做背景/边框；只让内容随激活态在
            // 透明度与颜色（激活绿 / 待命灰）上变化，整体与面板底板保持一致。
            .opacity(state.isActive ? state.activeOpacity : standbyOpacity)
            .animation(.easeInOut(duration: 0.2), value: state.isActive)
            // 覆盖整段波形：进度条在时波形整体隐去，铺满该区域。
            // 结果返回时波形与进度条同帧切换，显式禁用动画，避免「先亮波形、再退背景」的闪烁。
            .opacity(overlayVisible ? 0 : 1)
            .animation(nil, value: overlayVisible)

            // loading 时进度条独享整条，麦克风图标让位。
            if !overlayVisible {
                micBadge
            }
        }
        .onReceive(timer) { _ in
            // 每帧先更新进度/覆盖层的迟滞状态（与是否在监听无关），再决定是否需要重绘波形。
            updateLoadingPresentation()
            guard state.isActive || state.isListening || state.showsLoading || state.cutCountdown != nil else { return }
            tick += 1
        }
    }

    /// loading：深色进度条从 0 平滑推进，中央叠加当前阶段文案，铺满整段波形区。
    private var transcribingProgress: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle()
                    .fill(loadingFillColor)
                    .frame(width: geo.size.width * progress)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                Text("转译中")
                    .font(.system(size: loadingLabelSize, weight: .medium))
                    .foregroundColor(.white.opacity(0.95))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// 进度条覆盖高度：固定为「顶部内边距 + 波形条 + 底部内边距」，与下方是否有
    /// 缓冲文本无关。这样覆盖层高度恒定，中央的「转译中」始终居中在波形条上，
    /// 文字出现/消失时都不会产生 1pt 的上下抖动。
    private var loadingBandHeight: CGFloat {
        boardPadding + barHeight + boardPadding
    }

    /// 每帧推进进度并维护覆盖层的迟滞开关。
    /// - 处理中：立刻显示覆盖层，进度按指数缓动向 `loadingCap` 靠近；
    ///   整条流水线（转译 + 清整理）用固定预计总时长换算缓动常数，阶段切换速度不变；
    ///   再叠加极小匀速增量，接近上限时也持续缓慢前进。
    /// - 空闲：不立刻收起，只有连续空闲约 0.25 秒后才把覆盖层关掉、进度归零，
    ///   从而跨过转译→清整理之间的瞬时空档，波形与麦克风图标全程不闪。
    private func updateLoadingPresentation() {
        guard state.showsLoading else {
            guard overlayVisible else { return }
            idleTicks += 1
            if idleTicks > 7 {
                overlayVisible = false
                progress = 0
            }
            return
        }
        idleTicks = 0
        overlayVisible = true
        let estimatedTotal = Self.estimatedTotalSeconds(state: state)
        let tau = max(0.45, estimatedTotal / 3.0)
        let alpha = CGFloat(1 - exp(-tickInterval / tau))
        let creep: CGFloat = 0.0006
        progress = min(loadingCap, progress + max(creep, (loadingCap - progress) * alpha))
    }

    /// 整条流水线的固定预计耗时：转译音频估算 +（启用清整理时）约 1 秒的清整理固定开销。
    /// 刻意不随清整理文本长度变化，保证整段处理过程中缓动速度稳定、观感是一条进度条。
    private static func estimatedTotalSeconds(state: DictationWaveformViewState) -> TimeInterval {
        var total = state.loadingEstimatedDuration
        if state.cleanupFused { total += 1.0 }
        return max(0.6, total)
    }

    /// 右侧麦克风提示：常驻在波形右缘，用颜色而非数字表示当前能否说话。
    /// 绿色=可以说话；灰色=先别说话（临近强制切段，或未激活/待命）。
    private var micBadge: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: micIconSize, weight: .semibold))
            .foregroundColor(state.micHint == .go ? activeBarColor : micHoldColor)
            .frame(width: micReserveWidth, height: barHeight)
            .padding(.trailing, 2)
            .animation(.easeInOut(duration: 0.2), value: state.micHint)
    }

    /// 光波下方的滚动缓冲：逐段展示激活期间转写的文本，最新一句始终滚到底部。
    private var bufferScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(state.bufferLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.95))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .id(index)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bufferBottomID)
                }
                .padding(.horizontal, 8)
                .padding(.top, 1)
                .padding(.bottom, 8)
            }
            .onChange(of: state.bufferLines.count) { _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(Self.bufferBottomID, anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo(Self.bufferBottomID, anchor: .bottom)
            }
        }
    }

    private static let bufferBottomID = "buffer-bottom"

    private func drawBars(in context: inout GraphicsContext, size: CGSize) {
        let frameCount = max(2, Int(data.sampleRate * displaySeconds))
        let raw = data.readLast(count: frameCount)
        guard !raw.isEmpty else { return }

        let inset: CGFloat = 4
        // 麦克风图标常驻右侧一小段：该处不绘制音柱，露出底板作为图标背景。
        let rightReserve = micReserveWidth
        let contentWidth = max(4, size.width - inset * 2 - rightReserve)

        // 音柱固定宽度/间距，容器加宽时只增加柱数或拉大间距，绝不放大音柱
        let barWidth: CGFloat = 3.0
        let baseSpacing: CGFloat = 2.0
        let maxCount = 45
        let count = min(maxCount, max(4, Int(contentWidth / (barWidth + baseSpacing))))
        let amplitudes = amplitudeBars(raw, count: count)

        let used = CGFloat(count) * barWidth + CGFloat(count - 1) * baseSpacing
        let extraGap = max(0, contentWidth - used) / CGFloat(max(1, count - 1))
        let spacing = baseSpacing + extraGap

        let midY = size.height / 2
        // 音柱栏已收窄，放大占高比例让柱子仍接近原高度，同时贴近上下边框
        let maxHalf = max(3, size.height * 0.35)
        let minHalf: CGFloat = 1.5

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
}

/// 细噪点纹理：叠在毛玻璃上增强「磨砂」质感。
private struct GrainOverlay: View {
    var body: some View {
        GrainTexture.image
            .resizable(resizingMode: .tile)
            .blendMode(.softLight)
            .opacity(0.10)
            .allowsHitTesting(false)
    }
}

private enum GrainTexture {
    static let image: Image = {
        let side = 96
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        // 收窄灰度范围，降低颗粒对比，观感更均匀细腻。
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let value = UInt8.random(in: 112...144)
            pixels[index] = value
            pixels[index + 1] = value
            pixels[index + 2] = value
            pixels[index + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: side * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            return Image(systemName: "circle")
        }
        // scale 2：Retina 上 1 图像像素 = 1 物理像素，颗粒最细。
        return Image(decorative: cgImage, scale: 2, orientation: .up)
    }()
}
