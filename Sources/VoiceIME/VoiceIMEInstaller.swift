import Foundation
import Carbon.HIToolbox

enum VoiceIMEIDs {
    static let bundleIdentifier = "com.van.debuff.VoiceIME"
    static let sourceID = "com.van.debuff.VoiceIME"
}

enum VoiceIMEInstaller {
    static var appURL: URL {
        Bundle.main.bundleURL
    }

    private static var inputSources: [String: TISInputSource] {
        var result: [String: TISInputSource] = [:]
        guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
            return result
        }
        for source in list {
            if let id = propertyString(source, kTISPropertyInputSourceID) {
                result[id] = source
            }
        }
        return result
    }

    static func register() {
        let sources = inputSources
        if sources[VoiceIMEIDs.sourceID] != nil {
            print("already registered: \(VoiceIMEIDs.sourceID)")
            return
        }
        let error = TISRegisterInputSource(appURL as CFURL)
        print("register \(error == noErr ? "ok" : "error \(error)") for \(appURL.path)")
    }

    static func enable() {
        let sources = inputSources
        guard let source = sources[VoiceIMEIDs.sourceID] else {
            print("input source not found yet: \(VoiceIMEIDs.sourceID)")
            return
        }
        if propertyBool(source, kTISPropertyInputSourceIsEnabled) == true {
            print("already enabled: \(VoiceIMEIDs.sourceID)")
            return
        }
        let error = TISEnableInputSource(source)
        print("enable \(error == noErr ? "ok" : "error \(error)") for \(VoiceIMEIDs.sourceID)")
    }

    static func disable() {
        let sources = inputSources
        guard let source = sources[VoiceIMEIDs.sourceID] else { return }
        if propertyBool(source, kTISPropertyInputSourceIsEnabled) == false {
            print("already disabled")
            return
        }
        let error = TISDisableInputSource(source)
        print("disable \(error == noErr ? "ok" : "error \(error)")")
    }

    static func select() {
        let sources = inputSources
        guard let source = sources[VoiceIMEIDs.sourceID] else {
            print("input source not found yet: \(VoiceIMEIDs.sourceID)")
            return
        }
        if propertyBool(source, kTISPropertyInputSourceIsEnabled) != true {
            enable()
        }
        let enabled = propertyBool(source, kTISPropertyInputSourceIsEnabled) == true
        let selectable = propertyBool(source, kTISPropertyInputSourceIsSelectCapable) == true
        let selected = propertyBool(source, kTISPropertyInputSourceIsSelected) == true
        guard enabled && selectable && !selected else {
            print("cannot select (enabled=\(enabled) selectable=\(selectable) selected=\(selected))")
            return
        }
        let error = TISSelectInputSource(source)
        print("select \(error == noErr ? "ok" : "error \(error)") for \(VoiceIMEIDs.sourceID)")
    }

    static func status() {
        let sources = inputSources
        guard let source = sources[VoiceIMEIDs.sourceID] else {
            print("status: not registered")
            return
        }
        print("status: enabled=\(propertyBool(source, kTISPropertyInputSourceIsEnabled) == true) selectable=\(propertyBool(source, kTISPropertyInputSourceIsSelectCapable) == true) selected=\(propertyBool(source, kTISPropertyInputSourceIsSelected) == true)")
    }

    static func listAll() {
        var all: [String] = []
        if let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] {
            for source in list {
                if let id = propertyString(source, kTISPropertyInputSourceID) {
                    all.append(id)
                }
            }
        }
        print("total input sources: \(all.count)")
        for id in all.sorted() {
            print("  \(id)")
        }
    }

    private static func propertyString(_ source: TISInputSource, _ key: CFString) -> String? {
        let ref = TISGetInputSourceProperty(source, key)
        guard let ref = ref else { return nil }
        return unsafeBitCast(ref, to: CFString.self) as String
    }

    private static func propertyBool(_ source: TISInputSource, _ key: CFString) -> Bool? {
        let ref = TISGetInputSourceProperty(source, key)
        guard let ref = ref else { return nil }
        return CFBooleanGetValue(unsafeBitCast(ref, to: CFBoolean.self))
    }
}
