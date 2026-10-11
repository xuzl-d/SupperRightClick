import AppKit
import ServiceManagement

/// 主窗口：展示运行状态、权限引导与使用说明。
final class MainWindowController: NSWindowController {

    /// 「重新检测」回调（由 AppDelegate 注入）。
    var onRecheck: (() -> Void)?

    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let openSettingsButton = NSButton(title: "打开系统设置", target: nil, action: nil)
    private let recheckButton = NSButton(title: "重新检测", target: nil, action: nil)
    private let diagnosticsButton = NSButton(title: "生成诊断报告", target: nil, action: nil)
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "开机自启动", target: nil, action: nil)

    /// 「常用目录 / 常用 App」两块列表；监听 Favorites 变更以保持界面与配置一致。
    private var directoriesView: FavoritesListView?
    private var appsView: FavoritesListView?
    private var favoritesObserver: NSObjectProtocol?

    /// 打开已有窗口时用：重新读一遍状态（含常用列表）。
    func reloadFavorites() {
        directoriesView?.reload()
        appsView?.reload()
    }

    deinit {
        if let favoritesObserver { NotificationCenter.default.removeObserver(favoritesObserver) }
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "超级右键"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 560)
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
        let canListen = PermissionManager.shared.canListenEvents
        let running = EventTapManager.shared.isRunning

        var lines = [
            "辅助功能权限：" + (trusted ? "✅ 已授权" : "❌ 未授权"),
            "输入监控权限：" + (canListen ? "✅ 已授权" : "❌ 未授权"),
            "右键拦截：" + (running ? "✅ 运行中" : "❌ 未启动"),
        ]
        if !trusted {
            lines += ["", "请点击「打开系统设置」，在「隐私与安全性 → 辅助功能」中勾选本应用，再点「重新检测」。"]
        } else if !running {
            // 已授权但仍起不来：新版 macOS 可能连「输入监控」一起要求，这是最常见的原因。
            lines += [
                "",
                "已授权但拦截未启动。请再检查「隐私与安全性 → 输入监控」是否也勾选了本应用，",
                "两项都勾选后点「重新检测」。若仍不行，点「生成诊断报告」把结果发回来。",
            ]
        } else {
            lines += ["", "已就绪！在「访达」或桌面右键即可使用增强菜单。"]
        }
        statusLabel.stringValue = lines.joined(separator: "\n")
        openSettingsButton.isHidden = trusted

        // 开机自启动状态
        //
        // 注意：**不要**因为 `.notFound` 就禁用勾选框。实测（自签名、无 TeamIdentifier
        // 的 App 放在 /Applications）未注册过时 `SMAppService.mainApp.status` 返回的是
        // `.notFound`，而 `.notFound` 状态下 `register()` 是能成功的：
        //     notFound(3) → register() 成功 → enabled(1)
        // 之前把 `.notFound` 当成「不可用」直接禁用勾选框，用户根本点不下去，
        // 于是永远无法开启（客户报的「无法勾选」就是这个）。
        let loginStatus = SMAppService.mainApp.status
        launchAtLoginCheckbox.state = (loginStatus == .enabled) ? .on : .off
        launchAtLoginCheckbox.isEnabled = true
        SLog.log("开机自启动状态：rawValue=\(loginStatus.rawValue)"
                 + "（0=未注册 1=已启用 2=待批准 3=未找到；3 仍可注册）")
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

        diagnosticsButton.target = self
        diagnosticsButton.action = #selector(makeDiagnostics)

        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(toggleLaunchAtLogin)

        let quitButton = NSButton(title: "退出", target: self, action: #selector(quitApp))

        let buttonRow = NSStackView(views: [openSettingsButton, recheckButton, diagnosticsButton, quitButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        // 常用目录 / 常用 App：在这里配置，右键菜单里出现。改动即写回并通知菜单。
        let favoritesHint = NSTextField(wrappingLabelWithString: "下面的条目会出现在右键菜单里（可排序、可移除）。")
        favoritesHint.font = .systemFont(ofSize: 11)
        favoritesHint.textColor = .secondaryLabelColor

        let directoriesView = FavoritesListView(
            title: "常用目录",
            chooseApplication: false,
            emptyHint: "还没有配置。点「添加目录…」把常去的文件夹加进来。",
            load: { Favorites.directories },
            onAdd: { Favorites.addDirectory($0) },
            onRemove: { Favorites.removeDirectory(at: $0) },
            onMove: { Favorites.moveDirectory(from: $0, by: $1) }
        )

        let appsView = FavoritesListView(
            title: "常用 App",
            chooseApplication: true,
            emptyHint: "还没有配置。点「添加 App…」加上常用的应用（右键文件即可用它打开）。",
            load: { Favorites.apps },
            onAdd: { Favorites.addApp($0) },
            onRemove: { Favorites.removeApp(at: $0) },
            onMove: { Favorites.moveApp(from: $0, by: $1) }
        )

        // 配置变了一律重读（单一数据源），避免界面与菜单不一致。
        self.directoriesView = directoriesView
        self.appsView = appsView
        favoritesObserver = NotificationCenter.default.addObserver(
            forName: Favorites.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadFavorites()
        }

        let stack = NSStackView(views: [titleLabel, statusLabel, hintLabel, launchAtLoginCheckbox,
                                        buttonRow, favoritesHint, directoriesView, appsView])
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
            directoriesView.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            directoriesView.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            appsView.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            appsView.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
    }

    @objc private func openSettings() {
        PermissionManager.shared.prompt()               // 注册进辅助功能列表并触发授权弹窗
        PermissionManager.shared.openAccessibilitySettings()
    }

    @objc private func recheck() {
        // 已授权但拦截没起来时，顺手补一次「输入监控」授权请求（新版 macOS 的常见缺口）。
        if PermissionManager.shared.isTrusted && !PermissionManager.shared.canListenEvents {
            PermissionManager.shared.requestListenEventAccess()
        }
        onRecheck?()
        refresh()
    }

    @objc private func makeDiagnostics() {
        Diagnostics.collectAndExport()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                SLog.log("已关闭开机自启动")
            } else {
                // .notFound / .notRegistered 都能注册成功（已实测），交给 register() 决定。
                try SMAppService.mainApp.register()
                SLog.log("已开启开机自启动（status → \(SMAppService.mainApp.status.rawValue)）")
            }
        } catch {
            SLog.log("开机自启动设置失败: \(error)")
            let alert = NSAlert()
            alert.messageText = "设置开机自启动失败"
            alert.informativeText = """
                \(error.localizedDescription)

                请确认 App 位于「应用程序」文件夹（不要从下载目录或 dist 副本里运行时设置），
                然后重试。也可以到「系统设置 → 通用 → 登录项与扩展」手动查看。
                """
            alert.addButton(withTitle: "好")
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
