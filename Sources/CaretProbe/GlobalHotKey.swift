import Carbon.HIToolbox

final class GlobalHotKey {
    static let shared = GlobalHotKey()

    private var probeHotKeyRef: EventHotKeyRef?
    private var hideHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    var onProbePress: (() -> Void)?
    var onHidePress: (() -> Void)?

    private let probeHotKeyID = EventHotKeyID(signature: 0x43525042, id: 1)
    private let hideHotKeyID = EventHotKeyID(signature: 0x43525048, id: 2)

    func install(probeKeyCode: UInt32, probeModifiers: UInt32, hideKeyCode: UInt32, hideModifiers: UInt32) -> Bool {
        let handler: EventHandlerUPP = { _, event, userData in
            guard let userData = userData else { return noErr }
            let selfRef = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return noErr }
            if hotKeyID.id == selfRef.probeHotKeyID.id {
                selfRef.onProbePress?()
            } else if hotKeyID.id == selfRef.hideHotKeyID.id {
                selfRef.onHidePress?()
            }
            return noErr
        }

        let unmanaged = Unmanaged.passUnretained(self).toOpaque()
        var handlerType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            handler,
            1,
            &handlerType,
            unmanaged,
            &eventHandlerRef
        )
        guard installStatus == noErr else { return false }

        var ok = true
        let probeStatus = RegisterEventHotKey(
            probeKeyCode,
            probeModifiers,
            probeHotKeyID,
            GetEventDispatcherTarget(),
            0,
            &probeHotKeyRef
        )
        if probeStatus != noErr { ok = false }

        let hideStatus = RegisterEventHotKey(
            hideKeyCode,
            hideModifiers,
            hideHotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hideHotKeyRef
        )
        if hideStatus != noErr { ok = false }

        return ok
    }

    func uninstall() {
        if let ref = probeHotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = hideHotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = eventHandlerRef { RemoveEventHandler(ref) }
    }
}
