import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var mainWindow: MainWindowController?
    private var trustTimer: Timer?
    private let permissions = PermissionManager.shared
    private let menuBuilder = MenuBuilder()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Actions.refreshCachedState()      // 预热隐藏文件开关等缓存
        Actions.warmOpenableAppsCache()   // 后台预热「打开方式」，让首次右键也直接命中缓存
        setupStatusItem()
        setupMainWindow()
        startEventTapIfPossible()
        updateStatusMenu()
        mainWindow?.showWindow()          // 启动即显示主窗口，给出明确反馈
        if !permissions.isTrusted {
            permissions.prompt()          // 触发系统授权弹窗，并把本 App 注册进辅助功能列表
            startTrustPolling()
        }
    }

    private func setupMainWindow() {
        let wc = MainWindowController()
        wc.onRecheck = { [weak self] in self?.startEventTapIfPossible() }
        mainWindow = wc
    }

    private func setupStatusItem() {
        // 图标 + 文字，确保菜单栏入口清晰可见。
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "filemenu.and.cursorarrow", accessibilityDescription: "超级右键")
                ?? NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)
            image?.isTemplate = true
            button.image = image
            button.title = "超级右键"
        }
        statusItem = item
    }

    func startEventTapIfPossible() {
        guard permissions.isTrusted else {
            mainWindow?.refresh()
            return
        }
        EventTapManager.shared.onRightClick = { [weak self] in
            self?.menuBuilder.show()
        }
        EventTapManager.shared.prepareMenu = { [weak self] in
            self?.menuBuilder.prepare()
        }
        if EventTapManager.shared.start() {
            NSLog("[SuperRightClick] 右键拦截已启动")
            prewarmFinderAutomation()
        } else {
            NSLog("[SuperRightClick] 右键拦截启动失败")
        }
        mainWindow?.refresh()
    }

    /// 预触发一次对「访达」的自动化授权（一次性弹窗），后台执行避免阻塞启动。
    private func prewarmFinderAutomation() {
        DispatchQueue.global(qos: .utility).async {
            FinderBridge.runAppleScript("tell application \"Finder\" to get name")
        }
    }

    private func updateStatusMenu() {
        let menu = NSMenu()
        let state = EventTapManager.shared.isRunning ? "已启用" : "未授权"
        let title = NSMenuItem(title: "超级右键（\(state)）", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        let openMain = NSMenuItem(title: "打开主界面", action: #selector(openMainWindow), keyEquivalent: "")
        openMain.target = self
        menu.addItem(openMain)

        let check = NSMenuItem(title: "重新检测权限", action: #selector(recheckPermissions), keyEquivalent: "")
        check.target = self
        menu.addItem(check)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    @objc private func openMainWindow() {
        mainWindow?.showWindow()
    }

    @objc private func recheckPermissions() {
        if permissions.isTrusted {
            startEventTapIfPossible()
        } else {
            permissions.prompt()          // 未授权时主动触发系统授权流程
        }
        updateStatusMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func startTrustPolling() {
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.permissions.isTrusted && !EventTapManager.shared.isRunning {
                self.startEventTapIfPossible()
                self.updateStatusMenu()
                self.trustTimer?.invalidate()
                self.trustTimer = nil
            }
        }
    }
}
