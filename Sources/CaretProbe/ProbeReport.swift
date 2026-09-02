import AppKit
import ApplicationServices

final class ProbeStore {
    static let shared = ProbeStore()
    var lastCaretAXRect: CGRect?
    var lastElementAXRect: CGRect?
}

enum Probe {
    static var enhanceFrontmost = false

    static func run() -> String {
        var lines: [String] = []

        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        lines.append("=== CaretProbe report  \(date.string(from: Date())) ===")

        let trusted = AXIsProcessTrusted()
        lines.append("process_ax_trusted = \(trusted)")
        if !trusted {
            lines.append("result = NOT_AX_TRUSTED")
            return lines.joined(separator: "\n")
        }

        guard let front = NSWorkspace.shared.frontmostApplication else {
            lines.append("result = NO_FRONTMOST_APP")
            return lines.joined(separator: "\n")
        }
        let pid = front.processIdentifier
        lines.append("frontmost_app = \(front.localizedName ?? "?")")
        lines.append("frontmost_pid = \(pid)")
        lines.append("frontmost_bundle = \(front.bundleIdentifier ?? "?")")
        lines.append("frontmost_is_self = \(pid == ProcessInfo.processInfo.processIdentifier)")

        if enhanceFrontmost {
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, 3.0)
            let err = AXUIElementSetAttributeValue(appElement, axEnhancedUserInterface, kCFBooleanTrue)
            lines.append("set_AXEnhancedUserInterface = err=\(axErrorName(err))")
            usleep(300_000)
        }

        let frontmostAppElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(frontmostAppElement, 3.0)

        var focusedElement: AXUIElement?
        var focusSource = "none"
        if pid != ProcessInfo.processInfo.processIdentifier {
            let systemWide = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(systemWide, 3.0)
            let (value, error) = AXSupport.copyAttribute(systemWide, kAXFocusedUIElementAttribute)
            if error == .success, let element = AXSupport.elementValue(value) {
                focusedElement = element
                focusSource = "systemWide(kAXFocusedUIElement)"
            } else {
                lines.append("syswide_focusedUIElement = error \(axErrorName(error))")
            }
        }
        if focusedElement == nil {
            let (value, error) = AXSupport.copyAttribute(frontmostAppElement, kAXFocusedUIElementAttribute)
            if error == .success, let element = AXSupport.elementValue(value) {
                focusedElement = element
                focusSource = "app(kAXFocusedUIElement on frontmostApp)"
            } else {
                lines.append("app_focusedUIElement = error \(axErrorName(error))")
            }
        }
        lines.append("focus_source = \(focusSource)")

        guard let element = focusedElement else {
            lines.append("result = NO_FOCUSED_ELEMENT")
            return lines.joined(separator: "\n")
        }
        AXUIElementSetMessagingTimeout(element, 3.0)
        ProbeStore.shared.lastCaretAXRect = nil
        ProbeStore.shared.lastElementAXRect = nil

        reportElementIdentity(element, into: &lines)
        reportTextDiagnostics(element, into: &lines)

        let mouseAXPoint = axPoint(fromNS: NSEvent.mouseLocation)
        lines.append("mouse_ns_point = \(NSEvent.mouseLocation)")
        lines.append("mouse_ax_point = \(mouseAXPoint)")

        let caret = estimateCaretAXRect(focused: element, lines: &lines)
        if let rect = caret.rect {
            lines.append("caret_rect_AX = \(describeAXRect(rect)) source=\(caret.source)")
            let nsRect = nsRect(fromAXRect: rect)
            lines.append("caret_rect_AppKit = \(NSStringFromRect(nsRect)) screen=\(screenNameContaining(nsRect)) source=\(caret.source)")
            ProbeStore.shared.lastCaretAXRect = rect
        } else {
            lines.append("caret_rect_AX = NONE")
            lines.append("caret_rect_AppKit = NONE")
        }

        if let elemRect = ProbeStore.shared.lastElementAXRect {
            lines.append("element_rect_AX = \(describeAXRect(elemRect))")
        }

        if let elementFrame = focusedFrameAX(element) {
            lines.append("focused_element_frame_AX = \(describeAXRect(elementFrame))")
        }

        reportRangeForMouse(element, mouseAXPoint, into: &lines)

        lines.append("result = DONE")
        return lines.joined(separator: "\n")
    }

    static func reportElementIdentity(_ element: AXUIElement, into lines: inout [String]) {
        let role = AXSupport.attrString(element, kAXRoleAttribute)
        let subrole = AXSupport.attrString(element, kAXSubroleAttribute)
        let roleDescription = AXSupport.attrString(element, kAXRoleDescriptionAttribute)
        let title = AXSupport.attrString(element, kAXTitleAttribute)
        let description = AXSupport.attrString(element, kAXDescriptionAttribute)
        lines.append("focused_ax_role = \(role)")
        lines.append("focused_ax_subrole = \(subrole)")
        lines.append("focused_ax_roleDescription = \(roleDescription)")
        if !title.isEmpty { lines.append("focused_ax_title = \(title)") }
        if !description.isEmpty { lines.append("focused_ax_description = \(description)") }

        let ancestors = ancestorRoles(element)
        lines.append("ancestor_roles = [\(ancestors.joined(separator: " -> "))]")
    }

    static func ancestorRoles(_ element: AXUIElement) -> [String] {
        var roles: [String] = []
        var current = element
        for _ in 0..<10 {
            let (value, error) = AXSupport.copyAttribute(current, kAXParentAttribute)
            guard error == .success, let parent = AXSupport.elementValue(value) else { break }
            current = parent
            let role = AXSupport.attrString(current, kAXRoleAttribute)
            if role.hasPrefix("<error") { break }
            roles.append(role)
            if role == kAXApplicationRole as String { break }
        }
        return roles
    }

    static func reportTextDiagnostics(_ element: AXUIElement, into lines: inout [String]) {
        let (rangeValue, rangeError) = AXSupport.copyAttribute(element, kAXSelectedTextRangeAttribute)
        if rangeError == .success {
            if let range = AXSupport.rangeValue(rangeValue) {
                lines.append("AXSelectedTextRange = location=\(range.location) length=\(range.length)")
            } else {
                lines.append("AXSelectedTextRange = <present but not a CFRange; CFTypeID=\(rangeValue.map { String(CFGetTypeID($0)) } ?? "nil")>")
            }
        } else {
            lines.append("AXSelectedTextRange = ERROR \(axErrorName(rangeError))")
        }

        let (lenValue, lenError) = AXSupport.copyAttribute(element, kAXNumberOfCharactersAttribute)
        if lenError == .success {
            if let count = AXSupport.numberValue(lenValue) {
                lines.append("AXNumberOfCharacters = \(Int(count))")
            } else {
                lines.append("AXNumberOfCharacters = <not a number>")
            }
        } else {
            lines.append("AXNumberOfCharacters = ERROR \(axErrorName(lenError))")
        }

        let (textValue, textError) = AXSupport.copyAttribute(element, kAXSelectedTextAttribute)
        if textError == .success, let text = AXSupport.stringValue(textValue) {
            lines.append("AXSelectedText = \"\(clip(text))\"")
        } else if textError != .success {
            lines.append("AXSelectedText = ERROR \(axErrorName(textError))")
        } else {
            lines.append("AXSelectedText = <non-string>")
        }

        let (valueValue, valueError) = AXSupport.copyAttribute(element, kAXValueAttribute)
        if valueError == .success, let text = AXSupport.stringValue(valueValue) {
            lines.append("AXValue(length) = \(text.utf16.count) sample=\"\(clip(text))\"")
        } else if valueError != .success {
            lines.append("AXValue = ERROR \(axErrorName(valueError))")
        } else {
            lines.append("AXValue = <non-string>")
        }
    }

    struct RangeProbe {
        var rect: CGRect?
        var error: AXError?

        var description: String {
            if let rect = rect {
                let empty = rect.width <= 0.1 || rect.height <= 0.1
                return describeAXRect(rect) + (empty ? " (EMPTY)" : "")
            }
            if let error = error { return "ERROR \(axErrorName(error))" }
            return "NONE"
        }
    }

    static func estimateCaretAXRect(focused: AXUIElement, lines: inout [String]) -> (rect: CGRect?, source: String) {
        let (rangeValue, rangeError) = AXSupport.copyAttribute(focused, kAXSelectedTextRangeAttribute)
        var range: CFRange?
        if rangeError == .success {
            range = AXSupport.rangeValue(rangeValue)
        } else {
            lines.append("caret_strategy.range = unavailable err=\(axErrorName(rangeError))")
        }

        if let range = range {
            let caret = range.location
            let length = numberOfCharacters(focused)
            lines.append("caret_index = \(caret)  document_length = \(length)")

            let zero = bounds(forRange: focused, location: caret, length: 0)
            lines.append("caret_strategy.boundsForRange(\(caret),0) = \(zero.description)")
            if let rect = nonEmpty(zero.rect) {
                return (rect, "AXBoundsForRange@caret")
            }

            if caret < length {
                let next = bounds(forRange: focused, location: caret, length: 1)
                lines.append("caret_strategy.boundsForRange(\(caret),1) = \(next.description)")
                if let rect = nonEmpty(next.rect) {
                    let leadingEdge = CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height)
                    return (leadingEdge, "AXBoundsForRange@nextChar-leadingEdge")
                }
            }

            if caret > 0 {
                let prev = bounds(forRange: focused, location: caret - 1, length: 1)
                lines.append("caret_strategy.boundsForRange(\(caret - 1),1) = \(prev.description)")
                if let rect = nonEmpty(prev.rect) {
                    let trailingEdge = CGRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height)
                    return (trailingEdge, "AXBoundsForRange@prevChar-trailingEdge")
                }
            }
        }

        let markerProbe = boundsForSelectedTextMarker(focused, lines: &lines)
        if let rect = nonEmpty(markerProbe) {
            return (rect, "AXBoundsForTextMarkerRange")
        }

        let elementFrame = focusedFrameAX(focused)
        ProbeStore.shared.lastElementAXRect = elementFrame
        if let frame = elementFrame, !frame.isEmpty {
            return (frame, "focusedElementFrame(fallback)")
        }

        let ancestor = firstFramefulAncestor(focused)
        ProbeStore.shared.lastElementAXRect = ancestor
        if let frame = ancestor, !frame.isEmpty {
            return (frame, "ancestorFrame(fallback)")
        }

        return (nil, "none")
    }

    static func describeAXRect(_ rect: CGRect) -> String {
        return String(format: "x=%.1f y=%.1f w=%.1f h=%.1f", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
    }

    static func nonEmpty(_ rect: CGRect?) -> CGRect? {
        guard let rect = rect, rect.width > 0.1, rect.height > 0.1 else { return nil }
        return rect
    }

    static func numberOfCharacters(_ element: AXUIElement) -> Int {
        let (value, error) = AXSupport.copyAttribute(element, kAXNumberOfCharactersAttribute)
        guard error == .success, let count = AXSupport.numberValue(value) else { return 0 }
        return Int(count)
    }

    static func bounds(forRange element: AXUIElement, location: Int, length: Int) -> RangeProbe {
        let parameter = AXSupport.range(location, length)
        let (value, error) = AXSupport.copyParameterized(element, kAXBoundsForRangeParameterizedAttribute, parameter)
        guard error == .success else { return RangeProbe(rect: nil, error: error) }
        return RangeProbe(rect: AXSupport.rectValue(value), error: nil)
    }

    static func boundsForSelectedTextMarker(_ element: AXUIElement, lines: inout [String]) -> CGRect? {
        let (rangeValue, rangeError) = AXSupport.copyAttribute(element, axSelectedTextMarkerRange)
        if rangeError != .success {
            lines.append("caret_strategy.textMarker = unavailable err=\(axErrorName(rangeError))")
            return nil
        }
        guard let markerRange = rangeValue else {
            lines.append("caret_strategy.textMarker = selectedMarkerRange nil")
            return nil
        }
        let (boundsValue, boundsError) = AXSupport.copyParameterized(element, axBoundsForTextMarkerRange, markerRange)
        if boundsError != .success {
            lines.append("caret_strategy.boundsForTextMarkerRange = ERROR \(axErrorName(boundsError))")
            return nil
        }
        guard let rect = AXSupport.rectValue(boundsValue) else {
            lines.append("caret_strategy.boundsForTextMarkerRange = <non-rect result>")
            return nil
        }
        lines.append("caret_strategy.boundsForTextMarkerRange = \(describeAXRect(rect))" + (rect.width > 0.1 && rect.height > 0.1 ? "" : " (EMPTY)"))
        return rect
    }

    static func focusedFrameAX(_ element: AXUIElement) -> CGRect? {
        let (positionValue, positionError) = AXSupport.copyAttribute(element, kAXPositionAttribute)
        let (sizeValue, sizeError) = AXSupport.copyAttribute(element, kAXSizeAttribute)
        guard positionError == .success, sizeError == .success,
              let point = AXSupport.pointValue(positionValue), let size = AXSupport.sizeValue(sizeValue) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    static func firstFramefulAncestor(_ element: AXUIElement) -> CGRect? {
        var current = element
        for _ in 0..<10 {
            let (value, error) = AXSupport.copyAttribute(current, kAXParentAttribute)
            guard error == .success, let parent = AXSupport.elementValue(value) else { return nil }
            current = parent
            if let frame = focusedFrameAX(current), !frame.isEmpty {
                return frame
            }
        }
        return nil
    }

    static func reportRangeForMouse(_ element: AXUIElement, _ mouseAX: CGPoint, into lines: inout [String]) {
        var point = mouseAX
        let parameter = AXValueCreate(axValueType(.point), &point)
        let (value, error) = AXSupport.copyParameterized(element, kAXRangeForPositionParameterizedAttribute, parameter!)
        if error == .success {
            if let range = AXSupport.rangeValue(value) {
                lines.append("AXRangeForPosition@mouse = location=\(range.location) length=\(range.length)")
            } else {
                lines.append("AXRangeForPosition@mouse = <non-range result>")
            }
        } else {
            lines.append("AXRangeForPosition@mouse = ERROR \(axErrorName(error))")
        }
    }

    static func clip(_ text: String, limit: Int = 120) -> String {
        if text.count <= limit { return text }
        return String(text.prefix(limit)) + "..."
    }

    static func axPoint(fromNS point: NSPoint) -> CGPoint {
        let top = virtualTop()
        return CGPoint(x: point.x, y: top - point.y)
    }

    static func nsPoint(fromAX point: CGPoint) -> CGPoint {
        let top = virtualTop()
        return CGPoint(x: point.x, y: top - point.y)
    }

    static func nsRect(fromAXRect rect: CGRect) -> NSRect {
        let top = virtualTop()
        let minY = top - rect.maxY
        return NSRect(x: rect.minX, y: minY, width: rect.width, height: rect.height)
    }

    static func virtualTop() -> CGFloat {
        return NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
    }

    static func screenNameContaining(_ rect: NSRect) -> String {
        for screen in NSScreen.screens where screen.frame.intersects(rect) {
            return screen.localizedName
        }
        return NSScreen.main?.localizedName ?? "?"
    }
}
