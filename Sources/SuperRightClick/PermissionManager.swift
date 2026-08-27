import AppKit
import ApplicationServices

/// 辅助功能（Accessibility）权限管理。
/// CGEventTap 拦截全局鼠标事件必须依赖该权限。
final class PermissionManager {
    static let shared = PermissionManager()

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// 弹出系统授权提示（仅首次或未授权时调用）。
    func prompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 打开「系统设置 → 隐私与安全性 → 辅助功能」。
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
