import AppKit
import ApplicationServices

let axSelectedTextMarkerRange = "AXSelectedTextMarkerRange"
let axBoundsForTextMarkerRange = "AXBoundsForTextMarkerRange"
let axStartTextMarker = "AXStartTextMarker"
let axEndTextMarker = "AXEndTextMarker"
let axEnhancedUserInterface = "AXEnhancedUserInterface" as CFString
let axManualAccessibility = "AXManualAccessibility" as CFString

func axErrorName(_ error: AXError) -> String {
    switch error {
    case .success: return "success"
    case .failure: return "failure"
    case .illegalArgument: return "illegalArgument"
    case .invalidUIElement: return "invalidUIElement"
    case .invalidUIElementObserver: return "invalidUIElementObserver"
    case .cannotComplete: return "cannotComplete"
    case .attributeUnsupported: return "attributeUnsupported"
    case .actionUnsupported: return "actionUnsupported"
    case .notificationUnsupported: return "notificationUnsupported"
    case .notImplemented: return "notImplemented"
    case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
    case .notificationNotRegistered: return "notificationNotRegistered"
    case .apiDisabled: return "apiDisabled"
    case .noValue: return "noValue"
    case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
    case .notEnoughPrecision: return "notEnoughPrecision"
    default: return "unknown(\(error.rawValue))"
    }
}

enum AXValueKind: UInt32 {
    case illegal = 0
    case point = 1
    case size = 2
    case rect = 3
    case range = 4
    case axError = 5
}

func axValueType(_ kind: AXValueKind) -> AXValueType {
    return AXValueType(rawValue: kind.rawValue)!
}

func isAXValue(_ value: CFTypeRef?, ofKind kind: AXValueKind) -> Bool {
    guard let value = value else { return false }
    guard CFGetTypeID(value) == AXValueGetTypeID() else { return false }
    return AXValueGetType(value as! AXValue) == axValueType(kind)
}

enum AXSupport {
    static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> (CFTypeRef?, AXError) {
        let attr = attribute as CFString
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attr, &value)
        return (value, error)
    }

    static func copyParameterized(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> (CFTypeRef?, AXError) {
        let attr = attribute as CFString
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(element, attr, parameter, &value)
        return (value, error)
    }

    static func stringValue(_ value: CFTypeRef?) -> String? {
        guard let value = value else { return nil }
        if let string = value as? String { return string }
        if CFGetTypeID(value) == CFStringGetTypeID() { return value as? String }
        return nil
    }

    static func elementValue(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value = value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func numberValue(_ value: CFTypeRef?) -> Double? {
        guard let value = value else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    static func rangeValue(_ value: CFTypeRef?) -> CFRange? {
        guard let value = value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let type = AXValueGetType(value as! AXValue)
        guard type == axValueType(.range) else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value as! AXValue, type, &range) else { return nil }
        return range
    }

    static func pointValue(_ value: CFTypeRef?) -> CGPoint? {
        guard let value = value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let type = AXValueGetType(value as! AXValue)
        guard type == axValueType(.point) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, type, &point) else { return nil }
        return point
    }

    static func sizeValue(_ value: CFTypeRef?) -> CGSize? {
        guard let value = value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let type = AXValueGetType(value as! AXValue)
        guard type == axValueType(.size) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, type, &size) else { return nil }
        return size
    }

    static func rectValue(_ value: CFTypeRef?) -> CGRect? {
        guard let value = value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let type = AXValueGetType(value as! AXValue)
        guard type == axValueType(.rect) else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, type, &rect) else { return nil }
        return rect
    }

    static func range(_ location: Int, _ length: Int) -> CFTypeRef {
        var range = CFRange(location: location, length: length)
        let value = AXValueCreate(axValueType(.range), &range)
        return value!
    }

    static func attrString(_ element: AXUIElement, _ attribute: String) -> String {
        let (value, error) = copyAttribute(element, attribute)
        guard error == .success else {
            return "<error \(axErrorName(error))>"
        }
        guard let string = stringValue(value) else {
            return "<nil or non-string>"
        }
        return string
    }
}
