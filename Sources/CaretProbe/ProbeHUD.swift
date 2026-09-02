import AppKit

final class ProbeHUD {
    static let shared = ProbeHUD()

    private var textWindow: NSPanel?
    private var caretLineWindow: NSPanel?
    private var caretRectWindow: NSPanel?
    private var textView: NSTextView?

    func update(report: String, caretAXRect: CGRect?, elementAXRect: CGRect?) {
        if let rect = caretAXRect {
            showCaretLine(rect)
            showCaretRectOutline(rect)
        } else if let rect = elementAXRect {
            showCaretRectOutline(rect)
            hideCaretLine()
        } else {
            hideCaretLine()
            hideCaretRectOutline()
        }
        showReport(report)
    }

    func hideAll() {
        textWindow?.orderOut(nil)
        caretLineWindow?.orderOut(nil)
        caretRectWindow?.orderOut(nil)
    }

    private func makePanel(rect: NSRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }

    private func showCaretLine(_ axRect: CGRect) {
        let nsRect = Probe.nsRect(fromAXRect: axRect)
        let lineRect = NSRect(x: nsRect.minX, y: nsRect.minY, width: 2, height: max(nsRect.height, 4))
        let panel = caretLineWindow ?? makePanel(rect: lineRect)
        if panel.contentView == nil || caretLineWindow == nil {
            let view = NSView(frame: lineRect)
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.systemGreen.cgColor
            panel.contentView = view
        }
        caretLineWindow = panel
        panel.setFrame(lineRect, display: true)
        panel.orderFront(nil)
    }

    private func hideCaretLine() {
        caretLineWindow?.orderOut(nil)
    }

    private func showCaretRectOutline(_ axRect: CGRect) {
        let nsRect = Probe.nsRect(fromAXRect: axRect)
        let panel = caretRectWindow ?? makePanel(rect: nsRect)
        if caretRectWindow == nil {
            let view = CaretRectView(frame: nsRect)
            panel.contentView = view
        }
        caretRectWindow = panel
        panel.setFrame(nsRect, display: true)
        panel.orderFront(nil)
    }

    private func hideCaretRectOutline() {
        caretRectWindow?.orderOut(nil)
    }

    private func showReport(_ report: String) {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let textColor = NSColor.white
        let background = NSColor.black.withAlphaComponent(0.72)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]
        let attributed = NSAttributedString(string: report, attributes: attributes)

        let maxWidth: CGFloat = 920
        let bounding = attributed.boundingRect(
            with: NSSize(width: maxWidth, height: 100_000),
            options: [.usesLineFragmentOrigin]
        )
        let width = min(maxWidth, ceil(bounding.width) + 24)
        let height = min(ceil(bounding.height) + 16, 600)

        var screen = NSScreen.main
        if let caretRect = ProbeStore.shared.lastCaretAXRect {
            let caretNS = Probe.nsRect(fromAXRect: caretRect)
            screen = NSScreen.screens.first { $0.frame.intersects(caretNS) }
        }
        guard let target = screen else { return }
        let visible = target.visibleFrame
        let origin = NSPoint(x: visible.minX + 8, y: visible.maxY - height - 8)

        let textRect = NSRect(x: origin.x + 8, y: origin.y + 8, width: width - 16, height: height - 16)

        let panel = textWindow ?? makePanel(rect: NSRect(origin: origin, size: NSSize(width: width, height: height)))
        if textWindow == nil {
            let container = NSView(frame: NSRect(origin: origin, size: NSSize(width: width, height: height)))
            container.wantsLayer = true
            container.layer?.backgroundColor = background.cgColor
            container.layer?.cornerRadius = 8
            let tv = NSTextView(frame: textRect)
            tv.isEditable = false
            tv.isSelectable = true
            tv.drawsBackground = false
            tv.textContainerInset = NSSize(width: 0, height: 0)
            tv.textContainer?.widthTracksTextView = false
            tv.textContainer?.containerSize = NSSize(width: textRect.width, height: CGFloat.greatestFiniteMagnitude)
            tv.font = font
            tv.textColor = textColor
            container.addSubview(tv)
            panel.contentView = container
            textView = tv
        }
        textWindow = panel
        textView?.textStorage?.setAttributedString(attributed)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        panel.orderFront(nil)
    }
}

final class CaretRectView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(rect: bounds).fill()
    }
}
