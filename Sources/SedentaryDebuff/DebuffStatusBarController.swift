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

    private var itemDictationToggle: NSMenuItem!
    private var itemDictationStatus: NSMenuItem!
    private var itemDictationHint: NSMenuItem!
    private var itemJournalToggle: NSMenuItem!
    private var itemJournalOpen: NSMenuItem!
    private var itemJournalTodayText: NSMenuItem!
    private var itemJournalSavedTime: NSMenuItem!
    private var itemDictationURL: NSMenuItem!
    private var itemCleanupEnabled: NSMenuItem!
    private var itemCleanupModel: NSMenuItem!
    private var itemDictationHotkey: NSMenuItem!
    private var itemMicParent: NSMenuItem!
    private var micMenu: NSMenu!
    private var pauseOptionItems: [NSMenuItem] = []
    private var maxSegmentItems: [NSMenuItem] = []
    private var activeOpacityItems: [NSMenuItem] = []
    private var waveformWidthItems: [NSMenuItem] = []
    private var emptyBufferBehaviorItems: [NSMenuItem] = []
    private var hotkeyPresetItems: [NSMenuItem] = []

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
        addHeader("语音输入")

        itemDictationToggle = NSMenuItem(title: dictationToggleTitle, action: #selector(toggleDictation), keyEquivalent: "")
        itemDictationToggle.target = self
        rootMenu.addItem(itemDictationToggle)

        itemDictationStatus = makeDisabled("")
        rootMenu.addItem(itemDictationStatus)

        itemDictationHint = makeDisabled("激活中说话，文字先显示在光波下方 · 按 \(DictationHotKey.label(keyCode: s.hotkeyKeyCode, flags: s.hotkeyFlags))/End 粘贴待命 · Home 清空")
        itemDictationHint.toolTip = "激活期间转写的文字不再直接粘贴，而是逐段显示在光波面板下方的滚动区（鼠标悬停即可上下滚轮浏览），上下边界渐隐；把光标放进目标输入框后，按主快捷键 \(DictationHotKey.label(keyCode: s.hotkeyKeyCode, flags: s.hotkeyFlags)) 或固定 End 键，会把缓冲内容整段粘贴到当前光标、清空缓冲并进入非激活待命。按固定 Home 键清空尚未提交的缓冲文本。语音「over」等同提交；「清空/clear」清空缓冲文本；「发送」把缓冲粘贴到当前光标后回车；「删除/撤销」仍在当前输入框删一个词。非激活待命只驱动波形不做识别（语音日记也只记录激活状态转写的内容）。缓冲为空时可在「设置 → 空文本时」选择保留非激活文本框或收起只留波形。上方菜单项负责开启/关停麦克风。"
        rootMenu.addItem(itemDictationHint)

        itemJournalToggle = NSMenuItem(title: journalToggleTitle, action: #selector(toggleJournal), keyEquivalent: "")
        itemJournalToggle.target = self
        itemJournalToggle.setOn(s.journalEnabled, checkmark: true)
        itemJournalToggle.toolTip = "开启后，激活语音转写并上屏/发送的内容会逐条带「日期+时分秒」追加到桌面 语音日记/当天日期.txt；非激活待命不后台录音转写，杂音不进日记。纯指令词（over/发送/清空等）不入日记。下方的今日字数与累计节约统计始终跟随激活语音输入累计，与是否写入桌面文件无关。"
        rootMenu.addItem(itemJournalToggle)
        itemJournalOpen = NSMenuItem(title: "打开语音日记目录…", action: #selector(openJournalFolder), keyEquivalent: "")
        itemJournalOpen.target = self
        rootMenu.addItem(itemJournalOpen)

        itemJournalTodayText = makeDisabled("")
        itemJournalTodayText.toolTip = "今日激活语音转写的字符数（跨自然日自动清零重计）。"
        rootMenu.addItem(itemJournalTodayText)
        itemJournalSavedTime = makeDisabled("")
        itemJournalSavedTime.toolTip = "按 \(Int(VoiceJournalStats.charsPerMinute)) 字/分钟的打字速度估算：转写 N 字 ≈ 节约 N/\(Int(VoiceJournalStats.charsPerMinute)) 分钟，历史语音输入折算的节约时间永久累计。"
        rootMenu.addItem(itemJournalSavedTime)

        let settingsMenu = NSMenu()

        settingsMenu.addItem(subHeader("停顿判定（秒）"))
        for v in DictationSettings.pausePresets {
            let it = NSMenuItem(title: String(format: "%.1f 秒", v), action: #selector(selectPause(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = NSNumber(value: v)
            it.state = abs(v - s.pauseSilenceSeconds) < 0.0001 ? .on : .off
            settingsMenu.addItem(it)
            pauseOptionItems.append(it)
        }

        settingsMenu.addItem(subHeader("最大切段（秒）"))
        for v in DictationSettings.maxSegmentPresets {
            let it = NSMenuItem(title: "\(Int(v)) 秒", action: #selector(selectMaxSegment(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = NSNumber(value: v)
            it.state = abs(v - s.maxSegmentSeconds) < 0.0001 ? .on : .off
            settingsMenu.addItem(it)
            maxSegmentItems.append(it)
        }

        settingsMenu.addItem(subHeader("激活状态透明度"))
        for v in DictationSettings.activeOpacityPresets {
            let it = NSMenuItem(title: String(format: "%.2f", v), action: #selector(selectActiveOpacity(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = NSNumber(value: v)
            it.state = abs(v - s.activeOpacity) < 0.0001 ? .on : .off
            settingsMenu.addItem(it)
            activeOpacityItems.append(it)
        }

        settingsMenu.addItem(subHeader("波形宽度"))
        for v in DictationSettings.waveformWidthPresets {
            let it = NSMenuItem(title: waveformWidthLabel(v), action: #selector(selectWaveformWidth(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = NSNumber(value: v)
            it.state = abs(v - s.waveformWidth) < 0.0001 ? .on : .off
            settingsMenu.addItem(it)
            waveformWidthItems.append(it)
        }

        settingsMenu.addItem(subHeader("空文本时"))
        for behavior in DictationSettings.EmptyBufferBehavior.allCases {
            let it = NSMenuItem(title: emptyBufferBehaviorLabel(behavior), action: #selector(selectEmptyBufferBehavior(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = behavior.rawValue
            it.state = s.emptyBufferBehavior == behavior ? .on : .off
            settingsMenu.addItem(it)
            emptyBufferBehaviorItems.append(it)
        }

        settingsMenu.addItem(subHeader("STT 服务地址"))
        itemDictationURL = makeDisabled(s.sttURLString)
        settingsMenu.addItem(itemDictationURL)
        settingsMenu.addItem(NSMenuItem(title: "输入地址…", action: #selector(editSTTURL), keyEquivalent: "").apply { $0.target = self })
        settingsMenu.addItem(NSMenuItem(title: "恢复默认", action: #selector(resetSTTURL), keyEquivalent: "").apply { $0.target = self })

        settingsMenu.addItem(subHeader("文本清整理（大模型）"))
        itemCleanupEnabled = NSMenuItem(title: "启用清整理（错别字/重复词）", action: #selector(toggleCleanup), keyEquivalent: "")
        itemCleanupEnabled.target = self
        itemCleanupEnabled.setOn(s.cleanupEnabled, checkmark: true)
        itemCleanupEnabled.toolTip = "开启后，每次 ASR 转写出的文字会拉通尚未整理的部分交给大模型做「清整理」：纠正错别字/同音字、删除重复词与口水词、补全标点。整理完成后才允许提交粘贴，确保上屏的是整理后的文本。"
        settingsMenu.addItem(itemCleanupEnabled)
        itemCleanupModel = makeDisabled("模型：\(s.cleanupModel)")
        settingsMenu.addItem(itemCleanupModel)
        settingsMenu.addItem(NSMenuItem(title: "输入接口地址…", action: #selector(editCleanupURL), keyEquivalent: "").apply { $0.target = self })
        settingsMenu.addItem(NSMenuItem(title: "输入模型名…", action: #selector(editCleanupModel), keyEquivalent: "").apply { $0.target = self })
        settingsMenu.addItem(NSMenuItem(title: "设置 API Key…", action: #selector(editCleanupKey), keyEquivalent: "").apply { $0.target = self })
        settingsMenu.addItem(NSMenuItem(title: "恢复默认", action: #selector(resetCleanup), keyEquivalent: "").apply { $0.target = self })

        settingsMenu.addItem(subHeader("快捷键"))
        itemDictationHotkey = makeDisabled(DictationHotKey.label(keyCode: s.hotkeyKeyCode, flags: s.hotkeyFlags))
        settingsMenu.addItem(itemDictationHotkey)
        for p in DictationHotKey.presets {
            let it = NSMenuItem(title: p.label, action: #selector(selectHotkey(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = p
            it.state = (p.keyCode == s.hotkeyKeyCode && p.flags == s.hotkeyFlags) ? .on : .off
            settingsMenu.addItem(it)
            hotkeyPresetItems.append(it)
        }
        settingsMenu.addItem(makeDisabled("End（固定）＝ 激活/非激活切换 · Home（固定）＝ 清空缓冲"))

        let settingsParent = NSMenuItem(title: "设置", action: nil, keyEquivalent: "")
        settingsParent.submenu = settingsMenu
        rootMenu.addItem(settingsParent)

        itemMicParent = NSMenuItem(title: microphoneTitle, action: nil, keyEquivalent: "")
        micMenu = NSMenu()
        micMenu.delegate = self
        itemMicParent.submenu = micMenu
        rootMenu.addItem(itemMicParent)
        rebuildMicMenu()

        rootMenu.addItem(NSMenuItem(title: "测试服务连接", action: #selector(testDictationConnection), keyEquivalent: "").apply { $0.target = self })
        rootMenu.addItem(NSMenuItem(title: "测试清整理连接", action: #selector(testCleanupConnection), keyEquivalent: "").apply { $0.target = self })
        rootMenu.addItem(NSMenuItem(title: "辅助功能设置…", action: #selector(openAccessibilitySettings), keyEquivalent: "").apply { $0.target = self })
    }

    private var dictationToggleTitle: String {
        services.dictation.isEngineOn ? "停止语音输入" : "开始语音输入"
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

    @objc private func toggleDictation() {
        services.dictation.startStop()
    }

    @objc private func toggleJournal() {
        services.dictation.settings.journalEnabled.toggle()
        refreshDictationItems()
    }

    @objc private func openJournalFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let fileManager = FileManager.default
        let desktop = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop", isDirectory: true)
        let folder = desktop.appendingPathComponent("语音日记", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = folder.appendingPathComponent("\(formatter.string(from: Date())).txt")
        if fileManager.fileExists(atPath: today.path) {
            NSWorkspace.shared.activateFileViewerSelecting([today])
        } else {
            NSWorkspace.shared.open(folder)
        }
    }

    @objc private func selectPause(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        services.dictation.settings.pauseSilenceSeconds = n.doubleValue
        refreshDictationItems()
    }

    @objc private func selectMaxSegment(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        services.dictation.settings.maxSegmentSeconds = n.doubleValue
        refreshDictationItems()
    }

    @objc private func selectActiveOpacity(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        services.dictation.settings.activeOpacity = n.doubleValue
        services.dictation.applyActiveOpacity()
        refreshDictationItems()
    }

    @objc private func selectWaveformWidth(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        services.dictation.settings.waveformWidth = n.doubleValue
        services.dictation.applyWaveformWidth()
        refreshDictationItems()
    }

    private func waveformWidthLabel(_ v: Double) -> String {
        switch Int(v) {
        case 35: return "35（圆点）"
        case 167: return "167（标准）"
        default: return "\(Int(v))"
        }
    }

    @objc private func selectEmptyBufferBehavior(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let behavior = DictationSettings.EmptyBufferBehavior(rawValue: raw) else { return }
        services.dictation.settings.emptyBufferBehavior = behavior
        services.dictation.applyEmptyBufferBehavior()
        refreshDictationItems()
    }

    private func emptyBufferBehaviorLabel(_ behavior: DictationSettings.EmptyBufferBehavior) -> String {
        switch behavior {
        case .inactive: return "保留文本框（非激活显示）"
        case .collapse: return "收起文本框与按钮"
        }
    }

    @objc private func selectHotkey(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? DictationHotKey.Preset else { return }
        services.dictation.settings.hotkeyKeyCode = preset.keyCode
        services.dictation.settings.hotkeyFlags = preset.flags
        services.dictation.applyHotkey()
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

    @objc private func toggleCleanup() {
        let s = services.dictation.settings
        s.cleanupEnabled.toggle()
        services.dictation.applyCleanupSettings()
        refreshDictationItems()
    }

    @objc private func editCleanupURL() {
        promptText(
            title: "输入清整理接口地址",
            message: "OpenAI 兼容的 Chat Completions 完整 URL，例如：\(DictationSettings.defaultCleanupURL)",
            current: services.dictation.settings.cleanupURLString
        ) { [weak self] value in
            guard let self, !value.isEmpty else { return }
            self.services.dictation.settings.cleanupURLString = value
            self.services.dictation.applyCleanupSettings()
            self.refreshDictationItems()
        }
    }

    @objc private func editCleanupModel() {
        promptText(
            title: "输入清整理模型名",
            message: "例如：\(DictationSettings.defaultCleanupModel)",
            current: services.dictation.settings.cleanupModel
        ) { [weak self] value in
            guard let self, !value.isEmpty else { return }
            self.services.dictation.settings.cleanupModel = value
            self.services.dictation.applyCleanupSettings()
            self.refreshDictationItems()
        }
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

    @objc private func resetCleanup() {
        let s = services.dictation.settings
        s.cleanupURLString = DictationSettings.defaultCleanupURL
        s.cleanupModel = DictationSettings.defaultCleanupModel
        s.cleanupAPIKey = DictationSettings.defaultCleanupAPIKey
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

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        if let url {
            NSWorkspace.shared.open(url)
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
        guard itemDictationToggle != nil else { return }
        let d = services.dictation
        let s = d.settings
        itemDictationToggle.title = dictationToggleTitle
        itemDictationStatus.title = d.statusText
        itemJournalToggle.setOn(s.journalEnabled, checkmark: true)
        itemJournalTodayText.title = journalTodayLine
        itemJournalSavedTime.title = journalSavedLine
        itemDictationURL.title = s.sttURLString
        itemCleanupEnabled.setOn(s.cleanupEnabled, checkmark: true)
        itemCleanupModel.title = "模型：\(s.cleanupModel)"
        itemDictationHotkey.title = DictationHotKey.label(keyCode: s.hotkeyKeyCode, flags: s.hotkeyFlags)
        itemMicParent.title = microphoneTitle
        for it in pauseOptionItems {
            guard let n = it.representedObject as? NSNumber else { continue }
            it.state = abs(n.doubleValue - s.pauseSilenceSeconds) < 0.0001 ? .on : .off
        }
        for it in maxSegmentItems {
            guard let n = it.representedObject as? NSNumber else { continue }
            it.state = abs(n.doubleValue - s.maxSegmentSeconds) < 0.0001 ? .on : .off
        }
        for it in activeOpacityItems {
            guard let n = it.representedObject as? NSNumber else { continue }
            it.state = abs(n.doubleValue - s.activeOpacity) < 0.0001 ? .on : .off
        }
        for it in waveformWidthItems {
            guard let n = it.representedObject as? NSNumber else { continue }
            it.state = abs(n.doubleValue - s.waveformWidth) < 0.0001 ? .on : .off
        }
        for it in emptyBufferBehaviorItems {
            guard let raw = it.representedObject as? String else { continue }
            it.state = (raw == s.emptyBufferBehavior.rawValue) ? .on : .off
        }
        for it in hotkeyPresetItems {
            guard let preset = it.representedObject as? DictationHotKey.Preset else { continue }
            it.state = (preset.keyCode == s.hotkeyKeyCode && preset.flags == s.hotkeyFlags) ? .on : .off
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
