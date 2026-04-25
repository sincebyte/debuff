import AppKit
import ApplicationServices
import CoreFoundation

/// 经 Dock 辅助功能树读取飞书 / Lark 图标的角标（`AXStatusLabel`），与微信未读读法一致。
/// 注意：在部分系统上「标题 / 值」与 `AXStatusLabel` 不在同一层，会向上查找父链。
enum FeishuDockBadgeReader {
    private static let titleHints: Set<String> = ["飞书", "Feishu", "Lark", "LARK", "Lark 移动办公"]
    private static let axTitle = "AXTitle" as CFString
    private static let axChildren = "AXChildren" as CFString
    private static let axStatusLabel = "AXStatusLabel" as CFString
    private static let axParent = "AXParent" as CFString
    /// Dock 瓦片身份只用标题与路径类属性；不用 AXDescription/AXHelp（常含通知预览，易与微信消息文案串台）。
    private static let dockTilePathIdentity: [CFString] = [
        "AXFileURL" as CFString,
        "AXURL" as CFString,
        "AXDocument" as CFString,
        "AXFilename" as CFString,
        "AXIdentifier" as CFString,
    ]

    private static let maxDepth = 64
    private static let axValueFallback = "AXValue" as CFString

    static func readStatusLabel() -> String? {
        let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
        guard let app = dock.first else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        if let s = findByFeishuTitleMatch(in: root) { return s }
        return findByStatusNodesThenFeishuIdentity(in: root)
    }

    private static func findByFeishuTitleMatch(in element: AXUIElement) -> String? {
        findByFeishuTitleMatch(in: element, depth: 0)
    }

    private static func findByFeishuTitleMatch(in element: AXUIElement, depth: Int) -> String? {
        guard depth < maxDepth else { return nil }
        if feishuDockTileIdentityMatches(in: element) {
            if let s = stringForAttribute(element, axStatusLabel) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, t != "0" { return s }
            }
            for attr in [axValueFallback, "AXDescription" as CFString] {
                if let s = stringForAttribute(element, attr), looksLikeBadgeString(s) { return s }
            }
            if let s = firstBadgeStringInTree(element, depth: depth) { return s }
            if let s = firstBadgeInFeishuSiblingGroup(of: element, baseDepth: depth) { return s }
        }
        guard let children = copyElementArray(element, axChildren) else { return nil }
        for c in children {
            if let s = findByFeishuTitleMatch(in: c, depth: depth + 1) { return s }
        }
        return nil
    }

    private static func feishuDockTileIdentityMatches(in el: AXUIElement) -> Bool {
        if let t = stringForAttribute(el, axTitle), feishuTitleMatchesStrict(t) { return true }
        var pathParts: [String] = []
        for a in dockTilePathIdentity {
            if let s = stringForAttribute(el, a) { pathParts.append(s) }
        }
        let joined = pathParts.joined(separator: " ")
        if !joined.isEmpty, isFeishuIdentity(components: pathParts, joined: joined) { return true }
        return false
    }

    private static func firstBadgeStringInTree(_ element: AXUIElement, depth: Int) -> String? {
        guard depth < maxDepth else { return nil }
        if let s = stringForAttribute(element, axStatusLabel) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, t != "0" { return s }
        }
        if let s = stringForAttribute(element, axValueFallback), looksLikeBadgeString(s) { return s }
        if let s = stringForAttribute(element, "AXDescription" as CFString), looksLikeBadgeString(s) { return s }
        guard let children = copyElementArray(element, axChildren) else { return nil }
        for c in children {
            if let s = firstBadgeStringInTree(c, depth: depth + 1) { return s }
        }
        return nil
    }

    private static func firstBadgeInFeishuSiblingGroup(of element: AXUIElement, baseDepth: Int) -> String? {
        guard let parent = parentElement(element), let sibs = copyElementArray(parent, axChildren) else { return nil }
        var hasFeishuLabeled = false
        for s in sibs {
            if feishuDockTileIdentityMatches(in: s) { hasFeishuLabeled = true; break }
        }
        guard hasFeishuLabeled else { return nil }
        for s in sibs {
            guard feishuDockTileIdentityMatches(in: s) else { continue }
            if let b = firstBadgeStringInTree(s, depth: baseDepth) { return b }
        }
        return nil
    }

    /// 仅用 Dock 图标标题；避免对整串做裸 `"lark"` 子串匹配（易误中无关英文词）。
    private static func feishuTitleMatchesStrict(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if titleHints.contains(t) { return true }
        if t.contains("飞书") { return true }
        if t == "Lark" || t == "LARK" { return true }
        if t.hasPrefix("Lark ") || t.hasPrefix("Lark-") || t.hasPrefix("Lark(") { return true }
        if t.contains(" Lark ") { return true }
        if t.contains("飞") && t.contains("书") { return true }
        if t.range(of: "Larksuite", options: .caseInsensitive) != nil { return true }
        if t.contains("Lark 移动办公") { return true }
        return false
    }

    private static func looksLikeBadgeString(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s != "0" else { return false }
        if s == "99+" { return true }
        if s == "·" || s == "•" { return true }
        if s.count <= 4, s.allSatisfy({ $0.isNumber }) { return true }
        return false
    }

    private static func findByStatusNodesThenFeishuIdentity(in root: AXUIElement) -> String? {
        var withStatus: [(String, AXUIElement)] = []
        collectStatusNodes(in: root, depth: 0, into: &withStatus)
        for (raw, el) in withStatus {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t != "0" else { continue }
            if WeChatDockBadgeReader.isWeChatDockItem(el) { continue }
            if isFeishuDockItem(el) { return raw }
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
        } else if let s = stringForAttribute(element, axValueFallback), looksLikeBadgeString(s) {
            out.append((s, element))
        }
        guard let children = copyElementArray(element, axChildren) else { return }
        for c in children {
            collectStatusNodes(in: c, depth: depth + 1, into: &out)
        }
    }

    private static func isFeishuDockItem(_ element: AXUIElement) -> Bool {
        if identityStringsMatchFeishu(in: element) { return true }
        var p = parentElement(element)
        for _ in 0 ..< 8 {
            guard let c = p else { break }
            if identityStringsMatchFeishu(in: c) { return true }
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

    private static func identityStringsMatchFeishu(in el: AXUIElement) -> Bool {
        if WeChatDockBadgeReader.isWeChatDockItem(el) { return false }
        var parts: [String] = []
        if let s = stringForAttribute(el, axTitle) { parts.append(s) }
        for k in dockTilePathIdentity {
            if let s = stringForAttribute(el, k) { parts.append(s) }
        }
        return isFeishuIdentity(components: parts, joined: parts.joined(separator: " "))
    }

    private static func isFeishuIdentity(components: [String], joined: String) -> Bool {
        for p in titleHints {
            for c in components {
                if c == p { return true }
            }
        }
        if joined.contains("飞书") { return true }
        let l = joined.lowercased()
        if l.contains("larksuite") { return true }
        if l.contains("electron.lark") || l.contains("larkfeishu") { return true }
        if l.contains("lark.app") || l.contains("feishu.app") { return true }
        if l.contains("bytedance.ee") || l.contains("bytedance.lark") { return true }
        for c in components {
            if c.contains("飞书") { return true }
        }
        for c in components {
            let l2 = c.lowercased()
            if l2 == "lark" || l2 == "larkfeishu" { return true }
            if l2.hasSuffix("lark.app") || l2.hasSuffix("feishu.app") { return true }
        }
        return false
    }

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
