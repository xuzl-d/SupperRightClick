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
    private var showGeneration = 0

    /// 当前这次弹出中「打开方式 / 共享」两个子菜单的引用。
    /// 后台枚举完成时用它判断子菜单是否还在展示，从而回填内容（否则用户会一直看到「加载中…」）。
    private var openWithSubmenu: NSMenu?
    private var sendToSubmenu: NSMenu?

    // MARK: - 入口

    /// 右键按下时调用：后台预取 Finder 选中项与窗口目录。
    func prepare() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            FinderBridge.prefetchSelection()
            FinderBridge.prefetchFrontWindowDir()
        }
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

        // 优先用预取缓存，未就绪才同步兜底（快速连点等罕见场景）。
        let selection: [URL]
        if let cached = FinderBridge.selectionCached() {
            selection = cached
        } else {
            selection = FinderBridge.selection()
        }
        currentSelection = selection
        currentTargetDir = resolveTargetDirectory(selection: selection)

        let menu = build(selection: selection, targetDir: currentTargetDir)
        tap.cancelCurrentMenu = { menu.cancelTracking() }
        SLog.log("自定义菜单已弹出")
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        tap.cancelCurrentMenu = nil
        tap.isShowingMenu = false
        // 菜单已收起：清掉子菜单引用，避免迟到的回调去改一个已经没人看的菜单。
        openWithSubmenu = nil
        sendToSubmenu = nil
        SLog.log("自定义菜单已关闭")
    }

    // MARK: - 菜单构建（必须快，只做轻量操作）

    private func build(selection: [URL], targetDir: URL?) -> NSMenu {
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

        // 2. 文件操作
        var fileOps: [NSMenuItem] = []
        if !selection.isEmpty {
            fileOps.append(actionItem("打开", "arrow.up.right.square") { Actions.openDefault(selection) })
            fileOps.append(actionItem("快速查看", "eye") { Actions.quickLook(selection[0]) })
        }
        if selection.count == 1 {
            fileOps.append(actionItem("重命名", "pencil") { Actions.rename(selection[0]) })
        }
        if !fileOps.isEmpty { sections.append(fileOps) }

        // 3. 剪贴板（复制路径 / 文件名 / 复制副本 / 拷贝 / 剪切 / 粘贴）
        var clipboard: [NSMenuItem] = [
            actionItem("复制路径", "doc.on.doc") { Actions.copyPaths(selection, fallbackDir: targetDir) }
        ]
        if !selection.isEmpty {
            clipboard.append(actionItem("复制文件名", "textformat") { Actions.copyFileNames(selection) })
            clipboard.append(actionItem("复制", "plus.square.on.square") { Actions.duplicate(selection) })
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

        // 5. 终端
        var terminal: [NSMenuItem] = [
            actionItem("用终端打开", "terminal") { Actions.openInTerminal(targetDir) }
        ]
        if Actions.iTermExists() {
            terminal.append(actionItem("用 iTerm 打开", "terminal.fill") { Actions.openInITerm(targetDir) })
        }
        sections.append(terminal)

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

        // 7. 显示相关（标签 / 隐藏 / 隐藏文件开关）
        var display: [NSMenuItem] = []
        if !selection.isEmpty {
            display.append(makeLabelSubmenu(selection: selection))
            let hidden = Actions.firstIsHidden(selection)
            display.append(actionItem(hidden ? "显示" : "隐藏", "eye.slash") { Actions.toggleHidden(selection) })
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
        return FinderBridge.frontWindowTargetDirectory()
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
        openWithSubmenu = sub
        Actions.loadOpenableApps(for: selection)   // 后台预加载
        return item
    }

    private func makeSendToSubmenu(selection: [URL]) -> NSMenuItem {
        let item = NSMenuItem(title: "共享", action: nil, keyEquivalent: "")
        item.image = symbol("paperplane")
        let sub = NSMenu(title: "共享")
        sub.autoenablesItems = false
        sub.delegate = self
        item.submenu = sub
        sendToSubmenu = sub
        Actions.loadSharingServices(for: selection)   // 后台预加载
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

        // 尚未枚举完成：先占位，并在完成时回填「同一个」子菜单。
        // 只写缓存不刷新界面的话，用户会一直停在「加载中…」直到重新悬停一次。
        guard Actions.isOpenableAppsLoaded(for: selection) else {
            menu.addItem(disabledItem("加载中…"))
            Actions.loadOpenableApps(for: selection) { [weak self] in
                guard let self, self.openWithSubmenu === menu else { return }
                self.fillOpenWithSubmenu(menu)
                menu.update()
            }
            return
        }

        // 已加载（空结果也算已加载，不会再触发枚举）。
        let apps = Actions.openableAppsCache[Actions.appsKey(for: selection)] ?? []
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

        guard Actions.isSharingServicesLoaded(for: selection) else {
            menu.addItem(disabledItem("加载中…"))
            Actions.loadSharingServices(for: selection) { [weak self] in
                guard let self, self.sendToSubmenu === menu else { return }
                self.fillSendToSubmenu(menu)
                menu.update()
            }
            return
        }

        let services = Actions.sharingCache[Actions.appsKey(for: selection)] ?? []
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
