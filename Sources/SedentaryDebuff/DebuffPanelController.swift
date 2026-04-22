import AppKit
import SwiftUI

/// 管理仿魔兽风格的置顶浮窗
final class DebuffPanelController {
    private var panel: NSPanel?
    private var moveObserver: NSObjectProtocol?
    /// 每次隐藏浮窗时递增，用于丢弃已过期的「首帧后再显示」调度，避免 `orderOut` 后仍 `orderFront`
    private var visibilityEpoch = 0

    private enum HUDOriginPersistence {
        static let xKey = "SedentaryDebuff.hud.origin.x"
        static let yKey = "SedentaryDebuff.hud.origin.y"
        static let widthKey = "SedentaryDebuff.hud.frame.width"
        static let heightKey = "SedentaryDebuff.hud.frame.height"
    }

    deinit {
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
    }

    func update(
        show: Bool,
        monitor: SedentaryMonitor,
        onDoubleClick: @escaping () -> Void
    ) {
        guard show else {
            visibilityEpoch += 1
            panel?.orderOut(nil)
            return
        }

        let border = BundledAssets.borderImage()
        let hudWidth: CGFloat = 120
        let frameH: CGFloat = {
            let b = border.size
            guard b.width > 0 else { return hudWidth }
            return hudWidth * b.height / b.width
        }()
        let timerRow: CGFloat = 22
        let spacing: CGFloat = 6
        let size = NSSize(width: hudWidth, height: frameH + spacing + timerRow)

        if panel == nil {
            let content = DebuffHUDView(monitor: monitor, onDoubleClick: onDoubleClick)
                .environmentObject(monitor)
            let host = NSHostingView(rootView: AnyView(content))

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
            panel?.orderFrontRegardless()
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

    private func clampFrameToVisibleScreens(_ frame: NSRect) -> NSRect {
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            return frame
        }
        guard let screen = NSScreen.main else { return frame }
        let vf = screen.visibleFrame
        var f = frame
        f.origin.x = min(max(f.origin.x, vf.minX), max(vf.maxX - f.width, vf.minX))
        f.origin.y = min(max(f.origin.y, vf.minY), max(vf.maxY - f.height, vf.minY))
        return f
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

/// 允许双击接收，无需先激活应用
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
