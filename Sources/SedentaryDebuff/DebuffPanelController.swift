import AppKit
import SwiftUI

/// 管理仿魔兽风格的置顶浮窗
final class DebuffPanelController {
    private var panel: KeyablePanel?
    private var moveObserver: NSObjectProtocol?
    /// 显示器拔插/分辨率变化（锁屏唤醒后系统常常重排桌面）时，把浮窗拉回可见区域。
    private var screenObserver: NSObjectProtocol?
    /// 每次隐藏浮窗时递增，用于丢弃已过期的「首帧后再显示」调度，避免 `orderOut` 后仍 `orderFront`
    private var visibilityEpoch = 0

    private enum HUDOriginPersistence {
        static let xKey = "SedentaryDebuff.hud.origin.x"
        static let yKey = "SedentaryDebuff.hud.origin.y"
        static let widthKey = "SedentaryDebuff.hud.frame.width"
        static let heightKey = "SedentaryDebuff.hud.frame.height"
    }

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reclampVisiblePanel()
        }
    }

    deinit {
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func update(
        show: Bool,
        weChat: WeChatDebuffMonitor,
        feishu: FeishuDebuffMonitor,
        monitor: SedentaryMonitor,
        onSedentaryDoubleClick: @escaping () -> Void
    ) {
        guard show else {
            visibilityEpoch += 1
            panel?.orderOut(nil)
            return
        }

        let border = BundledAssets.borderImage()
        let colWidth: CGFloat = 50
        let gap: CGFloat = 6
        let weChatOn = weChat.showWeChatDebuff
        let feishuOn = feishu.showFeishuDebuff
        let sitOn = monitor.showDebuff
        let count = (weChatOn ? 1 : 0) + (feishuOn ? 1 : 0) + (sitOn ? 1 : 0)
        let contentW: CGFloat
        if count == 0 {
            contentW = 120
        } else if count == 1 {
            contentW = 120
        } else {
            let icons = colWidth * CGFloat(count) + gap * CGFloat(max(0, count - 1))
            contentW = icons
        }
        let panelWidth: CGFloat = max(120, contentW)
        let frameH: CGFloat = {
            let b = border.size
            let refW: CGFloat = 50
            guard b.width > 0 else { return refW }
            return refW * b.height / b.width
        }()
        let timerRow: CGFloat = 22
        let spacing: CGFloat = 6
        let size = NSSize(width: panelWidth, height: frameH + spacing + timerRow)

        if panel == nil {
            let content = CombinedDebuffHUDView(
                weChat: weChat,
                feishu: feishu,
                monitor: monitor
            )
            .environmentObject(monitor)
            let host = NSHostingView(rootView: AnyView(content))
            // 让 root 能占满内容区，否则 `Spacer` 无法把图标组顶到右侧（float right）
            host.sizingOptions = .minSize

            let panel = KeyablePanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            // `.floating` 过低，易被其他应用的文档/工具窗口压住；用 statusBar 档并 +1，贴近「总在最前」且仍低于系统弹出菜单档
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.contentView = host
            panel.setContentSize(size)
            self.panel = panel
            configureInteraction(panel: panel, monitor: monitor, onSedentaryDoubleClick: onSedentaryDoubleClick)
            // 立刻参与同 level 的 z-order，避免仅等 async 下一帧时才 orderFront，被当前前台 app 的绘制压在下面
            panel.orderFrontRegardless()

            // 等 SwiftUI / HostingView 完成首帧布局后再取 frame 并恢复，避免冷启动与上次 session 的窗口尺寸不一致导致 origin 看起来偏移
            let epochAtSchedule = visibilityEpoch
            DispatchQueue.main.async { [weak self] in
                guard let self, let panel = self.panel else { return }
                self.restoreOrDefaultPosition(panel: panel)
                if self.moveObserver == nil {
                    self.moveObserver = NotificationCenter.default.addObserver(
                        forName: NSWindow.didMoveNotification,
                        object: panel,
                        queue: .main
                    ) { [weak self] notification in
                        guard let window = notification.object as? NSWindow else { return }
                        self?.persistHUDOrigin(from: window)
                    }
                }
                if epochAtSchedule == self.visibilityEpoch {
                    panel.orderFrontRegardless()
                }
            }
        } else {
            guard let panel else { return }
            configureInteraction(panel: panel, monitor: monitor, onSedentaryDoubleClick: onSedentaryDoubleClick)
            // 若窗口因显示器重排/锁屏唤醒被系统留在了屏幕外，先把它拉回可见区域，再按
            // 「右缘不动」放大；否则会继续沿用离屏的左缘，新出现的槽位一直留在屏幕外。
            let visibleOld = clampFrameToVisibleScreens(panel.frame)
            if visibleOld.origin != panel.frame.origin {
                panel.setFrame(visibleOld, display: false)
            }
            // `setContentSize` 默认固定左下角：变宽时整窗向右长，右对齐的图标会「被挤向屏幕右侧」。
            // 先记下右缘与底边，改尺寸后再把 origin 左移，保持右缘不动，新出现的槽位向左扩展（与 float:right 一致）。
            let anchorMaxX = visibleOld.maxX
            let anchorMinY = visibleOld.minY
            panel.setContentSize(size)
            let newFrame = panel.frame
            // 放大后再次夹回可见区域，兼容「右缘本就在屏幕外」的历史持久化位置。
            let target = clampFrameToVisibleScreens(NSRect(
                x: anchorMaxX - newFrame.width,
                y: anchorMinY,
                width: newFrame.width,
                height: newFrame.height
            ))
            panel.setFrame(target, display: false)
            panel.orderFrontRegardless()
        }
    }

    /// 面板内容是一整块 `NSHostingView`：其 `hitTest` 会命中整个面板（空白处也一样），
    /// 且久坐视图原先的 SwiftUI 双击手势会吞掉 mouseDown，导致 `isMovableByWindowBackground`
    /// 在这些无边框非激活面板上无法起拖。这里改为在窗口层接管鼠标：拖动移动窗口、双击久坐图标清除。
    private func configureInteraction(
        panel: KeyablePanel,
        monitor: SedentaryMonitor,
        onSedentaryDoubleClick: @escaping () -> Void
    ) {
        panel.onSedentaryDoubleClick = onSedentaryDoubleClick
        panel.sedentaryHitRegion = { [weak monitor] bounds in
            guard let monitor, monitor.showDebuff else { return nil }
            // 久坐槽位固定在图标组最右侧，宽度与 `DebuffHUDView.hudWidth` 一致。
            let w: CGFloat = 50
            let width = min(w, bounds.width)
            return NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
        }
    }

    private func persistHUDOrigin(from window: NSWindow) {
        let f = window.frame
        let d = UserDefaults.standard
        d.set(f.origin.x, forKey: HUDOriginPersistence.xKey)
        d.set(f.origin.y, forKey: HUDOriginPersistence.yKey)
        d.set(Double(f.width), forKey: HUDOriginPersistence.widthKey)
        d.set(Double(f.height), forKey: HUDOriginPersistence.heightKey)
    }

    private func restoreOrDefaultPosition(panel: NSPanel) {
        let d = UserDefaults.standard
        guard d.object(forKey: HUDOriginPersistence.xKey) != nil,
              d.object(forKey: HUDOriginPersistence.yKey) != nil
        else {
            positionDefaultBottomRight(panel: panel)
            return
        }

        let cur = panel.frame
        let hasSavedSize = d.object(forKey: HUDOriginPersistence.widthKey) != nil
            && d.object(forKey: HUDOriginPersistence.heightKey) != nil

        let newFrame: NSRect
        if hasSavedSize {
            let saved = NSRect(
                x: d.double(forKey: HUDOriginPersistence.xKey),
                y: d.double(forKey: HUDOriginPersistence.yKey),
                width: d.double(forKey: HUDOriginPersistence.widthKey),
                height: d.double(forKey: HUDOriginPersistence.heightKey)
            )
            // 用上次窗口的「右下角 + 底边」对齐到当前窗口尺寸，避免仅保存 origin 时因高度/宽度在重启后变化产生漂移
            newFrame = NSRect(
                x: saved.maxX - cur.width,
                y: saved.minY,
                width: cur.width,
                height: cur.height
            )
        } else {
            let x = d.double(forKey: HUDOriginPersistence.xKey)
            let y = d.double(forKey: HUDOriginPersistence.yKey)
            var frame = cur
            frame.origin = NSPoint(x: x, y: y)
            newFrame = frame
        }

        let clamped = clampFrameToVisibleScreens(newFrame)
        panel.setFrame(clamped, display: false)
        if clamped.origin != newFrame.origin {
            persistHUDOrigin(from: panel)
        }
    }

    /// 把浮窗整体压回可见区域。始终夹一次（而非只在完全离屏时），因为「右缘贴屏边」的历史
    /// 坐标一旦被显示器重排带到屏幕外，浮窗会一直停在屏幕外，用户再也看不到它。
    private func clampFrameToVisibleScreens(_ frame: NSRect) -> NSRect {
        guard let screen = bestScreen(for: frame) else { return frame }
        let vf = screen.visibleFrame
        var f = frame
        f.origin.x = min(max(f.origin.x, vf.minX), max(vf.maxX - f.width, vf.minX))
        f.origin.y = min(max(f.origin.y, vf.minY), max(vf.maxY - f.height, vf.minY))
        return f
    }

    /// 选与窗口交集最大的屏幕；完全离屏时取中心最近的屏幕，最后退回主屏。
    private func bestScreen(for frame: NSRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return NSScreen.main }
        let best = screens.max { intersectionArea($0.visibleFrame, frame) < intersectionArea($1.visibleFrame, frame) }
        if let best, intersectionArea(best.visibleFrame, frame) > 0 {
            return best
        }
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return screens.min {
            distance(from: $0.visibleFrame, to: center) < distance(from: $1.visibleFrame, to: center)
        } ?? NSScreen.main
    }

    private func intersectionArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    private func distance(from rect: NSRect, to point: NSPoint) -> CGFloat {
        hypot(rect.midX - point.x, rect.midY - point.y)
    }

    /// 显示器参数变化（锁屏唤醒、插拔/切换显示器、改分辨率）后把可见浮窗拉回屏幕内。
    private func reclampVisiblePanel() {
        guard let panel, panel.isVisible else { return }
        let clamped = clampFrameToVisibleScreens(panel.frame)
        guard clamped.origin != panel.frame.origin else { return }
        // 移动会触发 `didMoveNotification`，由既有观察者写回新的位置。
        panel.setFrame(clamped, display: false)
    }

    private func positionDefaultBottomRight(panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let margin: CGFloat = 24
        let origin = NSPoint(
            x: frame.maxX - panel.frame.width - margin,
            y: frame.minY + margin
        )
        panel.setFrameOrigin(origin)
    }
}

/// 允许双击接收，无需先激活应用；并在无边框非激活面板上接管鼠标事件实现「按住拖动移动」。
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// 双击久坐图标：清除 debuff 并重新计时。
    var onSedentaryDoubleClick: (() -> Void)?
    /// 双击生效区域（内容视图坐标）。返回 nil 表示当前不响应双击（例如未显示久坐 debuff）。
    var sedentaryHitRegion: ((_ contentBounds: NSRect) -> NSRect?)?

    private var mouseStartScreen: NSPoint = .zero
    private var windowStartOrigin: NSPoint = .zero
    private var isDraggingWindow = false

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if event.clickCount == 2,
               let region = sedentaryHitRegion?(contentView?.bounds ?? .zero),
               let point = contentView.map({ $0.convert(event.locationInWindow, from: nil) }),
               region.contains(point) {
                onSedentaryDoubleClick?()
                isDraggingWindow = false
                return
            }
            mouseStartScreen = NSEvent.mouseLocation
            windowStartOrigin = frame.origin
            isDraggingWindow = false
            // 刻意不透传左键给 SwiftUI：其手势会吞掉 mouseDown，使窗口无法起拖。
        case .leftMouseDragged:
            let current = NSEvent.mouseLocation
            let dx = current.x - mouseStartScreen.x
            let dy = current.y - mouseStartScreen.y
            if !isDraggingWindow {
                // 先给一个死区，纯点击不移动窗口。
                guard abs(dx) >= 3 || abs(dy) >= 3 else { return }
                isDraggingWindow = true
            }
            setFrameOrigin(clampedOrigin(NSPoint(x: windowStartOrigin.x + dx, y: windowStartOrigin.y + dy)))
        case .leftMouseUp:
            isDraggingWindow = false
        default:
            super.sendEvent(event)
        }
    }

    /// 拖拽时把窗口限制在当前屏幕可见区域内，避免无边框面板被拖到屏幕外后彻底找不回。
    private func clampedOrigin(_ origin: NSPoint) -> NSPoint {
        let rect = NSRect(origin: origin, size: frame.size)
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return origin }
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let screen = screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? screens[0]
        let vf = screen.visibleFrame
        return NSPoint(
            x: min(max(origin.x, vf.minX), max(vf.minX, vf.maxX - frame.width)),
            y: min(max(origin.y, vf.minY), max(vf.minY, vf.maxY - frame.height))
        )
    }
}
