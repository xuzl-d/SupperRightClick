import AppKit
import ServiceManagement

/// 主窗口：展示运行状态、权限引导与使用说明。
final class MainWindowController: NSWindowController {

    /// 「重新检测」回调（由 AppDelegate 注入）。
    var onRecheck: (() -> Void)?

    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let openSettingsButton = NSButton(title: "打开系统设置", target: nil, action: nil)
    private let recheckButton = NSButton(title: "重新检测", target: nil, action: nil)
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "开机自启动", target: nil, action: nil)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "超级右键"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildContent()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showWindow() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        refresh()
    }

    func refresh() {
        let trusted = PermissionManager.shared.isTrusted
        let running = EventTapManager.shared.isRunning

        var lines = [
            "辅助功能权限：" + (trusted ? "✅ 已授权" : "❌ 未授权"),
            "右键拦截：" + (running ? "✅ 运行中" : "❌ 未启动"),
        ]
        if !trusted {
            lines += ["", "请点击「打开系统设置」，在「隐私与安全性 → 辅助功能」中勾选本应用，再点「重新检测」。"]
        } else if !running {
            lines += ["", "已授权但拦截未启动，请点「重新检测」。"]
        } else {
            lines += ["", "已就绪！在「访达」或桌面右键即可使用增强菜单。"]
        }
        statusLabel.stringValue = lines.joined(separator: "\n")
        openSettingsButton.isHidden = trusted

        // 开机自启动状态
        let loginStatus = SMAppService.mainApp.status
        switch loginStatus {
        case .enabled:
            launchAtLoginCheckbox.state = .on
        case .requiresApproval:
            launchAtLoginCheckbox.state = .off
        default:
            launchAtLoginCheckbox.state = .off
        }
        launchAtLoginCheckbox.isEnabled = (loginStatus != .notFound)
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let titleLabel = NSTextField(labelWithString: "超级右键")
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.preferredMaxLayoutWidth = 460

        let hintLabel = NSTextField(wrappingLabelWithString: "在「访达」或桌面右键即可使用：\n新建文件（txt / md / docx / xlsx …）、打开方式、共享、复制路径、压缩、终端打开、隐藏文件、删除等。")
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.preferredMaxLayoutWidth = 460

        openSettingsButton.target = self
        openSettingsButton.action = #selector(openSettings)

        recheckButton.target = self
        recheckButton.action = #selector(recheck)

        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(toggleLaunchAtLogin)

        let quitButton = NSButton(title: "退出", target: self, action: #selector(quitApp))

        let buttonRow = NSStackView(views: [openSettingsButton, recheckButton, quitButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let stack = NSStackView(views: [titleLabel, statusLabel, hintLabel, launchAtLoginCheckbox, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -22),
        ])
    }

    @objc private func openSettings() {
        PermissionManager.shared.prompt()               // 注册进辅助功能列表并触发授权弹窗
        PermissionManager.shared.openAccessibilitySettings()
    }

    @objc private func recheck() {
        onRecheck?()
        refresh()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                SLog.log("已关闭开机自启动")
            } else {
                try SMAppService.mainApp.register()
                SLog.log("已开启开机自启动")
            }
        } catch {
            SLog.log("开机自启动设置失败: \(error)")
            let alert = NSAlert()
            alert.messageText = "设置开机自启动失败"
            alert.informativeText = "请确认 App 位于 Applications 文件夹（或直接从访达启动），错误：\(error.localizedDescription)"
            alert.runModal()
        }
        refresh()

        if SMAppService.mainApp.status == .requiresApproval {
            let alert = NSAlert()
            alert.messageText = "需要在系统设置中允许"
            alert.informativeText = "请前往「系统设置 → 通用 → 登录项与扩展」，在「登录时打开」中允许「超级右键」。"
            alert.runModal()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
