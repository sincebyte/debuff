import AppKit
import SwiftUI

/// 微信未读 debuff：读 Dock 角标后，自最近一条「新消息/首次未读」起计时，立即显示。
struct WeChatDebuffHUDView: View {
    @ObservedObject var weChat: WeChatDebuffMonitor

    private var borderImage: NSImage { BundledAssets.borderImage() }

    private let hudWidth: CGFloat = 50
    private let iconWidth: CGFloat = 40
    private var frameHeight: CGFloat {
        let b = borderImage.size
        guard b.width > 0 else { return hudWidth }
        return hudWidth * b.height / b.width
    }

    var body: some View {
        if weChat.showWeChatDebuff {
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
                weChatIcon
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
        .help("微信有未读：自最近新消息起计时；需在「隐私与安全性 → 辅助功能」中允许本应用以读取 Dock 角标。")
    }

    @ViewBuilder
    private var weChatIcon: some View {
        if let path = weChat.weChatCustomIconPath,
           let ns = NSImage(contentsOfFile: path) {
            Image(nsImage: ns)
                .resizable()
                .scaledToFill()
        } else {
            Image(nsImage: BundledAssets.weChatDebuffIcon())
                .resizable()
                .scaledToFill()
        }
    }

    private var formattedMinutes: String {
        String(format: "%.1fm", weChat.weChatMinutesForDisplay)
    }
}

/// 与久坐 debuff 共用的描边时间文字
struct DebuffTimeOutlinedText: View {
    var string: String

    private static let minutesFill = Color(red: 0.95, green: 0.85, blue: 0.45)
    private static let minutesStrokeOffsets: [(CGFloat, CGFloat)] = [
        (-1, 0), (1, 0), (0, -1), (0, 1),
        (-1, -1), (-1, 1), (1, -1), (1, 1),
    ]

    var body: some View {
        ZStack {
            ForEach(0 ..< Self.minutesStrokeOffsets.count, id: \.self) { i in
                let dx = Self.minutesStrokeOffsets[i].0
                let dy = Self.minutesStrokeOffsets[i].1
                Text(string)
                    .font(BundledAssets.departureMonoFont(size: 14))
                    .foregroundStyle(Color.black)
                    .offset(x: dx, y: dy)
            }
            Text(string)
                .font(BundledAssets.departureMonoFont(size: 14))
                .foregroundStyle(Self.minutesFill)
        }
    }
}
