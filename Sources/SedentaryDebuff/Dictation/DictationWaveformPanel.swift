import AppKit
import SwiftUI

private let waveformMinWidth: CGFloat = 35
private let waveformMaxWidth: CGFloat = 400
private let waveformDefaultWidth: CGFloat = 167
/// 音柱栏高度（顶部固定区）：紧贴音柱，减少上下边框间的留白。
private let waveformHeight: CGFloat = 20
/// 音柱与缓冲文本区间距。
private let bufferSpacing: CGFloat = 2
/// 缓冲文本区的固定高度：文字再多也不改变窗口高度，超出部分在文本区内部滚动。
private let bufferAreaHeight: CGFloat = 93
/// 面板外围底板的内边距（与视图层一致，保证高度精确匹配）。
private let boardPadding: CGFloat = 4
/// 面板圆角（与视图层 `panelCornerRadius` 一致）：用于 AppKit 层的内容视图硬裁，
/// 兜底保证 Liquid Glass 在透明无边框窗口里不会露出方形背板。
private let waveformPanelCornerRadius: CGFloat = 8
/// 顶部底板 + 音柱栏（含与文本区间距）留给拖拽，鼠标事件穿透给面板内容视图。
private let passThroughTopHeight: CGFloat = boardPadding + waveformHeight + bufferSpacing
/// 右缘留给拖拽调宽。
private let passThroughRightWidth: CGFloat = 12
/// 面板展开后的最大高度：波形 + 文本区，整体处于底板之上。
private var waveformPanelFullHeight: CGFloat {
    waveformHeight + bufferSpacing + bufferAreaHeight + boardPadding * 2
}
/// 经典横版胶囊的窗口高度：胶囊本体 + 四周阴影留白；宽度随文字动态变化。
private let classicBarWindowHeight: CGFloat =
    DictationClassicBarMetrics.barHeight + DictationClassicBarMetrics.shadowInset * 2

final class DictationWaveformPanel {
    private var panel: NSPanel?
    private let data: DictationWaveformData
    private let viewState = DictationWaveformViewState()
    private var moveObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    /// 当前风格：竖版玻璃或 type4me 经典横版胶囊。
    private var currentStyle: DictationSettings.PanelStyle = .glass
    /// 当前承载 SwiftUI 内容的视图（切风格时整体替换）。
    private var hostingView: PassThroughHostingView?

    private enum Persistence {
        static let xKey = "dictation.waveform.origin.x"
        static let yKey = "dictation.waveform.origin.y"
        /// 顶边 y：面板在「显示/收起文本区」时高度会变化，用顶边作锚点恢复位置才不会漂移。
        static let topKey = "dictation.waveform.top"
    }

    /// 宽度由设置驱动；拖拽/设置改变宽度时回调给控制器写回设置。
    var onWidthChange: ((CGFloat) -> Void)?
    /// 经典条拖右缘调整「最大宽度」后回调给控制器写回设置。
    var onClassicMaxWidthChange: ((CGFloat) -> Void)?

    private var currentWidth: CGFloat = waveformDefaultWidth
    /// 经典条当前胶囊宽度（不含阴影留白）：每次会话从最大宽度的一半起步。
    private var classicContentWidth: CGFloat = DictationClassicBarMetrics.initialWidth(
        forMax: DictationClassicBarMetrics.defaultMaxWidth
    )
    /// 用户拖右缘设定的「最大宽度」，持久化在设置里。
    private var classicMaxContentWidth: CGFloat = DictationClassicBarMetrics.defaultMaxWidth
    /// 本次会话手动拖过宽度后固定使用该值，不再随文字自适应；下次会话恢复。
    private var classicManualWidth: CGFloat?
    /// 视图最近一次上报的「文字完整放下所需宽度」。
    private var lastClassicNeededWidth: CGFloat = 0

    /// 收起/展开动画时长（秒）。
    private let revealDuration: TimeInterval = 0.22
    /// 文本区撑开/收起的动画时长（秒）：文本区出现/隐藏时面板高度平滑变化。
    private let heightRevealDuration: TimeInterval = 0.32
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
        // 每次会话都从「最大宽度的一半」重新起步；上一轮手动拖过的宽度不带到下一轮。
        if currentStyle == .classic {
            classicManualWidth = nil
            classicContentWidth = classicInitialWidth
        }
        ensurePanel()
        guard let panel else { return }
        restorePosition(panel)
        // 按当前状态落到展开/收起：右缘为锚点，收起态宽度为 0，展开时再由 0 推到 currentWidth。
        applyReveal(animated: false)
        if isExpanded { panel.orderFrontRegardless() }
    }

    func setActive(_ active: Bool) {
        // 离开激活即结束本轮会话：下一次激活重新按空缓冲的形态出现。
        if !active { viewState.keepsExpandedHeight = false }
        viewState.isActive = active
        applyReveal(animated: true)
        // 兜底：若展开时 stateChanged 恰为 false（例如面板此前被 orderOut 但 isExpanded 仍为真），
        // 非动画分支不会 orderFront，这里补一次，确保激活后波形一定可见。
        if active { panel?.orderFrontRegardless() }
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

    /// 展开条件：激活中；玻璃风格在转写/清整理收尾时也保持展开（进度条要看得见）；
    /// 经典条转译阶段不显示 loading，但清整理阶段的「整理中」进度需要可见，因此也保持展开。
    private var shouldReveal: Bool {
        viewState.isActive
            || (currentStyle == .glass && viewState.showsLoading)
            || (currentStyle == .classic && viewState.isCleaning)
    }

    /// 是否显示文本区（固定高度）：有缓冲文本、保留空态占位，或本次会话已经出现过文字
    /// （说「清空」/缓冲暂时为空时也保持高度，避免面板忽高忽低）。
    private var showsBufferArea: Bool {
        viewState.showsBuffer || viewState.keepsEmptyPlaceholder || viewState.keepsExpandedHeight
    }

    /// 经典条本次会话的起始胶囊宽度。
    private var classicInitialWidth: CGFloat {
        DictationClassicBarMetrics.initialWidth(forMax: classicMaxContentWidth)
    }

    /// 当前面板展开后的宽度：竖版取用户设置，经典风格取当前胶囊宽度 + 阴影留白。
    private var expandedWidth: CGFloat {
        if currentStyle == .classic {
            return classicContentWidth + DictationClassicBarMetrics.shadowInset * 2
        }
        return currentWidth
    }

    /// 当前状态对应的目标 frame：宽度右缘锚定（收起收向 0），高度顶边锚定。
    private func targetFrame() -> NSRect? {
        guard let panel else { return nil }
        let current = panel.frame
        let width = shouldReveal ? expandedWidth : 0
        let size = desiredFrameSize()
        return NSRect(
            x: current.maxX - width,
            y: current.maxY - size.height,
            width: width,
            height: size.height
        )
    }

    /// 面板应有的尺寸：竖版为「波形 + 固定高度文本区」，经典风格为动态胶囊窗口。
    private func desiredFrameSize() -> NSSize {
        if currentStyle == .classic {
            return NSSize(
                width: classicContentWidth + DictationClassicBarMetrics.shadowInset * 2,
                height: classicBarWindowHeight
            )
        }
        let areaHeight = currentBufferAreaHeight()
        let height = waveformHeight + boardPadding * 2 + (areaHeight > 0 ? bufferSpacing + areaHeight : 0)
        return NSSize(width: currentWidth, height: height)
    }

    /// 文本区当前应有的高度：显示时固定为 bufferAreaHeight，不随文字多少变化；
    /// 缓冲为空且不保留占位时收起为 0。
    private func currentBufferAreaHeight() -> CGFloat {
        showsBufferArea ? bufferAreaHeight : 0
    }

    /// 按展开条件调整面板宽度与高度：收起时把宽度收向 0（右缘不动），展开时从 0 推回
    /// currentWidth；文本区出现/隐藏时高度平滑变化，文字增长不再改变窗口高度。
    /// `animated` 为 false 时直接落到目标（用于首次显示，避免开场闪动）。
    private func applyReveal(animated: Bool) {
        let expanded = shouldReveal
        guard let panel, let target = targetFrame() else {
            isExpanded = expanded
            return
        }
        let stateChanged = expanded != isExpanded
        isExpanded = expanded
        panel.ignoresMouseEvents = !expanded

        let current = panel.frame
        let sizeChanged = abs(target.width - current.width) > 0.5
            || abs(target.height - current.height) > 0.5

        guard animated && currentStyle == .glass && (stateChanged || sizeChanged) else {
            // 动画进行中不要再插入同步 setFrame，否则会打断正在跑的收起/展开。
            guard !isRevealAnimating else { return }
            revealGeneration += 1
            panel.setFrame(target, display: true)
            if expanded {
                panel.orderFrontRegardless()
            } else {
                panel.orderOut(nil)
            }
            return
        }

        revealGeneration += 1
        let generation = revealGeneration
        isRevealAnimating = true
        if expanded { panel.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { context in
            // 宽度抽屉与高度撑开是两件事：只改高度（文字出现）时用较慢的撑开时长，
            // 让文字出现的同时面板慢慢长到最大高度。
            context.duration = stateChanged ? revealDuration : heightRevealDuration
            // 展开用 easeOut 快速推出、收起用 easeIn 加速收进，观感更像抽屉。
            context.timingFunction = CAMediaTimingFunction(name: expanded ? .easeOut : .easeIn)
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            guard let self, generation == self.revealGeneration else { return }
            self.isRevealAnimating = false
            // 完全收起后把窗口移出屏幕，避免 0 宽窗口残留。
            if !expanded {
                panel.orderOut(nil)
            } else if let target = self.targetFrame(), abs(target.height - panel.frame.height) > 0.5 || abs(target.width - panel.frame.width) > 0.5 {
                // 动画期间目标又变了（例如文字恰好在展开过程中到达）：直接补到最终目标。
                panel.setFrame(target, display: true)
            }
            // 高度/宽度动画结束后按顶边记住最终位置（动画中间的帧不写回）。
            self.persistOrigin(from: panel)
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

    /// 波形敏感度（0.1…1.0）：值越大，越小的声音也能把音柱顶高。
    func setSensitivity(_ value: Double) {
        viewState.sensitivity = DictationSettings.clampWaveformSensitivity(value)
    }

    func setWidth(_ width: CGFloat) {
        currentWidth = min(waveformMaxWidth, max(waveformMinWidth, width))
        // 经典风格使用自己的最大宽度，不跟随竖版的宽度设置；收起态只记录目标宽度。
        guard currentStyle == .glass, let panel, isExpanded else { return }
        // 宽度变化不再需要重算高度：文本区高度固定，宽度直接落到设置值（右缘不动）。
        var frame = panel.frame
        frame.origin.x = frame.maxX - currentWidth
        frame.size.width = currentWidth
        panel.setFrame(frame, display: true)
    }

    /// 应用持久化的经典条最大宽度（胶囊本体，不含阴影留白）。
    func setClassicMaxWidth(_ width: CGFloat) {
        let clamped = min(
            DictationClassicBarMetrics.maxMaxWidth,
            max(DictationClassicBarMetrics.minMaxWidth, width)
        )
        guard abs(clamped - classicMaxContentWidth) > 0.5 else { return }
        classicMaxContentWidth = clamped
        // 本次会话没有被手动拖过时，按新上限重新收放当前宽度。
        if currentStyle == .classic, classicManualWidth == nil {
            applyClassicFit(lastClassicNeededWidth)
        }
    }

    /// 经典条视图上报「当前文字完整放下所需宽度」。未手动拖过宽度时，把窗口从起始
    /// 宽度开始随文字增长撑到最大值；手动拖过则保持用户选的宽度到本轮结束。
    private func setClassicWidthNeeded(_ needed: CGFloat) {
        guard currentStyle == .classic else { return }
        lastClassicNeededWidth = needed
        guard classicManualWidth == nil else { return }
        applyClassicFit(needed)
    }

    private func applyClassicFit(_ needed: CGFloat) {
        guard currentStyle == .classic else { return }
        let target = min(classicMaxContentWidth, max(classicInitialWidth, needed))
        applyClassicContentWidth(target)
    }

    /// 把经典条窗口宽度落到指定胶囊宽度（左缘为锚点，文字向右撑开）。
    private func applyClassicContentWidth(_ content: CGFloat) {
        let clamped = min(classicMaxContentWidth, max(classicInitialWidth, content))
        let changed = abs(clamped - classicContentWidth) > 0.5
        classicContentWidth = clamped
        guard changed, let panel, isExpanded else { return }

        var frame = panel.frame
        frame.size = NSSize(
            width: clamped + DictationClassicBarMetrics.shadowInset * 2,
            height: classicBarWindowHeight
        )
        frame.origin.y = panel.frame.maxY - frame.height
        // 左缘优先不动（波形不跳）；如果向右撑出屏幕，再把整条往左推回来。
        if let screen = panel.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if frame.maxX > visible.maxX - 6 {
                frame.origin.x = max(visible.minX + 6, visible.maxX - 6 - frame.width)
            }
            if frame.origin.x < visible.minX + 6 {
                frame.origin.x = visible.minX + 6
            }
        }
        panel.setFrame(frame, display: true)
    }

    /// 用户拖经典条右缘：把拖出来的宽度同时作为本次会话宽度和新的最大宽度。
    private func handleClassicUserResize(windowWidth: CGFloat) {
        guard currentStyle == .classic, let panel else { return }
        let inset = DictationClassicBarMetrics.shadowInset
        let content = min(
            DictationClassicBarMetrics.maxMaxWidth,
            max(DictationClassicBarMetrics.minMaxWidth, windowWidth - inset * 2)
        )
        classicManualWidth = content
        classicContentWidth = content
        classicMaxContentWidth = content
        onClassicMaxWidthChange?(content)
        persistOrigin(from: panel)
    }

    /// 切换悬浮窗风格：立即替换 SwiftUI 根视图并重设窗口尺寸，以旧面板的展开态中心为
    /// 锚点，避免从 167pt 竖版切到 420pt 横版时整块面板跳到屏幕外。
    func setStyle(_ style: DictationSettings.PanelStyle) {
        guard style != currentStyle else { return }
        let oldWidth = expandedWidth
        if style == .classic {
            // 切到经典条时按最大宽度重新取起始宽度；视图重建后会再上报实际文字所需宽度。
            classicManualWidth = nil
            classicContentWidth = classicInitialWidth
        }
        currentStyle = style
        guard let panel else { return }

        let wasExpanded = isExpanded
        let centerX = wasExpanded ? panel.frame.midX : panel.frame.maxX - oldWidth / 2
        let top = panel.frame.maxY

        // 作废旧展开/收起动画的完成回调，避免它在切风格后把旧尺寸写回来。
        revealGeneration += 1
        isRevealAnimating = false

        rebuildHostingView(in: panel)
        applyStyleAppearance(to: panel)
        applyReveal(animated: false)

        let size = desiredFrameSize()
        var frame = NSRect(
            x: centerX - size.width / 2,
            y: top - size.height,
            width: wasExpanded ? size.width : 0,
            height: size.height
        )
        // 展开态宽度为 0 时右缘代表展开后的右缘，这样之后 applyReveal 的右缘抽屉才是对的。
        if !wasExpanded { frame.origin.x = centerX + size.width / 2 }
        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = min(
                max(frame.origin.x, visible.minX + 6),
                max(visible.minX + 6, visible.maxX - size.width - 6)
            )
            frame.origin.y = min(
                max(frame.origin.y, visible.minY + 6),
                max(visible.minY + 6, visible.maxY - size.height - 6)
            )
        }
        panel.setFrame(frame, display: true)
        isExpanded = wasExpanded
        if wasExpanded { panel.orderFrontRegardless() }
        persistOrigin(from: panel)
    }

    /// 更新缓冲文本：非空时正常亮度；为空时按配置保留非激活占位或收起。
    /// `keepsExpandedHeight` 只标记「本次会话出现过文字」：文本区出现后保持固定高度，
    /// 说「清空」或缓冲暂时为空时不缩回，直到离开激活。
    func setBuffer(_ lines: [String]) {
        viewState.bufferLines = lines
        viewState.showsBuffer = !lines.isEmpty
        if !lines.isEmpty { viewState.keepsExpandedHeight = true }
        updatePanelHeight()
    }

    /// 缓冲为空时的处理方式：保留非激活文本框，还是收起只留波形。
    func setEmptyBufferBehavior(_ behavior: DictationSettings.EmptyBufferBehavior) {
        viewState.keepsEmptyPlaceholder = (behavior == .inactive)
        updatePanelHeight()
    }

    /// 保持面板顶边不动，按「是否显示文本区」调整高度（文本区高度固定）。
    private func updatePanelHeight() {
        applyReveal(animated: true)
    }

    func hide() {
        // 复位展开/动画状态：否则残留的 isExpanded=true 会让下次 show() 认为无需切换，
        // 残留的 isRevealAnimating=true 会让后续非动画 setFrame 被守卫挡掉。
        revealGeneration += 1
        isRevealAnimating = false
        isExpanded = false
        viewState.keepsExpandedHeight = false
        viewState.isActive = false
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        // 首帧落在展开态尺寸，随后由 show() 的 applyReveal(animated: false) 落到目标态，
        // 非激活时直接以 0 宽出现，避免先展开再收起的闪动。
        let size = desiredFrameSize()
        let content = DraggableContentView(frame: NSRect(origin: .zero, size: size))
        content.allowsResize = true
        content.onResize = { [weak self] width in
            self?.handleClassicUserResize(windowWidth: width)
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Liquid Glass 会跟随系统外观：浅色模式下 `.regular` 玻璃是奶白磨砂，叠黑色 tint
        // 也会发灰白。把面板强制为深色外观，让玻璃按深色变体渲染 —— 既发黑，又保留毛玻璃
        // 的模糊/折射。面板内内容本就是白字，深色外观一致。
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = false
        panel.isMovable = true
        panel.ignoresMouseEvents = false
        // 收起态要把宽度收到 0，显式放开窗口最小尺寸，避免被系统下限卡住。
        panel.minSize = .zero
        panel.contentMinSize = .zero
        panel.contentView = content
        content.wantsLayer = true
        self.panel = panel
        applyStyleAppearance(to: panel)
        rebuildHostingView(in: panel)
        panel.setContentSize(size)
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
            // 经典风格宽度固定，不参与竖版的宽度设置。
            guard !self.isRevealAnimating, self.isExpanded, self.currentStyle == .glass else { return }
            self.currentWidth = window.frame.width
            self.onWidthChange?(window.frame.width)
        }
    }

    /// 用当前风格重建加载 SwiftUI 内容的宿主视图。切风格时整体替换，避免两种布局
    /// 共享同一棵视图树导致状态错位。
    private func rebuildHostingView(in panel: NSPanel) {
        hostingView?.removeFromSuperview()
        guard let content = panel.contentView else { return }
        let host = PassThroughHostingView(
            rootView: DictationPanelRootView(
                data: data,
                state: viewState,
                style: currentStyle,
                onClassicWidthNeeded: { [weak self] width in
                    self?.setClassicWidthNeeded(width)
                }
            ),
            style: currentStyle
        )
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        content.addSubview(host)
        hostingView = host
    }

    /// 按风格设置窗口内容层的圆角与拖拽行为：
    /// - 竖版：8pt 硬裁，兜底 Liquid Glass 的方形背板；右缘拖拽调宽。
    /// - 经典：内容层不裁（胶囊外的 4pt 留给自绘阴影）；整条胶囊都可拖动，
    ///   右缘拖拽调整「最大宽度」。
    private func applyStyleAppearance(to panel: NSPanel) {
        guard let content = panel.contentView else { return }
        content.wantsLayer = true
        content.layer?.cornerRadius = currentStyle == .glass ? waveformPanelCornerRadius : 0
        content.layer?.masksToBounds = currentStyle == .glass
        if let draggable = content as? DraggableContentView {
            draggable.allowsResize = true
            if currentStyle == .classic {
                let inset = DictationClassicBarMetrics.shadowInset
                let lower = DictationClassicBarMetrics.minMaxWidth + inset * 2
                let upper = DictationClassicBarMetrics.maxMaxWidth + inset * 2
                draggable.resizeRange = lower...upper
            } else {
                draggable.resizeRange = waveformMinWidth...waveformMaxWidth
            }
            draggable.window?.invalidateCursorRects(for: draggable)
        }
    }

    private func restorePosition(_ panel: NSPanel) {
        let defaults = UserDefaults.standard
        let size = desiredFrameSize()
        // 面板高度会随文字区伸缩，按「顶边」恢复位置：顶边固定，高度变化只向下扩展，
        // 否则每次重启都会因为高度不同而整体上下漂移。
        var origin: NSPoint
        if defaults.object(forKey: Persistence.topKey) != nil {
            let savedX = defaults.object(forKey: Persistence.xKey) != nil
                ? defaults.double(forKey: Persistence.xKey)
                : NSScreen.main.map { $0.visibleFrame.midX - size.width / 2 } ?? 0
            origin = NSPoint(
                x: savedX,
                y: defaults.double(forKey: Persistence.topKey) - size.height
            )
        } else if defaults.object(forKey: Persistence.xKey) != nil,
                  defaults.object(forKey: Persistence.yKey) != nil {
            // 旧版本只存了左缘与底边：先按底边恢复一次，之后再写入顶边。
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
        var frame = NSRect(origin: origin, size: size)
        let screen = NSScreen.screens.first { $0.visibleFrame.contains(origin) } ?? NSScreen.main
        if let screen {
            let f = screen.visibleFrame
            frame.origin.x = min(max(frame.origin.x, f.minX + 6), max(f.minX + 6, f.maxX - size.width - 6))
            frame.origin.y = min(max(frame.origin.y, f.minY + 6), max(f.minY + 6, f.maxY - size.height - 6))
        }
        panel.setFrame(frame, display: false)
    }

    private func persistOrigin(from window: NSWindow) {
        guard !isRevealAnimating else { return }
        let defaults = UserDefaults.standard
        // 收起态窗口左缘贴在右缘：写回展开态左缘，避免重启后整块面板整体右移。
        let originX = isExpanded ? window.frame.origin.x : window.frame.maxX - expandedWidth
        defaults.set(originX, forKey: Persistence.xKey)
        // 兼容旧版本读取底边；新版本按顶边恢复，避免文本区高度变化造成位置漂移。
        defaults.set(window.frame.origin.y, forKey: Persistence.yKey)
        defaults.set(window.frame.maxY, forKey: Persistence.topKey)
    }
}

/// 顶部音柱栏与右缘不拦截鼠标事件，让拖拽移动/拖拽调宽落到 `DraggableContentView`；
/// 其余区域（缓冲文本、下方按钮）交给 SwiftUI 处理滚轮滚动与点击。
/// `hitTest` 的坐标是 superview 坐标系，与 `frame` 一致。
private final class PassThroughHostingView: NSHostingView<DictationPanelRootView> {
    private var style: DictationSettings.PanelStyle

    init(rootView: DictationPanelRootView, style: DictationSettings.PanelStyle) {
        self.style = style
        super.init(rootView: rootView)
    }

    required init(rootView: DictationPanelRootView) {
        self.style = .glass
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 经典横版胶囊里没有按钮、也没有可滚动的文本区，整块窗口交给
        // `DraggableContentView`，按住任意位置都能拖动面板。
        if style == .classic { return nil }
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
    /// 是否允许右缘拖拽调宽（两种风格都允许，范围不同）。
    var allowsResize = true
    /// 右缘拖拽的窗口宽度范围（竖版 35…400，经典 160…416 + 阴影留白）。
    var resizeRange: ClosedRange<CGFloat> = waveformMinWidth...waveformMaxWidth
    /// 用户拖拽过程中实时回调窗口宽度；经典条用它同步「最大宽度」设置。
    var onResize: ((CGFloat) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if allowsResize && point.x >= bounds.width - edgeWidth {
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
            let newWidth = min(
                resizeRange.upperBound,
                max(resizeRange.lowerBound, startWidth + current.x - mouseStart.x)
            )
            var frame = window.frame
            frame.size.width = newWidth
            window.setFrame(frame, display: true)
            onResize?(newWidth)
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        mode = .none
        mouseStart = nil
        windowStart = nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // 经典条会随文字变宽，右缘光标区要跟着窗口宽度重算。
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard allowsResize else { return }
        addCursorRect(NSRect(x: bounds.width - edgeWidth, y: 0, width: edgeWidth, height: bounds.height), cursor: .resizeLeftRight)
    }
}
