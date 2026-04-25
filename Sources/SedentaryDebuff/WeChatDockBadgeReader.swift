import AppKit
import ApplicationServices
import CoreFoundation

/// 经 Dock 辅助功能树读取「微信」图标的角标（`AXStatusLabel`）。
/// 注意：在部分系统上「标题 / 值」与 `AXStatusLabel` 不在同一层，会向上查找父链。
enum WeChatDockBadgeReader {
    private static let titleHints: Set<String> = ["微信", "WeChat"]
    private static let axTitle = "AXTitle" as CFString
    private static let axChildren = "AXChildren" as CFString
    private static let axStatusLabel = "AXStatusLabel" as CFString
    private static let axParent = "AXParent" as CFString
    private static let extraIdentity: [CFString] = [
        "AXValue" as CFString,
        "AXDescription" as CFString,
        "AXFileURL" as CFString,
        "AXURL" as CFString,
        "AXDocument" as CFString,
        "AXFilename" as CFString,
    ]

    static func readStatusLabel() -> String? {
        let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
        guard let app = dock.first else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        if let s = findByExactTitleMatch(in: root) { return s }
        return findByStatusNodesThenWeChatIdentity(in: root)
    }

    private static let maxDepth = 64

    /// 原先逻辑：角标与标题同节点
    private static func findByExactTitleMatch(in element: AXUIElement) -> String? {
        return findByExactTitleMatch(in: element, depth: 0)
    }

    private static func findByExactTitleMatch(in element: AXUIElement, depth: Int) -> String? {
        guard depth < maxDepth else { return nil }
        if let t = stringForAttribute(element, axTitle), titleHints.contains(t) {
            if let s = stringForAttribute(element, axStatusLabel) {
                return s
            }
        }
        guard let children = copyElementArray(element, axChildren) else { return nil }
        for c in children {
            if let s = findByExactTitleMatch(in: c, depth: depth + 1) { return s }
        }
        return nil
    }

    private static func findByStatusNodesThenWeChatIdentity(in root: AXUIElement) -> String? {
        var withStatus: [(String, AXUIElement)] = []
        collectStatusNodes(in: root, depth: 0, into: &withStatus)
        for (raw, el) in withStatus {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t != "0" else { continue }
            if isWeChatDockItem(el) { return raw }
        }
        return nil
    }

    private static func collectStatusNodes(in element: AXUIElement, depth: Int, into out: inout [(String, AXUIElement)]) {
        guard depth < maxDepth else { return }
        if let s = stringForAttribute(element, axStatusLabel) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, t != "0" {
                out.append((s, element))
            }
        }
        guard let children = copyElementArray(element, axChildren) else { return }
        for c in children {
            collectStatusNodes(in: c, depth: depth + 1, into: &out)
        }
    }

    /// 供飞书 Dock 读取等场景排除微信角标，避免与飞书检测串台。
    static func isWeChatDockItem(_ element: AXUIElement) -> Bool {
        if identityStringsMatchWeChat(in: element) { return true }
        var p = parentElement(element)
        for _ in 0 ..< 8 {
            guard let c = p else { break }
            if identityStringsMatchWeChat(in: c) { return true }
            p = parentElement(c)
        }
        return false
    }

    private static func toAXIfElement(_ o: AnyObject) -> AXUIElement? {
        let cf = o as CFTypeRef
        guard CFGetTypeID(cf) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(o, to: AXUIElement.self)
    }

    private static func parentElement(_ el: AXUIElement) -> AXUIElement? {
        var o: AnyObject?
        let r = AXUIElementCopyAttributeValue(el, axParent, &o)
        guard r == .success, let any = o else { return nil }
        return toAXIfElement(any)
    }

    private static func identityStringsMatchWeChat(in el: AXUIElement) -> Bool {
        var parts: [String] = []
        if let s = stringForAttribute(el, axTitle) { parts.append(s) }
        for k in extraIdentity {
            if let s = stringForAttribute(el, k) { parts.append(s) }
        }
        return isWeChatIdentity(components: parts, joined: parts.joined(separator: " "))
    }

    private static func isWeChatIdentity(components: [String], joined: String) -> Bool {
        for p in titleHints {
            for c in components {
                if c == p { return true }
            }
        }
        if joined.contains("微信") { return true }
        let l = joined.lowercased()
        if l.contains("wechat") { return true }
        if l.contains("tencent") && l.contains("wechat") { return true }
        if l.contains("xinwechat") || l.contains("com.tencent.xinwechat") { return true }
        for c in components {
            let l2 = c.lowercased()
            if l2.hasSuffix("wechat.app") { return true }
            if l2.contains("wechat.app/") { return true }
        }
        return false
    }

    // MARK: - 属性

    private static func stringForAttribute(_ el: AXUIElement, _ attr: CFString) -> String? {
        var v: AnyObject?
        let r = AXUIElementCopyAttributeValue(el, attr, &v)
        guard r == .success, let o = v else { return nil }
        if let s = o as? String { return s }
        if let n = o as? NSNumber { return n.stringValue }
        if let a = o as? NSAttributedString { return a.string }
        if let u = o as? URL { return u.path }
        return String(describing: o)
    }

    private static func copyElementArray(_ el: AXUIElement, _ attr: CFString) -> [AXUIElement]? {
        var v: AnyObject?
        let r = AXUIElementCopyAttributeValue(el, attr, &v)
        guard r == .success, let o = v else { return nil }
        if let a = o as? [AXUIElement] { return a }
        if let a = o as? NSArray {
            return (0 ..< a.count).compactMap { i in
                toAXIfElement(a.object(at: i) as AnyObject)
            }
        }
        return nil
    }
}
