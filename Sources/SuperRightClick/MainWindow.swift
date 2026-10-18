import AppKit
import ServiceManagement

/// 主窗口：展示运行状态、权限引导与使用说明。
final class MainWindowController: NSWindowController {

    /// 「重新检测」回调（由 AppDelegate 注入）。
    var onRecheck: (() -> Void)?

    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let licenseLabel = NSTextField(wrappingLabelWithString: "")
    private let removeLicenseButton = NSButton(title: "移除授权", target: nil, action: nil)
    private let licenseButton = NSButton(title: "输入授权码…", target: nil, action: nil)
    private let openSettingsButton = NSButton(title: "打开系统设置", target: nil, action: nil)
    private let recheckButton = NSButton(title: "重新检测", target: nil, action: nil)
    private let diagnosticsButton = NSButton(title: "生成诊断报告", target: nil, action: nil)
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "开机自启动", target: nil, action: nil)

    /// 「常用目录 / 常用 App」两块列表；监听 Favorites 变更以保持界面与配置一致。
    private var directoriesView: FavoritesListView?
    private var appsView: FavoritesListView?
    private var favoritesObserver: NSObjectProtocol?
    private var showTabObserver: NSObjectProtocol?
    private let pageContainer = NSView()
    private var pages: [NSView] = []
    private var selectedPage = 0
    private let tabSelector = NSSegmentedControl()

    /// 菜单里「管理常用目录 / App…」用它把主界面切到对应页。
    static let showTabNotification = Notification.Name("com.superrightclick.showPreferencesTab")

    /// 打开已有窗口时用：重新读一遍状态（含常用列表）。
    func reloadFavorites() {
        directoriesView?.reload()
        appsView?.reload()
    }

    deinit {
        if let favoritesObserver { NotificationCenter.default.removeObserver(favoritesObserver) }
        if let showTabObserver { NotificationCenter.default.removeObserver(showTabObserver) }
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "超级右键"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 540, height: 420)
        window.center()
        super.init(window: window)
        buildContent()
        refresh()
        // 菜单里点「管理常用目录 / App…」→ 显示窗口并切到那一页。
        showTabObserver = NotificationCenter.default.addObserver(
            forName: Self.showTabNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            if let index = note.userInfo?["index"] as? Int { self.showTab(index) }
            self.showWindow()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showWindow() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        refresh()
    }

    /// 授权状态（含试用倒计时）；每秒刷新，不触碰权限检测。
    func refreshLicense() {
        licenseLabel.stringValue = "授权状态：" + LicenseController.shared.detailText
            + "\n本机 ID：" + String(LicenseManager.shared.machineID.prefix(16))
        if case .licensed = LicenseManager.shared.status() {
            licenseButton.title = "更换授权码…"
            removeLicenseButton.isHidden = false
        } else {
            licenseButton.title = "输入授权码…"
            removeLicenseButton.isHidden = true
        }
    }

    @objc private func removeLicense() {
        let alert = NSAlert()
        alert.messageText = "移除当前授权？"
        alert.informativeText = "移除后本机将回到未授权状态，需要重新输入授权码；该授权码占用的机器名额不会自动释放。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "移除")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        LicenseManager.shared.clearLicense()
        refreshLicense()
    }

    @objc private func enterLicense() {
        LicenseController.shared.promptActivation()
    }

    func refresh() {
        refreshLicense()
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

        let titleLabel = NSTextField(labelWithString: "超级右键 SuperRightClick")
        titleLabel.font = .systemFont(ofSize: 16, weight: .bold)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let subtitleLabel = NSTextField(labelWithString: "版本 \(version) · 原生 AppKit，纯本地运行")
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor

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
        let directoriesView = FavoritesListView(
            title: "常用目录",
            chooseApplication: false,
            emptyHint: "还没有配置。点「添加目录…」，或在访达里右键某个文件夹选「将本目录加入常用目录」。",
            load: { Favorites.directories },
            onAdd: { Favorites.addDirectory($0) },
            onRemove: { Favorites.removeDirectory(at: $0) },
            onMove: { Favorites.moveDirectory(from: $0, by: $1) }
        )

        let appsView = FavoritesListView(
            title: "常用 App",
            chooseApplication: true,
            emptyHint: "还没有配置。点「添加 App…」，或在右键菜单「常用 App」里选「添加 App…」。",
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

        // 分页：一页一件事，避免窗口又高又空。
        licenseLabel.font = .systemFont(ofSize: 13, weight: .medium)
        licenseLabel.preferredMaxLayoutWidth = 340
        licenseButton.target = self
        licenseButton.action = #selector(enterLicense)
        removeLicenseButton.target = self
        removeLicenseButton.action = #selector(removeLicense)
        let licenseRow = NSStackView(views: [licenseLabel, licenseButton, removeLicenseButton])
        licenseRow.orientation = .horizontal
        licenseRow.alignment = .centerY
        licenseRow.spacing = 12
        let statusPage = makePage([
            titleLabel,
            subtitleLabel,
            licenseRow,
            statusLabel,
            hintLabel,
            launchAtLoginCheckbox,
            buttonRow,
        ])
        let directoriesPage = makePage([
            pageHint("这里的条目会出现在右键菜单「常用目录」里。点条目即在访达打开该文件夹。"),
            directoriesView,
        ], stretch: [directoriesView], fillHeight: true)
        let appsPage = makePage([
            pageHint("这里的条目会出现在右键菜单「常用 App」里。选中文件后点它即用该 App 打开；在空白处右键则只是启动该 App。"),
            appsView,
        ], stretch: [appsView], fillHeight: true)

        func aboutTitle(_ t: String) -> NSTextField {
            let l = NSTextField(labelWithString: t)
            l.font = .systemFont(ofSize: 13, weight: .semibold)
            return l
        }
        func aboutBody(_ t: String) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: t)
            l.font = .systemFont(ofSize: 12)
            l.preferredMaxLayoutWidth = 500
            return l
        }
        let aboutPage = makePage([
            aboutTitle("简介"),
            aboutBody("超级右键为 macOS 访达补充常用的右键功能：新建文件、复制路径、在终端打开、常用目录与常用 App 快捷入口等。使用原生 AppKit 开发，所有功能在本机运行，不上传任何文件或使用数据。"),
            aboutTitle("授权说明"),
            aboutBody("首次使用可免费试用 1 天；输入有效授权码激活后可长期使用。仅在激活或授权到期续期时联网校验授权码，其余时间完全离线。"),
            aboutTitle("版权声明"),
            aboutBody("© 2026 超级右键 SuperRightClick 版权所有。\n本软件受著作权法保护，未经许可，不得复制、反向工程、转售或以其他方式擅自传播。\n使用中如有问题或者反馈意见请联系2497524724@qq.com"),
            aboutBody("版本 \(version)"),
        ])

        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        pages = [statusPage, directoriesPage, appsPage, aboutPage]
        for (index, page) in pages.enumerated() {
            page.translatesAutoresizingMaskIntoConstraints = false
            page.isHidden = index != selectedPage
            pageContainer.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
                page.topAnchor.constraint(equalTo: pageContainer.topAnchor),
                page.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
            ])
        }

        tabSelector.segmentCount = 4
        tabSelector.setLabel("状态", forSegment: 0)
        tabSelector.setLabel("常用目录", forSegment: 1)
        tabSelector.setLabel("常用 App", forSegment: 2)
        tabSelector.setLabel("关于", forSegment: 3)
        tabSelector.trackingMode = .selectOne
        tabSelector.selectedSegment = 0
        tabSelector.target = self
        tabSelector.action = #selector(tabChanged)

        let panel = PanelView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(pageContainer)
        NSLayoutConstraint.activate([
            pageContainer.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20),
            pageContainer.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -20),
            pageContainer.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
            pageContainer.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16),
        ])

        let root = NSStackView(views: [tabSelector, panel])
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
            panel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    /// 一页的内容：纵向堆叠，顶部对齐，底部不撑开。
    /// `stretch` 里的视图会在**页内**撑满宽度（不能钉到 tabView：页只在标签被选中时才
    /// 进入 tabView 的视图层级，那时两者还没有共同祖先，激活约束会直接抛异常）。
    private func makePage(_ views: [NSView], stretch: [NSView] = [], fillHeight: Bool = false) -> NSView {
        let page = NSView()
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        let bottom = fillHeight
            ? stack.bottomAnchor.constraint(equalTo: page.bottomAnchor)
            : stack.bottomAnchor.constraint(lessThanOrEqualTo: page.bottomAnchor)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            stack.topAnchor.constraint(equalTo: page.topAnchor),
            bottom,
        ] + stretch.flatMap { view in
            [view.leadingAnchor.constraint(equalTo: page.leadingAnchor),
             view.trailingAnchor.constraint(equalTo: page.trailingAnchor)]
        })
        return page
    }

    private func pageHint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 500
        return label
    }

    @objc private func tabChanged() {
        showTab(tabSelector.selectedSegment)
    }

    /// 当前页索引（internal：便于测试分页切换）。
    var currentTabIndex: Int { selectedPage }

    /// 切换到某一页（0=状态 1=常用目录 2=常用 App）。菜单里的「管理…」也走这里。
    func showTab(_ index: Int) {
        let clamped = max(0, min(index, pages.count - 1))
        selectedPage = clamped
        tabSelector.selectedSegment = clamped
        for (i, page) in pages.enumerated() { page.isHidden = i != clamped }
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


private final class PanelView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
    override var wantsUpdateLayer: Bool { true }
}
