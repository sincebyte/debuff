import AppKit
import SwiftUI

struct DictationWaveformView: View {
    let data: DictationWaveformData
    @ObservedObject var state: DictationWaveformViewState
    @State private var tick = 0

    private let displaySeconds = 0.6
    private let gain: Float = 15.0
    private let noiseFloor: Float = 0.001
    /// 非激活(待命)状态的整体透明度：控件不再隐藏，常驻可见。
    private let standbyOpacity = 0.6
    /// 无缓冲文本时文本区的整体透明度：常驻但呈非激活态，而不是隐藏。
    private let emptyBufferOpacity = 0.35
    private let activeBarColor = Color(red: 0.3, green: 0.92, blue: 0.6)
    private let standbyBarColor = Color(red: 0.72, green: 0.72, blue: 0.75)
    private let barHeight: CGFloat = 20
    /// 面板底板圆角。
    private let panelCornerRadius: CGFloat = 8
    /// 面板外围底板的内边距：底板完整包裹内容，录屏时中间无背景缝隙。
    private let boardPadding: CGFloat = 4
    /// 缓冲文本滚动区高度。
    private let bufferAreaHeight: CGFloat = 93

    private let timer = Timer.publish(every: 0.033, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 2) {
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
        .background(panelBackground)
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
        Canvas { context, size in
            let _ = tick
            drawBars(in: &context, size: size)
        }
        // 直接画在统一底板上，不再单独给音柱做背景/边框；只让内容随激活态在
        // 透明度与颜色（激活绿 / 待命灰）上变化，整体与面板底板保持一致。
        .opacity(state.isActive ? state.activeOpacity : standbyOpacity)
        .animation(.easeInOut(duration: 0.2), value: state.isActive)
        .onReceive(timer) { _ in
            // 激活或待命监听期间持续刷新，让音柱随音频实时跳动。
            guard state.isActive || state.isListening else { return }
            tick += 1
        }
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
        let contentWidth = max(4, size.width - inset * 2)

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
