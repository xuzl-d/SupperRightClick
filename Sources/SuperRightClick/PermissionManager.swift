import AppKit
import ApplicationServices

/// 辅助功能（Accessibility）/ 输入监控（Input Monitoring）权限管理。
/// CGEventTap 拦截全局鼠标事件依赖这些权限；不同 macOS 版本的收紧程度不同。
final class PermissionManager {
    static let shared = PermissionManager()

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// 「输入监控」是否已授权。CGEventTap 若被更严格的系统策略拦下，往往就差这一项。
    var canListenEvents: Bool { CGPreflightListenEventAccess() }

    /// 弹出系统授权提示（仅首次或未授权时调用）。
    func prompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 请求「输入监控」授权（会弹系统提示并把本 App 注册进列表）。
    @discardableResult
    func requestListenEventAccess() -> Bool {
        CGRequestListenEventAccess()
    }

    /// 打开「系统设置 → 隐私与安全性 → 辅助功能」。
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 打开「系统设置 → 隐私与安全性 → 输入监控」。
    func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}
