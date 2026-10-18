import AppKit

/// 授权流程与界面：启动检查、输入授权码弹窗、试用倒计时、到期拦截。
final class LicenseController {
    static let shared = LicenseController()

    /// 可用状态变化（启用/停用右键拦截）。
    var onUsabilityChanged: ((Bool) -> Void)?
    /// 每秒回调，用于刷新倒计时文字。
    var onTick: (() -> Void)?

    private let manager = LicenseManager.shared
    private var timer: Timer?
    private var lastUsable: Bool?
    private var busy = false          // 弹窗/联网进行中，避免重复触发
    private var renewTried = false    // 本次运行是否已尝试过到期续期

    // MARK: - 启动

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        evaluate(launch: true)
    }

    private func tick() {
        manager.touch()
        notifyIfChanged()
        onTick?()
        if !manager.status().isUsable && !busy { evaluate(launch: false) }
    }

    private func notifyIfChanged() {
        let usable = manager.status().isUsable
        if usable != lastUsable {
            lastUsable = usable
            onUsabilityChanged?(usable)
        }
    }

    /// 根据当前状态决定：放行 / 续期 / 弹窗。
    private func evaluate(launch: Bool) {
        switch manager.status() {
        case .licensed, .trial:
            notifyIfChanged()
        case .licenseExpired:
            notifyIfChanged()
            renewExpiredLicense()
        case .trialAvailable, .trialExpired:
            notifyIfChanged()
            promptActivation()
        }
    }

    /// 授权到期：携带已保存的授权码联网查询一次（可能已被续期）；不再无限重试。
    private func renewExpiredLicense() {
        guard !busy else { return }
        guard !renewTried, let code = manager.licenseCode else {
            promptActivation(message: "授权已到期，请输入新的授权码。")
            return
        }
        renewTried = true
        busy = true
        manager.activate(code: code) { [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case .success:
                self.notifyIfChanged()
                if case .licensed = self.manager.status() { return }
                self.promptActivation(message: "授权已到期，请输入新的授权码。")
            case .rejected(let msg):
                self.manager.clearLicense()
                self.promptActivation(message: "授权已到期或失效：\(msg)\n请输入新的授权码。")
            case .network(let msg):
                self.promptActivation(message: "授权已到期，且续期查询失败：\(msg)\n请联网后重新输入授权码。")
            }
        }
    }

    // MARK: - 弹窗

    /// 菜单里的「输入授权码…」入口。
    func promptActivation(message: String? = nil) {
        guard !busy else { return }
        busy = true
        NSApp.activate(ignoringOtherApps: true)

        let status = manager.status()
        let trialAllowed = status == .trialAvailable
        let trialRunning: Bool = { if case .trial = status { return true }; return false }()
        let licensed: Bool = { if case .licensed = status { return true }; return false }()

        let alert = NSAlert()
        alert.messageText = "激活超级右键"
        var info = message ?? ""
        if info.isEmpty {
            if trialAllowed {
                info = "请输入授权码。点「取消」可免费试用 1 天。"
            } else if trialRunning {
                info = "请输入授权码以解锁完整使用。"
            } else if licensed {
                info = "当前已授权，输入新的授权码将替换现有授权。"
            } else {
                info = "试用已结束，请输入授权码继续使用。"
            }
        }
        alert.informativeText = info + "\n\n本机 ID：\(String(manager.machineID.prefix(16)))"
        alert.addButton(withTitle: "激活")
        let canDismiss = trialAllowed || trialRunning || licensed
        alert.addButton(withTitle: trialAllowed ? "取消（试用 1 天）" : (canDismiss ? "取消" : "退出"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "XXXX-XXXX-XXXX-XXXX"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            submit(code: field.stringValue)
        } else {
            busy = false
            if trialAllowed {
                manager.startTrialIfNeeded()
                notifyIfChanged()
                onTick?()
            } else if !canDismiss {
                NSApp.terminate(nil)
            }
        }
    }

    private func submit(code: String) {
        manager.activate(code: code) { [weak self] result in
            guard let self else { return }
            self.busy = false
            self.renewTried = false
            switch result {
            case .success:
                self.notifyIfChanged()
                self.onTick?()
                self.info("激活成功", "感谢使用超级右键。")
            case .rejected(let msg):
                self.promptActivation(message: "激活失败：\(msg)")
            case .network(let msg):
                self.promptActivation(message: "激活失败：\(msg)\n请检查网络后重试。")
            }
        }
    }

    private func info(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    // MARK: - 展示文案

    static func format(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// 菜单栏标题：试用中显示倒计时。
    var statusTitle: String {
        switch manager.status() {
        case .trial(let r): return "试用 " + Self.format(r)
        case .trialExpired, .licenseExpired, .trialAvailable: return "超级右键（未授权）"
        case .licensed: return "超级右键"
        }
    }

    var detailText: String {
        switch manager.status() {
        case .licensed(let exp):
            if let exp {
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
                return "✅ 已授权（到期：\(f.string(from: exp))）"
            }
            return "✅ 已授权（永久）"
        case .trial(let r): return "⏳ 试用中，剩余 \(Self.format(r))"
        case .trialAvailable: return "❌ 未授权"
        case .trialExpired: return "❌ 试用已结束"
        case .licenseExpired: return "❌ 授权已到期"
        }
    }
}
