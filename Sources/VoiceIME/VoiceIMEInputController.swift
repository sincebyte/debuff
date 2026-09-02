import AppKit
import InputMethodKit
import Carbon.HIToolbox

final class VoiceIMEInputController: IMKInputController {
    private var client: IMKTextInput?

    private let demoKeyCode: UInt16 = 0x63

    override init!(server: IMKServer!, delegate: Any!, client: Any!) {
        self.client = client as? IMKTextInput
        super.init(server: server, delegate: delegate, client: client)
        VoiceIMELog.write("controller init clientBundle=\(self.client?.bundleIdentifier() ?? "?")")
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        self.client = sender as? IMKTextInput
        if event.keyCode == demoKeyCode && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            VoiceIMELog.write("F8 pressed, running demo")
            runDemo()
            return true
        }
        return false
    }

    override func activateServer(_ sender: Any!) {
        self.client = sender as? IMKTextInput
        VoiceIMELog.write("activateServer bundle=\(client?.bundleIdentifier() ?? "?")")
        super.activateServer(sender)
    }

    override func deactivateServer(_ sender: Any!) {
        VoiceIMELog.write("deactivateServer")
        client = nil
        VoiceIMECaretMarker.shared.hide()
        super.deactivateServer(sender)
    }

    private func runDemo() {
        guard let client = client else {
            VoiceIMELog.write("demo aborted: no client")
            return
        }
        let selected = client.selectedRange()
        let marked = client.markedRange()

        var actual = NSRange(location: 0, length: 0)
        let firstRect = client.firstRect(forCharacterRange: selected, actualRange: &actual)

        VoiceIMELog.write("bundle=\(client.bundleIdentifier() ?? "?")")
        VoiceIMELog.write("selectedRange=\(NSStringFromRange(selected)) markedRange=\(NSStringFromRange(marked))")
        VoiceIMELog.write("firstRect=\(NSStringFromRect(firstRect)) actual=\(NSStringFromRange(actual))")

        VoiceIMECaretMarker.shared.show(atScreenRect: firstRect)

        let sample = "VoiceIME-PoC✅"
        VoiceIMELog.write("inserting sample='\(sample)' at replacementRange=NSNotFound")
        client.insertText(sample, replacementRange: NSRange(location: NSNotFound, length: 0))
        VoiceIMELog.write("insert done")
    }
}
