import AppKit
import InputMethodKit

let usage = """
VoiceIME — IMK 最小 PoC（在任意 App 的 caret 处插入文本并取 caret 屏幕矩形）
============================================================================
管理命令：
  --install     注册并启用输入源（安装到 ~/Library/Input Methods 后执行一次）
  --select      把当前 App 的输入法切换成 VoiceIME
  --disable     停用输入源
  --status      查看注册/启用/选中状态
  --quit        退出已运行的 VoiceIME

交互验证（注册后）：
  1. 在目标 App（Chrome/Emacs 等）里把输入法切到 VoiceIME（菜单栏输入法或 Ctrl+Space）。
  2. 把光标放到任意位置，按 F8。
  3. 观察：光标处出现绿色竖线（IM 报告的 caret 矩形），随后自动插入 "VoiceIME-PoC✅"。
  4. 详情追加写入 /tmp/voiceime.log（selectedRange / firstRect / insert 结果）。
  5. 其它按键原样透传给 App，打字不受影响。
"""

var handled = false
let args = CommandLine.arguments
if args.count > 1 {
    switch args[1] {
    case "--install":
        VoiceIMEInstaller.register()
        VoiceIMEInstaller.enable()
        handled = true
    case "--register":
        VoiceIMEInstaller.register()
        handled = true
    case "--enable":
        VoiceIMEInstaller.enable()
        handled = true
    case "--select":
        VoiceIMEInstaller.select()
        handled = true
    case "--disable":
        VoiceIMEInstaller.disable()
        handled = true
    case "--status":
        VoiceIMEInstaller.status()
        handled = true
    case "--list":
        VoiceIMEInstaller.listAll()
        handled = true
    case "--quit":
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: VoiceIMEIDs.bundleIdentifier)
        running.forEach { $0.terminate() }
        handled = true
    case "--help", "-h":
        print(usage)
        handled = true
    default:
        break
    }
}

if handled {
    exit(0)
}

let mainBundle = Bundle.main
guard let connectionName = mainBundle.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String,
      let bundleID = mainBundle.bundleIdentifier else {
    print("Not running as an input method bundle.")
    exit(1)
}

let server = IMKServer(name: connectionName, bundleIdentifier: bundleID)
_ = server

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
VoiceIMELog.write("VoiceIME starting; connection=\(connectionName)")
app.run()
