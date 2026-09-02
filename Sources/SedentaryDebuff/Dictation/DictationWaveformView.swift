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
    private let activeBarColor = Color(red: 0.3, green: 0.92, blue: 0.6)
    private let standbyBarColor = Color(red: 0.72, green: 0.72, blue: 0.75)

    private let timer = Timer.publish(every: 0.033, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width, geo.size.height) / 2
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color(red: 65.0 / 255.0, green: 65.0 / 255.0, blue: 67.0 / 255.0), lineWidth: 0.5)
                Canvas { context, size in
                    let _ = tick
                    drawBars(in: &context, size: size)
                }
            }
        }
        .opacity(state.isActive ? state.activeOpacity : standbyOpacity)
        .animation(.easeInOut(duration: 0.2), value: state.isActive)
        .onReceive(timer) { _ in
            // 激活或待命监听期间持续刷新，让音柱随音频实时跳动（激活绿 / 待命灰）。
            guard state.isActive || state.isListening else { return }
            tick += 1
        }
    }

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
        // 两端圆角内弧形区域容纳不了太高柱子，缩短到半高的 50% 以内，避免超出边框
        let maxHalf = max(3, size.height * 0.25)
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
