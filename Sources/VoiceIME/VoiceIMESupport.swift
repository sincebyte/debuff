import AppKit
import Carbon.HIToolbox

final class VoiceIMELog {
    static func write(_ line: String) {
        let stamp = DateFormatter()
        stamp.dateFormat = "HH:mm:ss.SSS"
        let message = "[\(stamp.string(from: Date()))] \(line)\n"
        if let handle = FileHandle(forWritingAtPath: "/tmp/voiceime.log") {
            handle.seekToEndOfFile()
            handle.write(message.data(using: .utf8)!)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: "/tmp/voiceime.log", contents: message.data(using: .utf8))
        }
    }
}

final class VoiceIMECaretMarker {
    static let shared = VoiceIMECaretMarker()
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    func show(atScreenRect rect: NSRect) {
        hideWorkItem?.cancel()
        let lineRect = NSRect(x: rect.minX, y: rect.minY, width: 2, height: max(rect.height, 6))
        let existing = panel ?? makePanel()
        if panel == nil {
            let view = NSView(frame: lineRect)
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.systemGreen.cgColor
            existing.contentView = view
        }
        panel = existing
        existing.setFrame(lineRect, display: true)
        existing.orderFront(nil)
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 2, height: 6),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }
}
