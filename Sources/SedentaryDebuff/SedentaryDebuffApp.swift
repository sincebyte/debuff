import SwiftUI

@main
struct SedentaryDebuffApp: App {
    @NSApplicationDelegateAdaptor(SedentaryDebuffAppDelegate.self) private var appDelegate
    @StateObject private var appState = DebuffAppState()

    var body: some Scene {
        // 菜单由 `DebuffStatusBarController` 用 `NSStatusItem` + `NSMenu` 自绘。SwiftUI `MenuBarExtra`
        // 会把整份内容同步成 `NSMenu`，任意子视图/定时重绘时整棵 `NSMenu` 会被替换，二级子菜单会无故关闭。
        Settings { EmptyView() }
    }
}
