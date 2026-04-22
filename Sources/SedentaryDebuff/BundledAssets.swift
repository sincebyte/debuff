import AppKit
import Foundation

/// 随包资源：`border.png` 为 debuff 外框，`sentinel-juggernautstance-128.png` 为默认技能图标。
enum BundledAssets {
    private static let bundle = Bundle.module

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
