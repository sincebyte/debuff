import AppKit
import ApplicationServices
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class DebuffStatusBarController: NSObject, NSMenuDelegate {
    private let services: AppServices

    private var statusItem: NSStatusItem!
    private var rootMenu: NSMenu!

    private var itemThresholdParent: NSMenuItem!
    private var menuThreshold: NSMenu!
    private var thresholdValueItems: [NSMenuItem] = []

    private var itemSedentaryCustomName: NSMenuItem!
    private var itemSedentaryReset: NSMenuItem!
    private var itemWeChatCustomName: NSMenuItem!
    private var itemWeChatReset: NSMenuItem!
    private var itemFeishuCustomName: NSMenuItem!
    private var itemFeishuReset: NSMenuItem!

    private var itemSit: NSMenuItem!
    private var itemWeChatStatus: NSMenuItem!
    private var itemFeishuStatus: NSMenuItem!
    private var itemHUD: NSMenuItem!

    private var updateTimer: AnyCancellable?
    private var dataCancellables = Set<AnyCancellable>()

    init(services: AppServices) {
        self.services = services
        super.init()
        install()
    }

    private static let baseThresholdMinutes: [Double] = [
        0.1, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60
    ]

    // MARK: - 安装

    private func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let b = item.button {
            b.image = BundledAssets.menuBarIcon()
        }

        rootMenu = NSMenu()
        rootMenu.autoenablesItems = false
        rootMenu.delegate = self
        item.menu = rootMenu

        buildAllItems()
        bindData()
    }

    private func buildAllItems() {
        let monitor = services.monitor
        let clamped = Self.clampThreshold(monitor.thresholdMinutes)
        var choiceSet = Set(Self.baseThresholdMinutes)
        choiceSet.insert(clamped)

        // 久坐定时（子菜单，一次性构建；之后只改标题与对勾，不用 SwiftUI/整表重建）
        itemThresholdParent = NSMenuItem(title: thresholdLabel(minutes: clamped), action: nil, keyEquivalent: "")
        menuThreshold = NSMenu()
        buildThresholdSubmenu(choices: choiceSet.sorted(), selected: clamped)
        itemThresholdParent.submenu = menuThreshold
        rootMenu.addItem(itemThresholdParent)

        rootMenu.addItem(NSMenuItem.separator())

        addHeader("久坐图标")
        rootMenu.addItem(NSMenuItem(
            title: "选择图片…",
            action: #selector(pickSedentaryIcon),
            keyEquivalent: ""
        ).apply { $0.target = self })
        itemSedentaryReset = NSMenuItem(
            title: "恢复默认",
            action: #selector(clearSedentaryIcon),
            keyEquivalent: ""
        )
        itemSedentaryReset.target = self
        itemSedentaryReset.isHidden = services.monitor.customIconPath == nil
        rootMenu.addItem(itemSedentaryReset)
        itemSedentaryCustomName = NSMenuItem(
            title: fileName(services.monitor.customIconPath) ?? " ",
            action: nil,
            keyEquivalent: ""
        )
        itemSedentaryCustomName.isEnabled = false
        itemSedentaryCustomName.isHidden = services.monitor.customIconPath == nil
        rootMenu.addItem(itemSedentaryCustomName)

        addHeader("微信未读图标")
        rootMenu.addItem(NSMenuItem(
            title: "选择图片…",
            action: #selector(pickWeChatIcon),
            keyEquivalent: ""
        ).apply { $0.target = self })
        itemWeChatReset = NSMenuItem(
            title: "恢复默认",
            action: #selector(clearWeChatIcon),
            keyEquivalent: ""
        )
        itemWeChatReset.target = self
        itemWeChatReset.isHidden = services.weChat.weChatCustomIconPath == nil
        rootMenu.addItem(itemWeChatReset)
        itemWeChatCustomName = NSMenuItem(
            title: fileName(services.weChat.weChatCustomIconPath) ?? " ",
            action: nil,
            keyEquivalent: ""
        )
        itemWeChatCustomName.isEnabled = false
        itemWeChatCustomName.isHidden = services.weChat.weChatCustomIconPath == nil
        rootMenu.addItem(itemWeChatCustomName)

        addHeader("飞书未读图标")
        rootMenu.addItem(NSMenuItem(
            title: "选择图片…",
            action: #selector(pickFeishuIcon),
            keyEquivalent: ""
        ).apply { $0.target = self })
        itemFeishuReset = NSMenuItem(
            title: "恢复默认",
            action: #selector(clearFeishuIcon),
            keyEquivalent: ""
        )
        itemFeishuReset.target = self
        itemFeishuReset.isHidden = services.feishu.feishuCustomIconPath == nil
        rootMenu.addItem(itemFeishuReset)
        itemFeishuCustomName = NSMenuItem(
            title: fileName(services.feishu.feishuCustomIconPath) ?? " ",
            action: nil,
            keyEquivalent: ""
        )
        itemFeishuCustomName.isEnabled = false
        itemFeishuCustomName.isHidden = services.feishu.feishuCustomIconPath == nil
        rootMenu.addItem(itemFeishuCustomName)

        rootMenu.addItem(NSMenuItem.separator())

        itemSit = makeDisabled(sitLine)
        itemWeChatStatus = makeDisabled(weChatStatusLine)
        itemFeishuStatus = makeDisabled(feishuStatusLine)
        rootMenu.addItem(itemSit)
        rootMenu.addItem(itemWeChatStatus)
        rootMenu.addItem(itemFeishuStatus)

        rootMenu.addItem(NSMenuItem.separator())

        itemHUD = NSMenuItem(
            title: "显示 Debuff 状态",
            action: #selector(toggleHUD),
            keyEquivalent: ""
        )
        itemHUD.target = self
        itemHUD.setOn(services.debuffHUDVisibility.isEnabled, checkmark: true)
        itemHUD.toolTip = "关闭时隐藏屏幕上的微信 / 飞书 / 久坐 debuff 浮窗，不影响菜单栏图标与计时逻辑。"
        rootMenu.addItem(itemHUD)

        rootMenu.addItem(NSMenuItem(
            title: "退出",
            action: #selector(quit),
            keyEquivalent: "q"
        ).apply { $0.target = self })
    }

    private func addHeader(_ t: String) {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        i.isEnabled = false
        rootMenu.addItem(i)
    }

    // MARK: - 阈值

    private func buildThresholdSubmenu(choices: [Double], selected: Double) {
        menuThreshold.removeAllItems()
        thresholdValueItems = []
        let sel = Self.clampThreshold(selected)
        for m in choices {
            let label = String(format: "%.1f", m)
            let it = NSMenuItem(title: label, action: #selector(selectThreshold(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = NSNumber(value: m)
            it.state = abs(m - sel) < 0.0001 ? .on : .off
            menuThreshold.addItem(it)
            thresholdValueItems.append(it)
        }
    }

    private func thresholdLabel(minutes: Double) -> String {
        "久坐定时：\(String(format: "%.1f", Self.clampThreshold(minutes))) 分钟"
    }

    private static func clampThreshold(_ value: Double) -> Double {
        let c = min(240, max(0.1, value))
        return (c * 10).rounded() / 10
    }

    @objc private func selectThreshold(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        let v = Self.clampThreshold(n.doubleValue)
        services.monitor.thresholdMinutes = v
        services.panelBridge.sync()
        itemThresholdParent.title = thresholdLabel(minutes: v)
        var s = Set(Self.baseThresholdMinutes)
        s.insert(v)
        let newC = s.sorted()
        let current = thresholdValueItems.compactMap { ($0.representedObject as? NSNumber)?.doubleValue }
        if newC != current {
            buildThresholdSubmenu(choices: newC, selected: v)
        } else {
            for it in thresholdValueItems {
                guard let num = it.representedObject as? NSNumber else { continue }
                it.state = abs(num.doubleValue - v) < 0.0001 ? .on : .off
            }
        }
    }

    // MARK: - 行文案

    private var sitLine: String {
        let m = Date().timeIntervalSince(services.monitor.sessionStart) / 60
        return String(format: "当前久坐：%.1f 分钟", m)
    }

    private var weChatStatusLine: String {
        let w = services.weChat
        if w.weChatDebuffVisible {
            return String(format: "微信未读：%.1f 分钟", w.weChatMinutesForDisplay)
        }
        if !AXIsProcessTrusted() { return "微信未读：未授权辅助功能，无法读 Dock 角标" }
        return "微信未读：无"
    }

    private var feishuStatusLine: String {
        let f = services.feishu
        if f.feishuDebuffVisible {
            return String(format: "飞书未读：%.1f 分钟", f.feishuMinutesForDisplay)
        }
        if !AXIsProcessTrusted() { return "飞书未读：未授权辅助功能，无法读 Dock 角标" }
        return "飞书未读：无"
    }

    @objc private func pickSedentaryIcon() {
        pickImage(title: "选择久坐 Debuff 图标") { services.monitor.customIconPath = $0; services.panelBridge.sync() }
    }

    @objc private func clearSedentaryIcon() { services.monitor.customIconPath = nil; services.panelBridge.sync() }

    @objc private func pickWeChatIcon() {
        pickImage(title: "选择微信未读 Debuff 图标") { services.weChat.weChatCustomIconPath = $0; services.panelBridge.sync() }
    }

    @objc private func clearWeChatIcon() { services.weChat.weChatCustomIconPath = nil; services.panelBridge.sync() }

    @objc private func pickFeishuIcon() {
        pickImage(title: "选择飞书未读 Debuff 图标") { services.feishu.feishuCustomIconPath = $0; services.panelBridge.sync() }
    }

    @objc private func clearFeishuIcon() { services.feishu.feishuCustomIconPath = nil; services.panelBridge.sync() }

    @objc private func toggleHUD() {
        services.debuffHUDVisibility.isEnabled.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func pickImage(title: String, setPath: (String) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = title
        if panel.runModal() == .OK, let u = panel.url { setPath(u.path) }
    }

    private func makeDisabled(_ t: String) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    // MARK: - 刷新（只改 title，整棵 `NSMenu` 结构不替换，子菜单不会“被拆掉”）

    private func refreshStatusLineItems() {
        itemSit.title = sitLine
        itemWeChatStatus.title = weChatStatusLine
        itemFeishuStatus.title = feishuStatusLine
    }

    private func refreshSedentaryIconBlock() {
        let p = services.monitor.customIconPath
        let has = p != nil
        itemSedentaryReset.isHidden = !has
        itemSedentaryCustomName.isHidden = !has
        itemSedentaryCustomName.title = has ? (fileName(p) ?? "") : " "
    }

    private func refreshWeChatIconBlock() {
        let p = services.weChat.weChatCustomIconPath
        let has = p != nil
        itemWeChatReset.isHidden = !has
        itemWeChatCustomName.isHidden = !has
        itemWeChatCustomName.title = has ? (fileName(p) ?? "") : " "
    }

    private func refreshFeishuIconBlock() {
        let p = services.feishu.feishuCustomIconPath
        let has = p != nil
        itemFeishuReset.isHidden = !has
        itemFeishuCustomName.isHidden = !has
        itemFeishuCustomName.title = has ? (fileName(p) ?? "") : " "
    }

    private func fileName(_ p: String?) -> String? {
        guard let p, !p.isEmpty else { return nil }
        return (p as NSString).lastPathComponent
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu == rootMenu {
            refreshAllVisibleStrings()
        }
    }

    private func refreshAllVisibleStrings() {
        refreshStatusLineItems()
        refreshSedentaryIconBlock()
        refreshWeChatIconBlock()
        refreshFeishuIconBlock()
        itemHUD.setOn(services.debuffHUDVisibility.isEnabled, checkmark: true)
    }

    private func bindData() {
        // 定时更新状态行（不替换 rootMenu 结构；子菜单在展开时也不会因 title 被覆盖而关闭）
        updateTimer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshStatusLineItems()
            }
        // 监听阈值（例如 HUD 里清除导致 session 等），父项/对勾
        services.monitor.$thresholdMinutes
            .removeDuplicates { abs($0 - $1) < 0.0001 }
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] v in
                self?.onThresholdOrSessionExternal(v)
            }
            .store(in: &dataCancellables)
        // 外源修改路径时
        services.monitor.$customIconPath
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshSedentaryIconBlock() }
            .store(in: &dataCancellables)
        services.weChat.$weChatCustomIconPath
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshWeChatIconBlock() }
            .store(in: &dataCancellables)
        services.feishu.$feishuCustomIconPath
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshFeishuIconBlock() }
            .store(in: &dataCancellables)
        services.debuffHUDVisibility.$isEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] b in
                self?.itemHUD.setOn(b, checkmark: true)
            }
            .store(in: &dataCancellables)
    }

    private func onThresholdOrSessionExternal(_: Double) {
        let m = services.monitor.thresholdMinutes
        let v = Self.clampThreshold(m)
        var s = Set(Self.baseThresholdMinutes)
        s.insert(v)
        let newChoices = s.sorted()
        let current = thresholdValueItems.compactMap { ($0.representedObject as? NSNumber)?.doubleValue }
        if current != newChoices {
            buildThresholdSubmenu(choices: newChoices, selected: v)
        } else {
            for it in thresholdValueItems {
                guard let num = it.representedObject as? NSNumber else { continue }
                it.state = abs(num.doubleValue - v) < 0.0001 ? .on : .off
            }
        }
        itemThresholdParent.title = thresholdLabel(minutes: m)
    }
}

// MARK: - 小工具

private extension NSMenuItem {
    func setOn(_ on: Bool, checkmark: Bool) {
        state = on && checkmark ? .on : .off
    }

    func apply(_ block: (NSMenuItem) -> Void) -> NSMenuItem {
        block(self)
        return self
    }
}
