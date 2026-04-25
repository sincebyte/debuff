import AppKit
import SwiftUI

/// 飞书未读 debuff：读 Dock 角标后，自最近一条新未读/计数变化起计时，立即显示（与微信同一路径）。
struct FeishuDebuffHUDView: View {
    @ObservedObject var feishu: FeishuDebuffMonitor

    private var borderImage: NSImage { BundledAssets.borderImage() }

    private let hudWidth: CGFloat = 50
    private let iconWidth: CGFloat = 40
    private var frameHeight: CGFloat {
        let b = borderImage.size
        guard b.width > 0 else { return hudWidth }
        return hudWidth * b.height / b.width
    }

    var body: some View {
        if feishu.showFeishuDebuff {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                hudContent
            }
        } else {
            hudContent
        }
    }

    private var hudContent: some View {
        VStack(spacing: 0) {
            ZStack {
                feishuIcon
                    .frame(width: iconWidth, height: iconWidth)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                Image(nsImage: borderImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: hudWidth, height: frameHeight)
            }
            .frame(width: hudWidth, height: hudWidth)

            DebuffTimeOutlinedText(string: formattedMinutes)
        }
        .help("飞书有未读：自最近新未读起计时；需在「隐私与安全性 → 辅助功能」中允许本应用以读取 Dock 角标。")
    }

    @ViewBuilder
    private var feishuIcon: some View {
        if let path = feishu.feishuCustomIconPath,
           let ns = NSImage(contentsOfFile: path) {
            Image(nsImage: ns)
                .resizable()
                .scaledToFill()
        } else {
            Image(nsImage: BundledAssets.feishuDebuffIcon())
                .resizable()
                .scaledToFill()
        }
    }

    private var formattedMinutes: String {
        String(format: "%.1fm", feishu.feishuMinutesForDisplay)
    }
}
