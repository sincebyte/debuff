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

    private var journalCheckbox: NSButton!
    private var itemJournalTodayText: NSMenuItem!
    private var itemJournalSavedTime: NSMenuItem!
    private var itemDictationURL: NSMenuItem!
    private var cleanupCheckbox: NSButton!
    private var itemDictationHotkey: NSMenuItem!
    private var itemMicParent: NSMenuItem!
    private var emptyBufferCheckbox: NSButton!
    private var micMenu: NSMenu!
    private var pauseValueButtons: [NSButton] = []
    private var maxSegmentValueButtons: [NSButton] = []

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

        buildDictationSection()

        rootMenu.addItem(NSMenuItem(
            title: "退出",
            action: #selector(quit),
            keyEquivalent: "q"
        ).apply { $0.target = self })
    }

    private func buildDictationSection() {
        let d = services.dictation
        let s = d.settings

        rootMenu.addItem(NSMenuItem.separator())

        let journalRow = checkmarkRow(
            title: journalToggleTitle,
            isOn: s.journalEnabled,
            toolTip: "开启后，激活语音转写并上屏/发送的内容会逐条带「日期+时分秒」追加到桌面 语音日记/当天日期.txt；非激活待命不后台录音转写，杂音不进日记。纯指令词（over/发送/清空等）不入日记。下方的今日字数与累计节约统计始终跟随激活语音输入累计，与是否写入桌面文件无关。",
            action: #selector(toggleJournal(_:))
        )
        journalCheckbox = journalRow.button
        rootMenu.addItem(journalRow.item)

        itemJournalTodayText = makeDisabled("")
        itemJournalTodayText.toolTip = "今日激活语音转写的字符数（跨自然日自动清零重计）。"
        rootMenu.addItem(itemJournalTodayText)
        itemJournalSavedTime = makeDisabled("")
        itemJournalSavedTime.toolTip = "按 \(Int(VoiceJournalStats.charsPerMinute)) 字/分钟的打字速度估算：转写 N 字 ≈ 节约 N/\(Int(VoiceJournalStats.charsPerMinute)) 分钟，历史语音输入折算的节约时间永久累计（满 \(VoiceJournalStats.workdayMinutes / 60) 小时记为 1 天）。"
        rootMenu.addItem(itemJournalSavedTime)

        let settingsMenu = NSMenu()

        settingsMenu.addItem(subHeader("停顿判定（秒）"))
        pauseValueButtons = []
        for (index, v) in DictationSettings.pausePresets.enumerated() {
            let row = radioRow(
                title: String(format: "%.1f 秒", v),
                isOn: abs(v - s.pauseSilenceSeconds) < 0.0001,
                tag: index,
                action: #selector(selectPause(_:))
            )
            settingsMenu.addItem(row.item)
            pauseValueButtons.append(row.button)
        }

        settingsMenu.addItem(NSMenuItem.separator())
        settingsMenu.addItem(subHeader("最大切段（秒）"))
        maxSegmentValueButtons = []
        for (index, v) in DictationSettings.maxSegmentPresets.enumerated() {
            let row = radioRow(
                title: "\(Int(v)) 秒",
                isOn: abs(v - s.maxSegmentSeconds) < 0.0001,
                tag: index,
                action: #selector(selectMaxSegment(_:))
            )
            settingsMenu.addItem(row.item)
            maxSegmentValueButtons.append(row.button)
        }

        settingsMenu.addItem(NSMenuItem.separator())
        let emptyBufferRow = checkmarkRow(
            title: "空文本时保留文本框",
            isOn: s.emptyBufferBehavior == .inactive,
            toolTip: "勾选：缓冲为空时保留文本框与按钮，以非激活（降低透明度）状态显示；不勾选：收起文本框与按钮，只保留波形。",
            action: #selector(toggleEmptyBufferBehavior(_:))
        )
        emptyBufferCheckbox = emptyBufferRow.button
        settingsMenu.addItem(emptyBufferRow.item)

        settingsMenu.addItem(NSMenuItem.separator())
        settingsMenu.addItem(subHeader("STT 服务地址"))
        itemDictationURL = makeDisabled(s.sttURLString)
        settingsMenu.addItem(itemDictationURL)
        settingsMenu.addItem(NSMenuItem(title: "输入地址…", action: #selector(editSTTURL), keyEquivalent: "").apply { $0.target = self })
        settingsMenu.addItem(NSMenuItem(title: "恢复默认", action: #selector(resetSTTURL), keyEquivalent: "").apply { $0.target = self })

        settingsMenu.addItem(NSMenuItem.separator())
        settingsMenu.addItem(subHeader("文本清整理（大模型）"))
        let cleanupRow = checkmarkRow(
            title: "启用清整理（错别字/重复词）",
            isOn: s.cleanupEnabled,
            toolTip: "开启后，每次 ASR 转写出的文字会拉通尚未整理的部分交给大模型做「清整理」：纠正错别字/同音字、删除重复词与口水词、补全标点。整理完成后才允许提交粘贴，确保上屏的是整理后的文本。",
            action: #selector(toggleCleanup(_:))
        )
        cleanupCheckbox = cleanupRow.button
        settingsMenu.addItem(cleanupRow.item)
        settingsMenu.addItem(NSMenuItem(title: "设置 DeepSeek API Key…", action: #selector(editCleanupKey), keyEquivalent: "").apply { $0.target = self })
        settingsMenu.addItem(NSMenuItem(title: "编辑提示词…", action: #selector(editCleanupPrompt), keyEquivalent: "").apply { $0.target = self })
        settingsMenu.addItem(NSMenuItem(title: "恢复默认", action: #selector(resetCleanup), keyEquivalent: "").apply { $0.target = self })

        settingsMenu.addItem(NSMenuItem.separator())
        settingsMenu.addItem(subHeader("快捷键"))
        itemDictationHotkey = makeDisabled(DictationHotKey.label(keyCode: s.hotkeyKeyCode, flags: s.hotkeyFlags))
        settingsMenu.addItem(itemDictationHotkey)

        let settingsParent = NSMenuItem(title: "设置", action: nil, keyEquivalent: "")
        settingsParent.submenu = settingsMenu
        rootMenu.addItem(settingsParent)

        itemMicParent = NSMenuItem(title: microphoneTitle, action: nil, keyEquivalent: "")
        micMenu = NSMenu()
        micMenu.delegate = self
        itemMicParent.submenu = micMenu
        rootMenu.addItem(itemMicParent)
        rebuildMicMenu()

        rootMenu.addItem(NSMenuItem(title: "测试 ASR 服务连接", action: #selector(testDictationConnection), keyEquivalent: "").apply { $0.target = self })
        rootMenu.addItem(NSMenuItem(title: "测试大语言模型连接", action: #selector(testCleanupConnection), keyEquivalent: "").apply { $0.target = self })
    }

    private var journalToggleTitle: String {
        "语音日记：记录激活语音到桌面"
    }

    private var journalTodayLine: String {
        let today = VoiceJournalStats.snapshot().todayChars
        return "今日语音输入：\(Self.grouped(today)) 字"
    }

    private var journalSavedLine: String {
        let total = VoiceJournalStats.snapshot().totalChars
        return "累计节约：\(VoiceJournalStats.savedTimeText(totalChars: total))"
    }

    private static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func addHeader(_ t: String) {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        i.isEnabled = false
        rootMenu.addItem(i)
    }

    private func subHeader(_ t: String) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
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

    @objc private func toggleJournal(_ sender: NSButton) {
        services.dictation.settings.journalEnabled = sender.state == .on
        refreshDictationItems()
    }

    @objc private func selectPause(_ sender: NSButton) {
        guard DictationSettings.pausePresets.indices.contains(sender.tag) else { return }
        services.dictation.settings.pauseSilenceSeconds = DictationSettings.pausePresets[sender.tag]
        refreshDictationItems()
    }

    @objc private func selectMaxSegment(_ sender: NSButton) {
        guard DictationSettings.maxSegmentPresets.indices.contains(sender.tag) else { return }
        services.dictation.settings.maxSegmentSeconds = DictationSettings.maxSegmentPresets[sender.tag]
        refreshDictationItems()
    }

    @objc private func toggleEmptyBufferBehavior(_ sender: NSButton) {
        services.dictation.settings.emptyBufferBehavior = sender.state == .on ? .inactive : .collapse
        services.dictation.applyEmptyBufferBehavior()
        refreshDictationItems()
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        // representedObject 存麦克风 uid；nil 表示「跟随系统默认」。
        let uid = sender.representedObject as? String
        services.dictation.settings.microphoneUID = uid
        services.dictation.applyMicrophoneInput()
        refreshDictationItems()
    }

    /// 当前麦克风标题：选中了具体设备则显示其名称，否则显示「跟随系统默认（当前：X）」。
    private var microphoneTitle: String {
        let s = services.dictation.settings
        if let uid = s.microphoneUID {
            let name = DictationMicrophone.name(forUID: uid) ?? "所选设备已断开"
            return "麦克风：\(name)"
        }
        let defaultName = DictationMicrophone.defaultInputDeviceName() ?? "无输入设备"
        return "麦克风：跟随系统默认（\(defaultName)）"
    }

    /// 重建「麦克风」子菜单：跟随系统默认 + 当前在线的输入设备列表。
    private func rebuildMicMenu() {
        guard micMenu != nil else { return }
        micMenu.removeAllItems()
        let s = services.dictation.settings
        let follow = NSMenuItem(title: "跟随系统默认", action: #selector(selectMicrophone(_:)), keyEquivalent: "")
        follow.target = self
        follow.representedObject = nil
        follow.state = s.microphoneUID == nil ? .on : .off
        micMenu.addItem(follow)
        micMenu.addItem(NSMenuItem.separator())
        let devices = DictationMicrophone.availableInputDevices()
        if devices.isEmpty {
            let empty = makeDisabled("未找到输入设备")
            micMenu.addItem(empty)
        } else {
            for device in devices {
                let it = NSMenuItem(title: device.name, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = device.uid
                it.state = s.microphoneUID == device.uid ? .on : .off
                micMenu.addItem(it)
            }
        }
    }

    @objc private func editSTTURL() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "输入 STT 服务地址"
        alert.informativeText = "OpenAI 兼容的转写接口完整 URL，例如：\(DictationSettings.defaultURL)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.stringValue = services.dictation.settings.sttURLString
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                services.dictation.settings.sttURLString = value
            }
        }
        refreshDictationItems()
    }

    @objc private func resetSTTURL() {
        services.dictation.settings.sttURLString = DictationSettings.defaultURL
        refreshDictationItems()
    }

    @objc private func toggleCleanup(_ sender: NSButton) {
        services.dictation.settings.cleanupEnabled = sender.state == .on
        services.dictation.applyCleanupSettings()
        refreshDictationItems()
    }

    @objc private func editCleanupKey() {
        promptText(
            title: "设置清整理 API Key",
            message: "用于调用大模型接口的 Bearer Token，仅保存在本机 UserDefaults，不写入仓库。",
            current: services.dictation.settings.cleanupAPIKey,
            isSecure: true
        ) { [weak self] value in
            guard let self else { return }
            self.services.dictation.settings.cleanupAPIKey = value
            self.services.dictation.applyCleanupSettings()
            self.refreshDictationItems()
        }
    }

    @objc private func editCleanupPrompt() {
        promptMultilineText(
            title: "编辑清整理提示词",
            message: "发送给大模型的 system 提示词，可自行修改并保存；留空则恢复默认。",
            current: services.dictation.settings.cleanupSystemPrompt
        ) { [weak self] value in
            guard let self else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            self.services.dictation.settings.cleanupSystemPrompt = trimmed.isEmpty
                ? DictationSettings.defaultCleanupSystemPrompt
                : value
            self.services.dictation.applyCleanupSettings()
            self.refreshDictationItems()
        }
    }

    @objc private func resetCleanup() {
        let s = services.dictation.settings
        s.cleanupURLString = DictationSettings.defaultCleanupURL
        s.cleanupModel = DictationSettings.defaultCleanupModel
        s.cleanupAPIKey = DictationSettings.defaultCleanupAPIKey
        s.cleanupSystemPrompt = DictationSettings.defaultCleanupSystemPrompt
        services.dictation.applyCleanupSettings()
        refreshDictationItems()
    }

    @objc private func testCleanupConnection() {
        NSApp.activate(ignoringOtherApps: true)
        services.dictation.checkCleanupConnection { ok, message in
            let alert = NSAlert()
            alert.messageText = ok ? "连接正常" : "连接失败"
            alert.informativeText = message
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    private func promptText(
        title: String,
        message: String,
        current: String,
        isSecure: Bool = false,
        apply: @escaping (String) -> Void
    ) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field: NSTextField = isSecure
            ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
            : NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            apply(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func promptMultilineText(
        title: String,
        message: String,
        current: String,
        apply: @escaping (String) -> Void
    ) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let scrollView = NSTextView.scrollableTextView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
        if let textView = scrollView.documentView as? NSTextView {
            textView.string = current
            textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
        }
        alert.accessoryView = scrollView
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn,
           let textView = scrollView.documentView as? NSTextView {
            apply(textView.string)
        }
    }

    @objc private func testDictationConnection() {
        NSApp.activate(ignoringOtherApps: true)
        services.dictation.checkConnection { ok, message in
            let alert = NSAlert()
            alert.messageText = ok ? "连接正常" : "连接失败"
            alert.informativeText = message
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
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

    // MARK: - 视图型菜单项（勾选后菜单不收起，方便连续调整；点菜单外部仍会收起）

    /// 把 NSButton 装进菜单项：点击由控件消费，菜单保持展开。
    private func viewRow(button: NSButton) -> (item: NSMenuItem, button: NSButton) {
        button.font = .menuFont(ofSize: 0)
        button.sizeToFit()
        let height = max(22, button.frame.height + 4)
        let width = max(240, button.frame.width + 24)
        button.frame = NSRect(
            x: 14,
            y: (height - button.frame.height) / 2,
            width: width - 20,
            height: button.frame.height
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.addSubview(button)
        let item = NSMenuItem()
        item.view = container
        return (item, button)
    }

    private func checkmarkRow(
        title: String,
        isOn: Bool,
        toolTip: String? = nil,
        action: Selector
    ) -> (item: NSMenuItem, button: NSButton) {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = isOn ? .on : .off
        button.toolTip = toolTip
        return viewRow(button: button)
    }

    private func radioRow(
        title: String,
        isOn: Bool,
        tag: Int,
        action: Selector
    ) -> (item: NSMenuItem, button: NSButton) {
        let button = NSButton(radioButtonWithTitle: title, target: self, action: action)
        button.state = isOn ? .on : .off
        button.tag = tag
        return viewRow(button: button)
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
        } else if menu == micMenu {
            // 设备可随时插拔：展开麦克风子菜单前重建一次设备列表与勾选状态。
            rebuildMicMenu()
        }
    }

    private func refreshAllVisibleStrings() {
        refreshStatusLineItems()
        refreshSedentaryIconBlock()
        refreshWeChatIconBlock()
        refreshFeishuIconBlock()
        itemHUD.setOn(services.debuffHUDVisibility.isEnabled, checkmark: true)
        refreshDictationItems()
    }

    private func refreshDictationItems() {
        guard journalCheckbox != nil else { return }
        let s = services.dictation.settings
        journalCheckbox.state = s.journalEnabled ? .on : .off
        cleanupCheckbox.state = s.cleanupEnabled ? .on : .off
        emptyBufferCheckbox.state = s.emptyBufferBehavior == .inactive ? .on : .off
        itemJournalTodayText.title = journalTodayLine
        itemJournalSavedTime.title = journalSavedLine
        itemDictationURL.title = s.sttURLString
        itemDictationHotkey.title = DictationHotKey.label(keyCode: s.hotkeyKeyCode, flags: s.hotkeyFlags)
        itemMicParent.title = microphoneTitle
        for (index, button) in pauseValueButtons.enumerated() {
            let selected = abs(DictationSettings.pausePresets[index] - s.pauseSilenceSeconds) < 0.0001
            button.state = selected ? .on : .off
        }
        for (index, button) in maxSegmentValueButtons.enumerated() {
            let selected = abs(DictationSettings.maxSegmentPresets[index] - s.maxSegmentSeconds) < 0.0001
            button.state = selected ? .on : .off
        }
    }

    private func bindData() {
        // 定时更新状态行（不替换 rootMenu 结构；子菜单在展开时也不会因 title 被覆盖而关闭）
        updateTimer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshStatusLineItems()
                self?.refreshDictationItems()
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
