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

    // 下面这些图都在 HUD 的 SwiftUI body 里取用，而 body 会随计时刷新反复求值。
    // `NSImage(contentsOf:)` 每次都做一次 bundle 查找 + 读盘 + PNG 解码（采样里
    // 空闲时占到近一成 CPU），所以统一在这里解码一次并复用。

    private static let border: NSImage = {
        if let url = bundle.url(forResource: "border", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return NSImage(size: NSSize(width: 68, height: 68))
    }()

    static func borderImage() -> NSImage { border }

    private static let debuffIcon: NSImage = {
        if let url = bundle.url(forResource: "sentinel-juggernautstance-128", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        if let sys = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) {
            return sys
        }
        return NSImage(size: NSSize(width: 64, height: 64))
    }()

    static func defaultDebuffIcon() -> NSImage { debuffIcon }

    /// 微信未读 debuff 图标（Terraria Silenced）
    private static let weChatIcon: NSImage = {
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
    }()

    static func weChatDebuffIcon() -> NSImage { weChatIcon }

    /// 飞书未读 debuff 默认图标
    private static let feishuIcon: NSImage = {
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
    }()

    static func feishuDebuffIcon() -> NSImage { feishuIcon }

    /// 菜单栏状态项图标（源图：`App/appicon.png`，经 SPM 打入包内）
    private static let statusBarIcon: NSImage = {
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
    }()

    static func menuBarIcon() -> NSImage { statusBarIcon }

    /// 用户自选图标（路径来自设置）：同一路径 + 同一修改时间只解码一次。
    /// 只应在主线程调用（SwiftUI body / 面板布局）。
    private static var customImages: [String: (mtime: Date?, image: NSImage)] = [:]

    static func customImage(atPath path: String?) -> NSImage? {
        guard let path, !path.isEmpty else { return nil }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let cached = customImages[path], cached.mtime == mtime {
            return cached.image
        }
        guard let image = NSImage(contentsOfFile: path) else {
            customImages[path] = nil
            return nil
        }
        customImages[path] = (mtime, image)
        return image
    }
}
