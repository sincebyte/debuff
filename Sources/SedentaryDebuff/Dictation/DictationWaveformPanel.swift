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

    /// 收起/展开动画时长（秒）。
    private let revealDuration: TimeInterval = 0.22
    /// 当前是否处于展开态。展开时宽度为 currentWidth，收起时宽度收到 0（右缘保持不动）。
    private var isExpanded = false
    /// 展开/收起动画进行中：抑制窗口移动/缩放写回设置与位置，避免把动画中间帧持久化。
    private var isRevealAnimating = false
    /// 展开/收起代号：快速反复切换时作废旧动画的完成回调（否则旧的收起回调会误把面板 orderOut）。
    private var revealGeneration = 0

    init(data: DictationWaveformData) {
        self.data = data
    }

    func show() {
        ensurePanel()
        guard let panel else { return }
        restorePosition(panel)
        // 按当前状态落到展开/收起：右缘为锚点，收起态宽度为 0，展开时再由 0 推到 currentWidth。
        applyReveal(animated: false)
        if isExpanded { panel.orderFrontRegardless() }
    }

    func setActive(_ active: Bool) {
        viewState.isActive = active
        applyReveal(animated: true)
    }

    func setListening(_ listening: Bool) {
        viewState.isListening = listening
    }

    /// 有在途转写时波形区铺满转译进度条。estimatedDuration 为本次音频的预计耗时（秒），
    /// 用于按语音长短伸缩缓动曲线；已在 loading 时取较大值，避免新段落让进度提前逼近满格。
    func setTranscribing(_ transcribing: Bool, estimatedDuration: TimeInterval? = nil) {
        if let estimatedDuration {
            viewState.loadingEstimatedDuration = transcribing && viewState.isTranscribing
                ? max(viewState.loadingEstimatedDuration, estimatedDuration)
                : estimatedDuration
        }
        viewState.isTranscribing = transcribing
        applyReveal(animated: true)
    }

    /// 清整理（第二阶段）进行中：进度条接着转译阶段继续推进，文案切换为「整理中」。
    func setCleaning(_ cleaning: Bool, estimatedDuration: TimeInterval? = nil) {
        if let estimatedDuration {
            viewState.cleaningEstimatedDuration = cleaning && viewState.isCleaning
                ? max(viewState.cleaningEstimatedDuration, estimatedDuration)
                : estimatedDuration
        }
        viewState.isCleaning = cleaning
        applyReveal(animated: true)
    }

    /// 展开条件：激活中，或正在转写/清整理（收尾段的进度条也要看得见）。
    /// 其余（非激活待命）把整块宽度收向 0，右缘为锚点。
    private var shouldReveal: Bool {
        viewState.isActive || viewState.showsLoading
    }

    /// 按展开条件调整面板宽度：收起时把宽度收向 0（右缘不动），展开时从 0 推回 currentWidth。
    /// `animated` 为 false 时直接落到目标宽度（用于首次显示，避免开场闪动）。
    private func applyReveal(animated: Bool) {
        let expanded = shouldReveal
        guard let panel else {
            isExpanded = expanded
            return
        }
        let stateChanged = expanded != isExpanded
        isExpanded = expanded
        panel.ignoresMouseEvents = !expanded

        // 右缘固定：无论收起还是展开，都让 maxX 保持在当前值。
        let right = panel.frame.maxX
        var target = panel.frame
        target.size.width = expanded ? currentWidth : 0
        target.origin.x = right - target.size.width

        guard animated && stateChanged else {
            // 动画进行中不要再插入同步 setFrame，否则会打断正在跑的收起/展开。
            guard !isRevealAnimating else { return }
            revealGeneration += 1
            panel.setFrame(target, display: true)
            if !expanded { panel.orderOut(nil) }
            return
        }

        revealGeneration += 1
        let generation = revealGeneration
        isRevealAnimating = true
        if expanded { panel.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = revealDuration
            // 展开用 easeOut 快速推出、收起用 easeIn 加速收进，观感更像抽屉。
            context.timingFunction = CAMediaTimingFunction(name: expanded ? .easeOut : .easeIn)
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            guard let self, generation == self.revealGeneration else { return }
            self.isRevealAnimating = false
            // 完全收起后把窗口移出屏幕，避免 0 宽窗口残留。
            if !expanded { panel.orderOut(nil) }
        }
    }

    /// 是否启用「转译 → 清整理」两段式进度融合。
    func setCleanupFused(_ fused: Bool) {
        viewState.cleanupFused = fused
    }

    /// 临近最大切段的倒计时秒数（nil 表示不在预警窗口）。
    func setCutCountdown(_ seconds: Int?) {
        viewState.cutCountdown = seconds
    }

    func setActiveOpacity(_ value: Double) {
        viewState.activeOpacity = value
    }

    func setWidth(_ width: CGFloat) {
        currentWidth = min(waveformMaxWidth, max(waveformMinWidth, width))
        // 收起态只记录目标宽度，等展开时再生效，避免把 0 宽窗口撑开。
        guard let panel, isExpanded else { return }
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
        // 首帧落在展开态尺寸，随后由 show() 的 applyReveal(animated: false) 落到目标态，
        // 非激活时直接以 0 宽出现，避免先展开再收起的闪动。
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
        // 收起态要把宽度收到 0，显式放开窗口最小尺寸，避免被系统下限卡住。
        panel.minSize = .zero
        panel.contentMinSize = .zero
        panel.contentView = content
        panel.setContentSize(size)
        self.panel = panel
        applyReveal(animated: false)

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
            guard let self, let window = notification.object as? NSWindow else { return }
            // 收起/展开动画与收起态（宽度 0）不写回设置，只有用户拖拽或展开态尺寸算数。
            guard !self.isRevealAnimating, self.isExpanded else { return }
            self.onWidthChange?(window.frame.width)
        }
        updatePanelHeight()
    }

    private func restorePosition(_ panel: NSPanel) {
        let defaults = UserDefaults.standard
        var frame = panel.frame
        // 上一次可能停在收起态（宽度 0）：先按展开宽度算位置，再由 applyReveal 落到目标态。
        frame.size.width = currentWidth
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
        guard !isRevealAnimating else { return }
        let defaults = UserDefaults.standard
        // 收起态窗口左缘贴在右缘：写回展开态左缘，避免重启后整块面板整体右移。
        let originX = isExpanded ? window.frame.origin.x : window.frame.maxX - currentWidth
        defaults.set(originX, forKey: Persistence.xKey)
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
