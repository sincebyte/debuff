import AppKit
import SwiftUI

private let waveformMinWidth: CGFloat = 35
private let waveformMaxWidth: CGFloat = 400
private let waveformDefaultWidth: CGFloat = 167
/// 音柱栏高度（顶部固定区）：紧贴音柱，减少上下边框间的留白。
private let waveformHeight: CGFloat = 20
/// 音柱与缓冲文本区间距。
private let bufferSpacing: CGFloat = 2
/// 缓冲文本区高度：缓冲非空时向下展开，内部自动滚到最新。
private let bufferAreaHeight: CGFloat = 93
/// 面板外围底板的内边距（与视图层一致，保证高度精确匹配）。
private let boardPadding: CGFloat = 4
/// 顶部底板 + 音柱栏（含与文本区间距）留给拖拽，鼠标事件穿透给面板内容视图。
private let passThroughTopHeight: CGFloat = boardPadding + waveformHeight + bufferSpacing
/// 右缘留给拖拽调宽。
private let passThroughRightWidth: CGFloat = 12
/// 面板展开后的固定高度：波形 + 文本区，整体处于底板之上。
private var waveformPanelFullHeight: CGFloat {
    waveformHeight + bufferSpacing + bufferAreaHeight + boardPadding * 2
}
/// 收起文本区时的面板高度：只有底板包裹的波形。
private var waveformPanelCollapsedHeight: CGFloat {
    waveformHeight + boardPadding * 2
}

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

    func setListening(_ listening: Bool) {
        viewState.isListening = listening
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

    /// 更新缓冲文本：非空时正常亮度；为空时按配置保留非激活占位或收起。
    func setBuffer(_ lines: [String]) {
        viewState.bufferLines = lines
        viewState.showsBuffer = !lines.isEmpty
        updatePanelHeight()
    }

    /// 缓冲为空时的处理方式：保留非激活文本框，还是收起只留波形。
    func setEmptyBufferBehavior(_ behavior: DictationSettings.EmptyBufferBehavior) {
        viewState.keepsEmptyPlaceholder = (behavior == .inactive)
        updatePanelHeight()
    }

    /// 保持面板顶边不动，按「是否展开文本区」调整高度。
    private func updatePanelHeight() {
        guard let panel else { return }
        let expanded = viewState.showsBuffer || viewState.keepsEmptyPlaceholder
        let target = expanded ? waveformPanelFullHeight : waveformPanelCollapsedHeight
        var frame = panel.frame
        guard abs(frame.height - target) > 0.5 else { return }
        let top = frame.origin.y + frame.height
        frame.size.height = target
        frame.origin.y = top - target
        panel.setFrame(frame, display: true)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let size = NSSize(width: currentWidth, height: waveformPanelFullHeight)
        let host = PassThroughHostingView(
            rootView: DictationWaveformView(
                data: data,
                state: viewState
            )
        )
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
        updatePanelHeight()
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

/// 顶部音柱栏与右缘不拦截鼠标事件，让拖拽移动/拖拽调宽落到 `DraggableContentView`；
/// 其余区域（缓冲文本、下方按钮）交给 SwiftUI 处理滚轮滚动与点击。
/// `hitTest` 的坐标是 superview 坐标系，与 `frame` 一致。
private final class PassThroughHostingView: NSHostingView<DictationWaveformView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let topEdge = frame.maxY - passThroughTopHeight
        let rightEdge = frame.maxX - passThroughRightWidth
        if point.y > topEdge || point.x > rightEdge {
            return nil
        }
        return super.hitTest(point)
    }

    /// 面板非激活：首次点击也要落到按钮上，不能只用于激活窗口。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
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
