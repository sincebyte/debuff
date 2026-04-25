import Foundation
import SwiftUI

/// 控制 Debuff 状态浮窗（久坐 / 微信图标）的显示，与 `MenuBarExtra` 无关；持久化在 UserDefaults。
final class DebuffHUDVisibility: ObservableObject {
    private static let key = "showDebuffStatusHUD"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.key)
        }
    }

    init() {
        if UserDefaults.standard.object(forKey: Self.key) == nil {
            isEnabled = true
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: Self.key)
        }
    }
}
