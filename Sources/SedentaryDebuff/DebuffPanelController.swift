import AppKit
import SwiftUI

/// 管理仿魔兽风格的置顶浮窗
final class DebuffPanelController {
    private var panel: NSPanel?

    func update(
        show: Bool,
        monitor: SedentaryMonitor,
        onDoubleClick: @escaping () -> Void
    ) {
        monitor.syncDebuffAnchorIfNeeded()

        guard show else {
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
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.contentView = host
            panel.setContentSize(size)
            position(panel: panel)
            self.panel = panel
        }

        panel?.orderFrontRegardless()
    }

    private func position(panel: NSPanel) {
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
