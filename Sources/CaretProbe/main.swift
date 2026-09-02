import AppKit
import ApplicationServices

let usage = """
CaretProbe — 检测“其他 App 文本框里的光标”在屏幕上的位置
========================================================
用法：
  直接运行，然后切到被测 App、把光标点进文本框。
  程序会每 0.7 秒自动探测一次，绿线会跟着光标实时走，
  报告变化时才打印；按 F7 手动刷新一次，F8 关闭屏幕上的提示。

  CaretProbe --once          只探测一次当前前台 App，然后退出
  CaretProbe --interval 0.2  自定义自动探测间隔（秒）
  CaretProbe --quiet         不在终端打印，只更新屏幕提示和报告文件
  CaretProbe --enhance       探测前先给目标 App 开 AXEnhancedUserInterface
                             （部分 Electron/Qt App 需要它才构建无障碍树）
  CaretProbe --report PATH   报告写到 PATH（默认 /tmp/caretprobe-report.txt）

测试步骤：
  1. 终端里运行 CaretProbe，弹出授权就点“允许”（系统设置→辅助功能）。
  2. 切到 TextEdit/Safari/Chrome/VS Code/Qt/Electron App，把光标点进文本框。
  3. 看绿色竖线是否压在真实光标上；终端和报告文件里有每个 API 的详细结果。
"""

func ensureAccessibilityTrust() -> Bool {
    if AXIsProcessTrusted() { return true }
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [key: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

func reportSignature(_ report: String) -> String {
    var parts: [String] = []
    let meaningful = [
        "frontmost_pid",
        "focused_ax_role =",
        "focused_ax_subrole =",
        "AXSelectedTextRange =",
        "AXNumberOfCharacters =",
        "caret_strategy.",
        "caret_rect_AX =",
        "focused_element_frame_AX =",
    ]
    for line in report.split(separator: "\n") {
        let string = String(line)
        for prefix in meaningful where string.hasPrefix(prefix) {
            parts.append(string)
        }
    }
    return parts.joined(separator: "|")
}

func isTerminalApp(_ name: String, _ bundle: String) -> Bool {
    let combined = (name + " " + bundle).lowercased()
    let terminals = ["terminal", "iterm", "warp", "kitty", "alacritty", "hyper", "ghostty", "wezterm"]
    return terminals.contains { combined.contains($0) }
}

final class ProbeRunner {
    var lastSignature = ""
    var quiet = false

    func fire(forcePrint: Bool, updateHUD: Bool = true) {
        let report = Probe.run()
        do {
            try report.write(toFile: reportFile, atomically: true, encoding: .utf8)
        } catch {}
        if updateHUD {
            ProbeHUD.shared.update(
                report: report,
                caretAXRect: ProbeStore.shared.lastCaretAXRect,
                elementAXRect: ProbeStore.shared.lastElementAXRect
            )
        }
        let signature = reportSignature(report)
        if forcePrint || (!quiet && signature != lastSignature) {
            print(report)
            print("")
            fflush(stdout)
        }
        lastSignature = signature
    }
}

let runner = ProbeRunner()

var args = CommandLine.arguments
var onceMode = false
var autoInterval: Double = 0.7
var quiet = false
var probeEnhance = false
var reportFile = "/tmp/caretprobe-report.txt"

var index = 1
while index < args.count {
    switch args[index] {
    case "--once":
        onceMode = true
    case "--quiet":
        quiet = true
    case "--enhance":
        probeEnhance = true
    case "--interval":
        index += 1
        if index < args.count, let value = Double(args[index]), value > 0 {
            autoInterval = value
        }
    case "--report":
        index += 1
        if index < args.count {
            reportFile = args[index]
        }
    case "--help", "-h":
        print(usage)
        exit(0)
    default:
        break
    }
    index += 1
}

runner.quiet = quiet
Probe.enhanceFrontmost = probeEnhance

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard ensureAccessibilityTrust() else {
    print("没有被授予辅助功能权限，已重新打开系统设置，请在“辅助功能”里允许后重跑。")
    exit(1)
}

if onceMode {
    runner.fire(forcePrint: true, updateHUD: false)
    exit(0)
}

let probeKeyCode: UInt32 = 0x62
let probeModifiers: UInt32 = 0
let hideKeyCode: UInt32 = 0x64
let hideModifiers: UInt32 = 0

GlobalHotKey.shared.onProbePress = { runner.fire(forcePrint: true) }
GlobalHotKey.shared.onHidePress = { ProbeHUD.shared.hideAll() }
let hotKeyInstalled = GlobalHotKey.shared.install(
    probeKeyCode: probeKeyCode,
    probeModifiers: probeModifiers,
    hideKeyCode: hideKeyCode,
    hideModifiers: hideModifiers
)

print(usage)
if hotKeyInstalled {
    print("开始。切到被测 App，把光标放进文本框即可，程序自动跟；F7 手动刷一次，F8 关闭提示，Ctrl-C 退出。")
} else {
    print("开始（功能键注册失败，仅用自动探测）。Ctrl-C 退出。")
}
print("报告文件：\(reportFile)")

let timer = Timer(timeInterval: autoInterval, repeats: true) { _ in
    guard let front = NSWorkspace.shared.frontmostApplication else { return }
    if front.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
    let name = front.localizedName ?? ""
    let bundle = front.bundleIdentifier ?? ""
    if isTerminalApp(name, bundle) { return }
    runner.fire(forcePrint: false)
}
RunLoop.main.add(timer, forMode: .common)

app.run()
