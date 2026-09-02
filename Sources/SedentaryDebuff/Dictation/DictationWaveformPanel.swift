import AppKit
import SwiftUI

private let waveformMinWidth: CGFloat = 35
private let waveformMaxWidth: CGFloat = 400
private let waveformDefaultWidth: CGFloat = 167

final class DictationWaveformPanel {
    private var panel: NSPanel?
    private let data: DictationWaveformData
    private let viewState = DictationWaveformViewState()
    private var moveObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?

    private enum Persistence {
        static let xKey = "dictation.waveform.origin.x"
        static let yKey = "dictation.waveform.origin.y"
    }

    /// 宽度由设置驱动；拖拽/设置改变宽度时回调给控制器写回设置。
    var onWidthChange: ((CGFloat) -> Void)?

    private var currentWidth: CGFloat = waveformDefaultWidth

    init(data: DictationWaveformData) {
        self.data = data
    }

    func show() {
        ensurePanel()
        guard let panel else { return }
        restorePosition(panel)
        panel.orderFrontRegardless()
    }

    func setActive(_ active: Bool) {
        viewState.isActive = active
    }

    func setActiveOpacity(_ value: Double) {
        viewState.activeOpacity = value
    }

    func setWidth(_ width: CGFloat) {
        currentWidth = min(waveformMaxWidth, max(waveformMinWidth, width))
        guard let panel else { return }
        var frame = panel.frame
        frame.size.width = currentWidth
        panel.setFrame(frame, display: true)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let size = NSSize(width: currentWidth, height: 35)
        let host = PassThroughHostingView(rootView: DictationWaveformView(data: data, state: viewState))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        let content = DraggableContentView(frame: NSRect(origin: .zero, size: size))
        content.addSubview(host)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = false
        panel.isMovable = true
        panel.ignoresMouseEvents = false
        panel.contentView = content
        panel.setContentSize(size)
        self.panel = panel

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            self?.persistOrigin(from: window)
        }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            self?.onWidthChange?(window.frame.width)
        }
    }

    private func restorePosition(_ panel: NSPanel) {
        let defaults = UserDefaults.standard
        var frame = panel.frame
        var origin: NSPoint
        if defaults.object(forKey: Persistence.xKey) != nil,
           defaults.object(forKey: Persistence.yKey) != nil {
            origin = NSPoint(
                x: defaults.double(forKey: Persistence.xKey),
                y: defaults.double(forKey: Persistence.yKey)
            )
        } else {
            guard let screen = NSScreen.main else { return }
            origin = NSPoint(
                x: screen.visibleFrame.midX - frame.width / 2,
                y: screen.visibleFrame.maxY - frame.height - 48
            )
        }
        let screen = NSScreen.screens.first { $0.visibleFrame.contains(origin) } ?? NSScreen.main
        if let screen {
            let f = screen.visibleFrame
            origin.x = min(max(origin.x, f.minX + 6), max(f.minX + 6, f.maxX - frame.width - 6))
            origin.y = min(max(origin.y, f.minY + 6), max(f.minY + 6, f.maxY - frame.height - 6))
        }
        frame.origin = origin
        panel.setFrame(frame, display: false)
    }

    private func persistOrigin(from window: NSWindow) {
        let defaults = UserDefaults.standard
        defaults.set(window.frame.origin.x, forKey: Persistence.xKey)
        defaults.set(window.frame.origin.y, forKey: Persistence.yKey)
    }
}

/// 内容视图不拦截鼠标事件，保证拖拽事件落到 `DraggableContentView`。
private final class PassThroughHostingView: NSHostingView<DictationWaveformView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// 让无边框面板支持按窗口背景拖动（中间区域）与右边缘拖拽调宽。
private final class DraggableContentView: NSView {
    private enum DragMode {
        case none
        case move
        case resize
    }

    private var mode: DragMode = .none
    private var mouseStart: NSPoint?
    private var windowStart: NSPoint?
    private var startWidth: CGFloat = 0
    private let edgeWidth: CGFloat = 12

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.x >= bounds.width - edgeWidth {
            mode = .resize
            startWidth = window?.frame.width ?? 0
        } else {
            mode = .move
        }
        mouseStart = NSEvent.mouseLocation
        windowStart = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseStart, let windowStart, let window else { return }
        let current = NSEvent.mouseLocation
        switch mode {
        case .move:
            window.setFrameOrigin(NSPoint(
                x: windowStart.x + current.x - mouseStart.x,
                y: windowStart.y + current.y - mouseStart.y
            ))
        case .resize:
            let newWidth = min(waveformMaxWidth, max(waveformMinWidth, startWidth + current.x - mouseStart.x))
            var frame = window.frame
            frame.size.width = newWidth
            window.setFrame(frame, display: true)
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        mode = .none
        mouseStart = nil
        windowStart = nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(NSRect(x: bounds.width - edgeWidth, y: 0, width: edgeWidth, height: bounds.height), cursor: .resizeLeftRight)
    }
}
