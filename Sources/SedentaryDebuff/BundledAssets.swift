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
}
