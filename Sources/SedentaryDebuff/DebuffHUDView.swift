import AppKit
import SwiftUI

struct DebuffHUDView: View {
    @ObservedObject var monitor: SedentaryMonitor
    var onDoubleClick: () -> Void

    private var borderImage: NSImage { BundledAssets.borderImage() }

    /// 外框显示宽度；高度随 `border.png` 比例缩放
    private let hudWidth: CGFloat = 50
    // 图片icon显示宽度
    private let iconWidth: CGFloat = 40
    private var frameHeight: CGFloat {
        let b = borderImage.size
        guard b.width > 0 else { return hudWidth }
        return hudWidth * b.height / b.width
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                iconView
                    .frame(width: iconWidth , height: iconWidth )

                Image(nsImage: borderImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: hudWidth, height: frameHeight)
            }
            .frame(width: hudWidth, height: hudWidth)

            outlinedMinutesText(formattedMinutes)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onDoubleClick()
        }
        .help("双击清除久坐 debuff 并重新计时")
    }

    private var formattedMinutes: String {
        let m = monitor.debuffMinutesForDisplay
        return String(format: "%.1fm", m)
    }

    private static let minutesFont = Font.system(size: 14, weight: .thin, design: .serif)
    private static let minutesFill = Color(red: 0.95, green: 0.85, blue: 0.45)
    private static let minutesStrokeOffsets: [(CGFloat, CGFloat)] = [
        (-1, 0), (1, 0), (0, -1), (0, 1),
        (-1, -1), (-1, 1), (1, -1), (1, 1),
    ]

    private func outlinedMinutesText(_ string: String) -> some View {
        ZStack {
            ForEach(0 ..< Self.minutesStrokeOffsets.count, id: \.self) { i in
                let dx = Self.minutesStrokeOffsets[i].0
                let dy = Self.minutesStrokeOffsets[i].1
                Text(string)
                    .font(Self.minutesFont)
                    .foregroundStyle(Color.black)
                    .offset(x: dx, y: dy)
            }
            Text(string)
                .font(Self.minutesFont)
                .foregroundStyle(Self.minutesFill)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let path = monitor.customIconPath,
           let ns = NSImage(contentsOfFile: path) {
            Image(nsImage: ns)
                .resizable()
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(nsImage: BundledAssets.defaultDebuffIcon())
                .resizable()
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }
}
