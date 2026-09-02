import AppKit
import SwiftUI

final class DictationWaveformPanel {
    private var panel: NSPanel?
    private let data: DictationWaveformData
    private let viewState = DictationWaveformViewState()
    private var moveObserver: NSObjectProtocol?

    private enum Persistence {
        static let xKey = "dictation.waveform.origin.x"
        static let yKey = "dictation.waveform.origin.y"
    }

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

    func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let size = NSSize(width: 167, height: 35)
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
    }

    private func restorePosition(_ panel: NSPanel) {
        let defaults = UserDefaults.standard
        let size = panel.frame.size
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
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.visibleFrame.maxY - size.height - 48
            )
        }
        let screen = NSScreen.screens.first { $0.visibleFrame.contains(origin) } ?? NSScreen.main
        if let screen {
            let frame = screen.visibleFrame
            origin.x = min(max(origin.x, frame.minX + 6), max(frame.minX + 6, frame.maxX - size.width - 6))
            origin.y = min(max(origin.y, frame.minY + 6), max(frame.minY + 6, frame.maxY - size.height - 6))
        }
        panel.setFrameOrigin(origin)
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

/// 让无边框面板支持按窗口背景拖动，并把位置变化交给 `didMoveNotification` 持久化。
private final class DraggableContentView: NSView {
    private var mouseStart: NSPoint?
    private var windowStart: NSPoint?

    override func mouseDown(with event: NSEvent) {
        mouseStart = NSEvent.mouseLocation
        windowStart = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseStart, let windowStart, let window else { return }
        // 用屏幕坐标（与 window.frame 同坐标系）算位移，
        // 避免 locationInWindow 相对已移动窗口的基准漂移导致拖拽距离减半、卡顿。
        let current = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(
            x: windowStart.x + current.x - mouseStart.x,
            y: windowStart.y + current.y - mouseStart.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        mouseStart = nil
        windowStart = nil
    }
}
