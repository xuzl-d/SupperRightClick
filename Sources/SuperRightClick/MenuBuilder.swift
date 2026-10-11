import AppKit

/// 承载菜单项闭包动作的 target。
final class ActionItem: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke(_ sender: Any?) { handler() }
}

/// 根据右键上下文构建自定义 NSMenu。
/// 性能策略：右键按下时后台预取数据（prepare），弹菜单时直接用缓存（show），
/// 打开方式 / 发送到子菜单懒加载（menuNeedsUpdate）+ 缓存。
final class MenuBuilder: NSObject, NSMenuDelegate {

    /// 当前菜单上下文（构建菜单时捕获）。
    private var currentSelection: [URL] = []
    private var currentTargetDir: URL?
    /// 本次右键若落在访达侧边栏项目上，这里是它指向的目录（否则 nil）。
    private var currentSidebarFolder: URL?
    private var showGeneration = 0
    /// 本次右键的预取 token：只有它对应的选中项才允许用于建菜单。
    private var selectionToken: UUID?
    /// 同理：本次右键的前台窗口目录 token。
    private var frontDirToken: UUID?

    // MARK: - 入口

    /// 右键按下时调用：后台预取 Finder 选中项与窗口目录。
    func prepare() {
        // 每次右键都重新开一次预取，并把结果绑定到这一次的 token 上。
        // 不能用时间窗口（TTL）——那会在「右键文件 → 再右键空白处」时拿上一次的选中项建菜单，
        // 也会在「刚在废纸篓窗口剪切 → 到文稿窗口粘贴」时拿上一次的窗口目录当目标。
        selectionToken = FinderBridge.beginSelectionPrefetch()
        frontDirToken = FinderBridge.beginFrontDirPrefetch()
    }

    /// 右键抬起时调用：立即弹菜单。
    /// 若旧菜单还在展示（右键重定位场景），先关闭旧菜单再在新位置弹出。
    func show() {
        showGeneration += 1
        let gen = showGeneration
        let tap = EventTapManager.shared

        if tap.isShowingMenu {
            SLog.log("关闭旧菜单，准备重定位新菜单")
            tap.cancelCurrentMenu?()
            tap.cancelCurrentMenu = nil
            tap.isShowingMenu = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self, gen == self.showGeneration else { return }
                self.popMenu()
            }
        } else {
            popMenu()
        }
    }

    private func popMenu() {
        let tap = EventTapManager.shared
        tap.isShowingMenu = true
        SLog.log("准备弹出自定义菜单")

        // 只用「本次右键」的预取结果；还没回来就同步兜底（带 1s 超时）。
        // 兜底必须带超时：这里在主线程上，一旦 AppleScript 被授权弹窗或卡住的访达拖住，
        // 菜单就永远不会出现（客户报「右键没反应」的典型成因之一）。
        let selection: [URL]
        if let cached = FinderBridge.selectionForCurrentClick(token: selectionToken) {
            selection = cached
            SLog.log("使用本次右键的预取选中项：\(cached.count) 项")
        } else {
            selection = FinderBridge.selectionWithTimeout()
            SLog.log("预取未就绪，改用同步读取选中项：\(selection.count) 项")
        }
        currentSelection = selection
        // 右键侧边栏项目时 selection 为空 —— 先把侧边栏指向的目录解析出来，
        // 供「目标目录」和「在新标签页中打开」共用（避免重复做辅助功能命中）。
        currentSidebarFolder = selection.isEmpty
            ? FinderBridge.sidebarFolder(at: EventTapManager.shared.lastClickLocation)
            : nil
        currentTargetDir = resolveTargetDirectory(selection: selection)

        let menu = build(selection: selection, targetDir: currentTargetDir)
        tap.cancelCurrentMenu = { menu.cancelTracking() }
        SLog.log("自定义菜单已弹出")
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        tap.cancelCurrentMenu = nil
        tap.isShowingMenu = false
        SLog.log("自定义菜单已关闭")
    }

    // MARK: - 菜单构建（必须快，只做轻量操作）

    /// （internal 而非 private：便于测试菜单渲染结果。）
    func build(selection: [URL], targetDir: URL?) -> NSMenu {
        let menu = NSMenu(title: "SuperRightClick")
        menu.autoenablesItems = false
        let isDesktop = EventTapManager.shared.lastClickOnDesktop
        let canPaste = Actions.pasteboardHasFileURLs()

        var sections: [[NSMenuItem]] = []

        // 1. 新建 / 打开方式 / 发送到
        var core: [NSMenuItem] = [makeNewFileSubmenu(targetDir: targetDir)]
        if !selection.isEmpty {
            core.append(makeOpenWithSubmenu(selection: selection))
            core.append(makeSendToSubmenu(selection: selection))
        }
        sections.append(core)

        // 2. 常用（在主界面配置；没配置就不显示，避免菜单变长）
        var favorites: [NSMenuItem] = []
        if !Favorites.availableDirectories.isEmpty {
            favorites.append(makeFavoriteDirectoriesSubmenu())
        }
        if !Favorites.availableApps.isEmpty {
            favorites.append(makeFavoriteAppsSubmenu(selection: selection))
        }
        if !favorites.isEmpty { sections.append(favorites) }

        // 2. 文件操作
        var fileOps: [NSMenuItem] = []
        if !selection.isEmpty {
            fileOps.append(actionItem("打开", "arrow.up.right.square") { Actions.openDefault(selection) })
            fileOps.append(actionItem("快速查看", "eye") { Actions.quickLook(selection[0]) })
        }
        if selection.count == 1 {
            fileOps.append(actionItem("重命名", "pencil") { Actions.rename(selection[0]) })
            if Actions.isDirectory(selection[0]) {
                fileOps.append(actionItem("在新标签页中打开", "plus.rectangle.on.rectangle") { Actions.openInNewTab(selection[0]) })
            }
        }
        // 右键访达侧边栏项目（如「文稿」）时选中项为空，但侧边栏本身指向一个文件夹，
        // 同样给「在新标签页中打开」。
        if selection.isEmpty, let sidebar = currentSidebarFolder {
            fileOps.append(actionItem("在新标签页中打开", "plus.rectangle.on.rectangle") {
                Actions.openInNewTab(sidebar)
            })
        }
        if !fileOps.isEmpty { sections.append(fileOps) }

        // 3. 剪贴板（复制路径 / 文件名 / 拷贝 / 剪切 / 粘贴）
        var clipboard: [NSMenuItem] = [
            actionItem("复制路径", "doc.on.doc") { Actions.copyPaths(selection, fallbackDir: targetDir) }
        ]
        if !selection.isEmpty {
            clipboard.append(actionItem("复制文件名", "textformat") { Actions.copyFileNames(selection) })
            clipboard.append(actionItem("拷贝", "doc.on.doc") { Actions.copyFiles(selection) })
            clipboard.append(actionItem("剪切", "scissors") { Actions.cutFiles(selection) })
        }
        let pasteItem = actionItem("粘贴", "doc.on.clipboard") { Actions.pasteFiles(to: targetDir) }
        pasteItem.isEnabled = canPaste
        clipboard.append(pasteItem)
        sections.append(clipboard)

        // 4. 压缩 / 解压
        var archive: [NSMenuItem] = []
        if !selection.isEmpty {
            archive.append(actionItem("压缩", "archivebox") { Actions.compress(selection) })
            if selection.count == 1 && Actions.isArchive(selection[0]) {
                archive.append(actionItem("解压", "shippingbox") { Actions.decompress(selection[0]) })
            }
        }
        if !archive.isEmpty { sections.append(archive) }

        // 5. 工具（截图 / 终端）
        var tools: [NSMenuItem] = [
            makeScreenshotSubmenu(targetDir: targetDir),
            actionItem("用终端打开", "terminal") { Actions.openInTerminal(targetDir) }
        ]
        if Actions.iTermExists() {
            tools.append(actionItem("用 iTerm 打开", "terminal.fill") { Actions.openInITerm(targetDir) })
        }
        sections.append(tools)

        // 6. 空白处系统菜单复刻（整理 / 堆栈 / 排序 / 显示选项 / 壁纸）
        var areaOps: [NSMenuItem] = []
        if selection.isEmpty {
            areaOps.append(actionItem(Actions.cleanUpTitle, "wand.and.stars") { Actions.cleanUp() })
            if isDesktop {
                areaOps.append(actionItem(Actions.stacksTitle, "square.3.layers.3d") { Actions.toggleStacks() })
            }
            areaOps.append(makeSortSubmenu())
            areaOps.append(actionItem("查看显示选项", "rectangle.3.group") { Actions.showViewOptions() })
            if isDesktop {
                areaOps.append(actionItem("更改桌面背景…", "photo") { Actions.openWallpaperSettings() })
            }
        }
        if !areaOps.isEmpty { sections.append(areaOps) }

        // 7. 显示相关（标签 / 隐藏或取消隐藏（互斥） / 隐藏文件开关）
        var display: [NSMenuItem] = []
        if !selection.isEmpty {
            display.append(makeLabelSubmenu(selection: selection))
            // 互斥：已隐藏只给「取消隐藏」，未隐藏只给「隐藏」。
            let hidden = Actions.firstIsHidden(selection)
            display.append(actionItem(hidden ? "取消隐藏" : "隐藏", hidden ? "eye" : "eye.slash") {
                Actions.setHidden(!hidden, selection)
            })
        }
        display.append(actionItem(Actions.showAllFilesEnabledCached() ? "隐藏隐藏文件" : "显示隐藏文件", "eye") {
            Actions.toggleShowAllFiles()
        })
        sections.append(display)

        // 8. 替身 / 简介
        var more: [NSMenuItem] = []
        if !selection.isEmpty {
            more.append(actionItem("制作替身", "arrow.triangle.branch") { Actions.makeAlias(selection[0]) })
            more.append(actionItem("显示简介", "info.circle") { Actions.showInfo(selection[0]) })
        }
        if !more.isEmpty { sections.append(more) }

        // 9. 删除
        var delete: [NSMenuItem] = []
        if !selection.isEmpty {
            delete.append(actionItem("移到废纸篓", "trash") { Actions.trash(selection) })
            delete.append(actionItem("立即删除", "trash.slash") { Actions.deleteDirectly(selection) })
        }
        if !delete.isEmpty { sections.append(delete) }

        // 组装：组间加分隔线
        for (index, section) in sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for item in section { menu.addItem(item) }
        }

        // 兜底：完整系统菜单（复刻未覆盖项）
        menu.addItem(.separator())
        menu.addItem(actionItem("显示系统菜单", "arrow.uturn.backward") {
            EventTapManager.shared.showSystemMenu()
        })

        return menu
    }

    // MARK: - 上下文解析

    private func resolveTargetDirectory(selection: [URL]) -> URL? {
        if let first = selection.first {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir), isDir.boolValue {
                return first
            }
            return first.deletingLastPathComponent()
        }
        // 右键落在**桌面**上：目标必须是桌面，不能取「最前面窗口的目录」。
        // 用户从某个文件夹剪切后，那个窗口往往还开着且是最前面的，于是目标会算成来源文件夹
        // → 命中「贴回原目录」→ 看起来"粘贴没反应"。（桌面这一信息在判定访达时已算出。）
        if EventTapManager.shared.lastClickOnDesktop {
            return FinderBridge.desktopDirectory()
        }
        // 选中项为空：可能是在**侧边栏项目**上右键（如「文稿」）。
        // 必须先用侧边栏本身 —— 否则会退化成「最前面窗口的目录」，
        // 而那个窗口可能还是上一个（例如废纸篓），于是粘贴目标算错。
        // （侧边栏解析已在 popMenu 里做一次并缓存到 currentSidebarFolder。）
        if let sidebar = currentSidebarFolder {
            return sidebar
        }
        // 只用「本次右键」的前台窗口目录快照；没就绪就同步读（带超时）。
        // 绝不能用上一次的快照 —— 那正是「在文稿窗口粘贴却落到废纸篓」的原因。
        if let snapshot = FinderBridge.frontDirForCurrentClick(token: frontDirToken) {
            return snapshot
        }
        SLog.log("窗口目录快照未就绪，改用同步读取")
        return FinderBridge.frontWindowTargetDirectoryWithTimeout()
    }

    // MARK: - 子菜单（懒加载）

    private func makeNewFileSubmenu(targetDir: URL?) -> NSMenuItem {
        let item = NSMenuItem(title: "新建文件", action: nil, keyEquivalent: "")
        item.image = symbol("doc.badge.plus")

        let sub = NSMenu(title: "新建文件")
        sub.autoenablesItems = false
        sub.addItem(actionItem("新建文件夹", "folder.badge.plus") { Actions.newFolder(at: targetDir) })
        sub.addItem(.separator())
        for template in Templates.all() {
            sub.addItem(actionItem(template.displayName, template.symbol) {
                Actions.newFile(template: template, at: targetDir)
            })
        }
        item.submenu = sub
        return item
    }

    private func makeOpenWithSubmenu(selection: [URL]) -> NSMenuItem {
        let item = NSMenuItem(title: "打开方式", action: nil, keyEquivalent: "")
        item.image = symbol("square.on.square")
        let sub = NSMenu(title: "打开方式")
        sub.autoenablesItems = false
        sub.delegate = self
        item.submenu = sub
        // 内容在子菜单展开时同步填充（见 fillOpenWithSubmenu），构建阶段不做枚举。
        return item
    }

    // MARK: - 常用目录 / 常用 App（主界面配置，这里只渲染）

    private func makeFavoriteDirectoriesSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: "常用目录", action: nil, keyEquivalent: "")
        item.image = symbol("folder")
        let sub = NSMenu(title: "常用目录")
        sub.autoenablesItems = false
        for url in Favorites.availableDirectories {
            let entry = NSMenuItem(title: url.lastPathComponent, action: #selector(ActionItem.invoke(_:)), keyEquivalent: "")
            let target = ActionItem { Actions.openDirectory(url) }
            entry.target = target
            entry.representedObject = target
            entry.image = menuIcon(for: url)
            entry.toolTip = url.path
            sub.addItem(entry)
        }
        item.submenu = sub
        return item
    }

    private func makeFavoriteAppsSubmenu(selection: [URL]) -> NSMenuItem {
        let item = NSMenuItem(title: "常用 App", action: nil, keyEquivalent: "")
        item.image = symbol("square.grid.2x2")
        let sub = NSMenu(title: "常用 App")
        sub.autoenablesItems = false
        for app in Favorites.availableApps {
            let entry = NSMenuItem(title: app.deletingPathExtension().lastPathComponent,
                                   action: #selector(ActionItem.invoke(_:)), keyEquivalent: "")
            let target = ActionItem {
                // 选中了文件 → 用它打开这些文件；在空白处右键（无选中）→ 只是启动这个 App。
                if selection.isEmpty {
                    Actions.openDefault([app])
                } else {
                    Actions.openWith(app: app, urls: selection)
                }
            }
            entry.target = target
            entry.representedObject = target
            entry.image = menuIcon(for: app)
            entry.toolTip = app.path
            sub.addItem(entry)
        }
        item.submenu = sub
        return item
    }

    /// 菜单里 16×16 的文件/应用图标。
    private func menuIcon(for url: URL) -> NSImage? {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    private func makeSendToSubmenu(selection: [URL]) -> NSMenuItem {
        let item = NSMenuItem(title: "共享", action: nil, keyEquivalent: "")
        item.image = symbol("paperplane")
        let sub = NSMenu(title: "共享")
        sub.autoenablesItems = false
        sub.delegate = self
        item.submenu = sub
        return item
    }

    private func makeLabelSubmenu(selection: [URL]) -> NSMenuItem {
        let item = NSMenuItem(title: "标签…", action: nil, keyEquivalent: "")
        item.image = symbol("tag")
        let sub = NSMenu(title: "标签")
        sub.autoenablesItems = false
        let names = ["无", "红", "橙", "黄", "绿", "蓝", "紫", "灰"]
        for (index, name) in names.enumerated() {
            let it = NSMenuItem(title: name, action: #selector(ActionItem.invoke(_:)), keyEquivalent: "")
            let target = ActionItem {
                for url in selection { Actions.setLabel(url, index: index) }
            }
            it.target = target
            it.representedObject = target
            it.image = Actions.labelColorImage(index)
            sub.addItem(it)
        }
        item.submenu = sub
        return item
    }

    private func makeSortSubmenu() -> NSMenuItem {
        let item = NSMenuItem(title: Actions.sortByMenuTitle, action: nil, keyEquivalent: "")
        item.image = symbol("arrow.up.arrow.down")
        let sub = NSMenu(title: "排序方式")
        sub.autoenablesItems = false
        for (name, value) in Actions.sortOptions() {
            sub.addItem(actionItem(name, "arrow.up.arrow.down") { Actions.arrangeBy(value) })
        }
        item.submenu = sub
        return item
    }

    /// 截图子菜单：三种取景方式 × 存文件 / 进剪贴板。
    /// 只依赖 targetDir，因此无论右键点的是文件、文件夹还是空白处都可用。
    private func makeScreenshotSubmenu(targetDir: URL?) -> NSMenuItem {
        let item = NSMenuItem(title: "截图", action: nil, keyEquivalent: "")
        item.image = symbol("camera.viewfinder")
        let sub = NSMenu(title: "截图")
        sub.autoenablesItems = false

        sub.addItem(actionItem("区域截图（存到当前文件夹）", "viewfinder") {
            Screenshot.capture(.region, to: .file, in: targetDir)
        })
        sub.addItem(actionItem("窗口截图（存到当前文件夹）", "macwindow") {
            Screenshot.capture(.window, to: .file, in: targetDir)
        })
        sub.addItem(actionItem("全屏截图（存到当前文件夹）", "display") {
            Screenshot.capture(.screen, to: .file, in: targetDir)
        })
        sub.addItem(.separator())
        sub.addItem(actionItem("区域截图到剪贴板", "doc.on.clipboard") {
            Screenshot.capture(.region, to: .clipboard, in: targetDir)
        })
        sub.addItem(actionItem("窗口截图到剪贴板", "doc.on.clipboard") {
            Screenshot.capture(.window, to: .clipboard, in: targetDir)
        })
        sub.addItem(actionItem("全屏截图到剪贴板", "doc.on.clipboard") {
            Screenshot.capture(.screen, to: .clipboard, in: targetDir)
        })
        item.submenu = sub
        return item
    }

    // MARK: - NSMenuDelegate（子菜单展开时才填充内容）

    func menuNeedsUpdate(_ menu: NSMenu) {
        switch menu.title {
        case "打开方式":
            fillOpenWithSubmenu(menu)
        case "共享":
            fillSendToSubmenu(menu)
        default:
            break
        }
    }

    private func fillOpenWithSubmenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let selection = currentSelection
        guard !selection.isEmpty else {
            menu.addItem(disabledItem("没有可打开的应用"))
            return
        }

        // 同步取（缓存优先，未命中就现场枚举 30~90 ms）：内容在子菜单展开的同一拍就绪，
        // 于是绝不会出现「加载中…」——不再依赖「后台枚举完成后回填」那条不可靠的路径。
        let apps = Actions.openableAppsSync(for: selection)
        guard !apps.isEmpty else {
            menu.addItem(disabledItem("没有可打开的应用"))
            return
        }

        for app in apps {
            let it = NSMenuItem(title: app.name, action: #selector(ActionItem.invoke(_:)), keyEquivalent: "")
            let target = ActionItem { Actions.openWith(app: app.url, urls: selection) }
            it.target = target
            it.representedObject = target
            it.image = app.icon
            menu.addItem(it)
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("选择其他应用…", "square.grid.2x2") { Actions.chooseOtherApp(selection) })
    }

    private func fillSendToSubmenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let selection = currentSelection
        guard !selection.isEmpty else {
            menu.addItem(disabledItem("无可用的共享服务"))
            return
        }

        let services = Actions.sharingServicesSync(for: selection)
        guard !services.isEmpty else {
            menu.addItem(disabledItem("无可用的共享服务"))
            return
        }

        for service in services {
            let it = NSMenuItem(title: service.menuItemTitle, action: #selector(ActionItem.invoke(_:)), keyEquivalent: "")
            let target = ActionItem { service.perform(withItems: selection) }
            it.target = target
            it.representedObject = target
            it.image = service.image
            menu.addItem(it)
        }
    }

    // MARK: - 工具

    private func actionItem(_ title: String, _ symbolName: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(ActionItem.invoke(_:)), keyEquivalent: "")
        let target = ActionItem(handler)
        item.target = target
        item.representedObject = target
        item.image = symbol(symbolName)
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
}
