import AppKit
import CoreText
import Foundation
import SwiftUI

/// 随包资源：`border.png` 为 debuff 外框；`sentinel-juggernautstance-128.png` 为久坐默认技能图标；`silenced.png` 为微信未读；`DepartureMono-Regular.otf` 在启动时注册。
enum BundledAssets {
    private static let bundle = Bundle.module

    /// 包内 Departure Mono Regular 的 PostScript 名，用于 `Font.custom`（需先 `registerBundledFonts()`）。
    private static let departureMonoPSName = "DepartureMono-Regular"

    static func departureMonoFont(size: CGFloat) -> Font {
        .custom(Self.departureMonoPSName, size: size)
    }

    static func registerBundledFonts() {
        guard let url = bundle.url(forResource: "DepartureMono-Regular", withExtension: "otf") else { return }
        var error: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
    }

    static func borderImage() -> NSImage {
        if let url = bundle.url(forResource: "border", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return NSImage(size: NSSize(width: 68, height: 68))
    }

    static func defaultDebuffIcon() -> NSImage {
        if let url = bundle.url(forResource: "sentinel-juggernautstance-128", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        if let sys = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) {
            return sys
        }
        return NSImage(size: NSSize(width: 64, height: 64))
    }

    /// 微信未读 debuff 图标（Terraria Silenced）
    static func weChatDebuffIcon() -> NSImage {
        if let url = bundle.url(forResource: "wechat", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        if let url = bundle.url(forResource: "ui_chat", withExtension: "jpg"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        if let sys = NSImage(systemSymbolName: "message.badge", accessibilityDescription: nil) {
            return sys
        }
        return NSImage(size: NSSize(width: 32, height: 32))
    }

    /// 飞书未读 debuff 默认图标
    static func feishuDebuffIcon() -> NSImage {
        if let url = bundle.url(forResource: "飞书", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        if let sys = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: nil) {
            return sys
        }
        if let sys = NSImage(systemSymbolName: "message", accessibilityDescription: nil) {
            return sys
        }
        return NSImage(size: NSSize(width: 32, height: 32))
    }

    /// 菜单栏状态项图标（源图：`App/appicon.png`，经 SPM 打入包内）
    static func menuBarIcon() -> NSImage {
        guard let url = bundle.url(forResource: "appicon", withExtension: "png"),
              let original = NSImage(contentsOf: url) else {
            if let sys = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil) {
                return sys
            }
            return NSImage(size: NSSize(width: 18, height: 18))
        }
        let target = NSSize(width: 18, height: 18)
        return NSImage(size: target, flipped: false) { rect in
            original.draw(
                in: rect,
                from: NSRect(origin: .zero, size: original.size),
                operation: .sourceOver,
                fraction: 1.0
            )
            return true
        }
    }
}
