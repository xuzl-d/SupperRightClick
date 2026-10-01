import AppKit
import CoreServices
import UniformTypeIdentifiers

/// 所有右键动作的实现。
enum Actions {

    struct AppInfo {
        let url: URL
        let name: String
        let icon: NSImage?
    }

    // MARK: - 新建

    static func newFolder(at dir: URL?) {
        guard let base = dir ?? FinderBridge.frontWindowTargetDirectory() else { return }
        let name = uniqueName(baseName: "未命名文件夹", ext: "", in: base)
        let target = base.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            FinderBridge.reveal(target)
        } catch {
            log("新建文件夹失败: \(error)")
        }
    }

    static func newFile(template: Template, at dir: URL?) {
        guard let base = dir ?? FinderBridge.frontWindowTargetDirectory() else { return }
        let name = uniqueName(baseName: template.baseName, ext: template.fileExtension, in: base)
        let target = base.appendingPathComponent(name)
        do {
            try template.makeData().write(to: target)
            FinderBridge.reveal(target)
        } catch {
            log("新建文件失败: \(error)")
        }
    }

    private static func uniqueName(baseName: String, ext: String, in dir: URL) -> String {
        let extStr = ext.isEmpty ? "" : ".\(ext)"
        var candidate = baseName + extStr
        var i = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
            candidate = "\(baseName) \(i)" + extStr
            i += 1
        }
        return candidate
    }

    // MARK: - 打开方式

    static func openableApplications(for urls: [URL]) -> [AppInfo] {
        var infos: [AppInfo] = []
        var seen = Set<String>()

        func add(_ appURL: URL) {
            let key = appURL.path
            guard !seen.contains(key) else { return }
            seen.insert(key)
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            infos.append(AppInfo(url: appURL, name: appName(appURL), icon: icon))
        }

        // 1) 常规：系统按文件类型枚举可打开的应用
        for url in urls {
            for appURL in NSWorkspace.shared.urlsForApplications(toOpen: url) {
                add(appURL)
            }
        }

        // 2) 文件夹补充：开发类 App（VSCode 等）可打开文件夹，单独枚举并入
        if urls.contains(where: { isDirectory($0) }) {
            for appURL in folderCapableApps() {
                add(appURL)
            }
        }
        return infos
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// 枚举声明可打开文件夹的 App + 常用开发工具兜底列表。
    static func folderCapableApps() -> [URL] {
        let excluded = Set([
            "com.apple.finder",
            "com.apple.Terminal",
            "com.googlecode.iterm2",
        ])

        var result: [URL] = []
        var seen = Set<String>()

        func add(_ url: URL) {
            guard !seen.contains(url.path) else { return }
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
            guard !excluded.contains(id) else { return }
            seen.insert(url.path)
            result.append(url)
        }

        // LaunchServices：声明可「编辑」文件夹类型的应用
        for type in ["public.folder", "public.directory"] {
            if let handlers = LSCopyAllRoleHandlersForContentType(type as CFString, .editor)?.takeRetainedValue() as? [String] {
                for handler in handlers {
                    if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: handler) {
                        add(appURL)
                    }
                }
            }
        }

        // 常用开发工具兜底（即便未声明文件夹类型也列出）
        let knownDevApps = [
            "/Applications/Visual Studio Code.app",
            "/Applications/Cursor.app",
            "/Applications/Windsurf.app",
            "/Applications/Sublime Text.app",
            "/Applications/IntelliJ IDEA.app",
            "/Applications/PyCharm.app",
            "/Applications/WebStorm.app",
            "/Applications/PhpStorm.app",
            "/Applications/CLion.app",
            "/Applications/GoLand.app",
            "/Applications/RubyMine.app",
            "/Applications/TextMate.app",
            "/Applications/BBEdit.app",
            "/Applications/Nova.app",
            "/Applications/Zed.app",
            "/Applications/Fleet.app",
            "/Applications/Atom.app",
        ]
        for path in knownDevApps where FileManager.default.fileExists(atPath: path) {
            add(URL(fileURLWithPath: path))
        }
        return result
    }

    static func appName(_ url: URL) -> String {
        let bundle = Bundle(url: url)
        return (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }

    static func openWith(app: URL, urls: [URL]) {
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: 打开方式缓存（按扩展名组合缓存，后台枚举 + 图标加载）

    static var openableAppsCache: [String: [AppInfo]] = [:]
    /// 已枚举完成的 key —— 包含「结果为空」的情况。
    /// 必须与 openableAppsCache 分开记录，否则空结果会被误判成「尚未加载」而反复枚举。
    private static var appsLoaded = Set<String>()
    private static var appsLoading = Set<String>()
    /// 同一 key 的并发请求合并到同一批等待者，完成后在主线程统一回调。
    private static var appsWaiters: [String: [() -> Void]] = [:]

    static func appsKey(for urls: [URL]) -> String {
        urls.map { $0.pathExtension.lowercased() }.sorted().joined(separator: "|")
    }

    /// 是否已完成过枚举（含空结果）。
    static func isOpenableAppsLoaded(for urls: [URL]) -> Bool {
        appsLoaded.contains(appsKey(for: urls))
    }

    /// 后台枚举可打开的应用。`completion` 一律在主线程执行：命中缓存或等待中的请求都会回调，
    /// 这样调用方（子菜单）能在加载完成后回填自己，而不是停留在「加载中…」。
    static func loadOpenableApps(for urls: [URL], completion: (() -> Void)? = nil) {
        let key = appsKey(for: urls)

        if appsLoaded.contains(key) {
            if let completion { DispatchQueue.main.async(execute: completion) }
            return
        }

        if appsLoading.contains(key) {          // 已有同 key 枚举在跑：挂上去，不重复枚举
            if let completion { appsWaiters[key, default: []].append(completion) }
            return
        }

        appsLoading.insert(key)
        if let completion { appsWaiters[key] = [completion] }
        let captured = urls
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let apps = openableApplications(for: captured)
            let elapsed = Date().timeIntervalSince(started) * 1000
            DispatchQueue.main.async {
                openableAppsCache[key] = apps
                appsLoaded.insert(key)
                appsLoading.remove(key)
                SLog.log(String(format: "「打开方式」枚举完成: %d 个 App，耗时 %.1f ms（key=%@）",
                                apps.count, elapsed, key.isEmpty ? "(文件夹)" : key))
                for waiter in appsWaiters.removeValue(forKey: key) ?? [] { waiter() }
            }
        }
    }

    static func chooseOtherApp(_ urls: [URL]) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "选择一个应用来打开所选文件"
        panel.prompt = "打开"
        panel.begin { response in
            if response == .OK, let app = panel.url {
                openWith(app: app, urls: urls)
            }
        }
    }

    // MARK: - 复制路径 / 文件名

    static func copyPaths(_ urls: [URL], fallbackDir: URL? = nil) {
        let text: String
        if urls.isEmpty {
            text = fallbackDir?.path ?? ""     // 空白处右键 → 复制当前目录路径
        } else {
            text = urls.map(\.path).joined(separator: "\n")
        }
        writeToPasteboard(text)
    }

    static func copyFileNames(_ urls: [URL]) {
        let text = urls.map(\.lastPathComponent).joined(separator: "\n")
        writeToPasteboard(text)
    }

    private static func writeToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - 剪贴板（拷贝/剪切/粘贴文件）

    private static let cutFlagType = NSPasteboard.PasteboardType("com.superrightclick.cut")

    static func copyFiles(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        pb.setString("0", forType: cutFlagType)
    }

    static func cutFiles(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        pb.setString("1", forType: cutFlagType)
    }

    static func pasteboardHasFileURLs() -> Bool {
        let objects = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
        return (objects?.isEmpty == false)
    }

    static func pasteFiles(to dir: URL?) {
        guard let target = dir ?? FinderBridge.frontWindowTargetDirectory() else { return }
        let pb = NSPasteboard.general
        let isCut = pb.string(forType: cutFlagType) == "1"
        guard let objects = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !objects.isEmpty else { return }

        let fm = FileManager.default
        for src in objects {
            let dest = target.appendingPathComponent(src.lastPathComponent)
            do {
                if isCut {
                    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                    do {
                        try fm.moveItem(at: src, to: dest)
                    } catch {
                        // 跨卷移动失败时回退为 拷贝 + 删除
                        try fm.copyItem(at: src, to: dest)
                        try fm.removeItem(at: src)
                    }
                } else {
                    try fm.copyItem(at: src, to: dest)
                }
            } catch {
                log("粘贴失败 \(src.lastPathComponent): \(error)")
            }
        }
        if isCut { pb.clearContents() }
    }

    // MARK: - 发送到（NSSharingService：AirDrop / 邮件 / 备忘录 / 信息 …）

    static var sharingCache: [String: [NSSharingService]] = [:]
    /// 同 openableAppsCache：完成标记与结果分开，空结果也算「已加载」。
    private static var sharingLoaded = Set<String>()
    private static var sharingLoading = Set<String>()
    private static var sharingWaiters: [String: [() -> Void]] = [:]

    static func sharingServices(for urls: [URL]) -> [NSSharingService] {
        NSSharingService.sharingServices(forItems: urls)
    }

    static func isSharingServicesLoaded(for urls: [URL]) -> Bool {
        sharingLoaded.contains(appsKey(for: urls))
    }

    static func loadSharingServices(for urls: [URL], completion: (() -> Void)? = nil) {
        let key = appsKey(for: urls)

        if sharingLoaded.contains(key) {
            if let completion { DispatchQueue.main.async(execute: completion) }
            return
        }

        if sharingLoading.contains(key) {
            if let completion { sharingWaiters[key, default: []].append(completion) }
            return
        }

        sharingLoading.insert(key)
        if let completion { sharingWaiters[key] = [completion] }
        let captured = urls
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let services = NSSharingService.sharingServices(forItems: captured)
            let elapsed = Date().timeIntervalSince(started) * 1000
            DispatchQueue.main.async {
                sharingCache[key] = services
                sharingLoaded.insert(key)
                sharingLoading.remove(key)
                SLog.log(String(format: "「共享」枚举完成: %d 项服务，耗时 %.1f ms", services.count, elapsed))
                for waiter in sharingWaiters.removeValue(forKey: key) ?? [] { waiter() }
            }
        }
    }

    // MARK: - 压缩 / 解压

    static func isArchive(_ url: URL) -> Bool {
        ["zip", "tar", "gz", "tgz", "bz2", "xz"].contains(url.pathExtension.lowercased())
    }

    static func compress(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let parent = first.deletingLastPathComponent()
        let outName = urls.count == 1 ? "\(first.lastPathComponent).zip" : "归档.zip"
        let outPath = parent.appendingPathComponent(outName).path

        var args = ["-c", "-k", "--sequesterRsrc", "--keepParent"]
        args += urls.map(\.path)
        args.append(outPath)
        let result = Shell.run("/usr/bin/ditto", args)
        if result.status != 0 { log("压缩失败: \(result.stderr)") }
    }

    static func decompress(_ url: URL) {
        let destDir = url.deletingLastPathComponent()
        let result = Shell.run("/usr/bin/ditto", ["-x", "-k", url.path, destDir.path])
        if result.status != 0 { log("解压失败: \(result.stderr)") }
    }

    // MARK: - 终端打开

    static func openInTerminal(_ dir: URL?) {
        guard let dir = dir ?? FinderBridge.frontWindowTargetDirectory() else { return }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([dir], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    static func iTermExists() -> Bool {
        FileManager.default.fileExists(atPath: "/Applications/iTerm.app")
    }

    static func openInITerm(_ dir: URL?) {
        guard let dir = dir ?? FinderBridge.frontWindowTargetDirectory() else { return }
        let iterm = URL(fileURLWithPath: "/Applications/iTerm.app")
        NSWorkspace.shared.open([dir], withApplicationAt: iterm, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - 隐藏 / 显示

    static func firstIsHidden(_ urls: [URL]) -> Bool {
        guard let first = urls.first else { return false }
        return (try? first.resourceValues(forKeys: [.isHiddenKey]).isHidden) ?? false
    }

    static func toggleHidden(_ urls: [URL]) {
        let hide = !firstIsHidden(urls)
        for url in urls {
            Shell.run("/usr/bin/chflags", [hide ? "hidden" : "nohidden", url.path])
        }
    }

    static func showAllFilesEnabled() -> Bool {
        let result = Shell.run("/usr/bin/defaults", ["read", "com.apple.finder", "AppleShowAllFiles"])
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// 缓存版：启动时预热，避免每次右键弹菜单时 fork 子进程查询。
    private static var showAllFilesCache: Bool?

    static func refreshCachedState() {
        showAllFilesCache = showAllFilesEnabled()
    }

    static func showAllFilesEnabledCached() -> Bool {
        if let cached = showAllFilesCache { return cached }
        let value = showAllFilesEnabled()
        showAllFilesCache = value
        return value
    }

    static func toggleShowAllFiles() {
        let enable = !showAllFilesEnabled()
        Shell.run("/usr/bin/defaults", ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", enable ? "true" : "false"])
        Shell.run("/usr/bin/killall", ["Finder"])
        showAllFilesCache = enable
    }

    // MARK: - 删除

    static func trash(_ urls: [URL]) {
        for url in urls {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            catch { log("移入废纸篓失败 \(url.lastPathComponent): \(error)") }
        }
    }

    static func deleteDirectly(_ urls: [URL]) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "确定要立即删除这些项目吗？"
        alert.informativeText = "此操作不可撤销。\n\n" + urls.map(\.lastPathComponent).joined(separator: "\n")
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            for url in urls {
                do { try FileManager.default.removeItem(at: url) }
                catch { log("删除失败 \(url.lastPathComponent): \(error)") }
            }
        }
    }

    // MARK: - 打开 / 快速预览 / 重命名 / 替身 / 简介

    static func openDefault(_ urls: [URL]) {
        for url in urls {
            NSWorkspace.shared.open(url)
        }
    }

    static func quickLook(_ url: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Shell.run("/usr/bin/qlmanage", ["-p", url.path])
        }
    }

    static func rename(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "重命名"
        alert.informativeText = "为「\(url.lastPathComponent)」输入新名称："
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = url.lastPathComponent
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != url.lastPathComponent, !newName.contains("/") else { return }
        let dest = url.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: url, to: dest)
        } catch {
            log("重命名失败: \(error)")
        }
    }

    static func makeAlias(_ url: URL) {
        let escaped = url.path.appleScriptEscaped
        let src = """
        tell application "Finder"
            set f to POSIX file \(escaped) as alias
            set c to container of f
            make alias file to f at c
        end tell
        """
        FinderBridge.runAppleScriptAsync(src)
    }

    static func showInfo(_ url: URL) {
        let escaped = url.path.appleScriptEscaped
        FinderBridge.runAppleScriptAsync("tell application \"Finder\" to open information window of (POSIX file \(escaped))")
    }

    // MARK: - 系统菜单复刻（复制副本 / 标签 / 桌面整理 / 堆栈 / 排序 / 显示选项 / 壁纸）

    /// 复制（副本，等价 Finder 的 Cmd+D）
    static func duplicate(_ urls: [URL]) {
        for url in urls {
            let escaped = url.path.appleScriptEscaped
            FinderBridge.runAppleScriptAsync("tell application \"Finder\" to duplicate (POSIX file \(escaped))")
        }
    }

    /// 设置颜色标签（0=无，1-7=红橙黄绿蓝紫灰）
    static func setLabel(_ url: URL, index: Int) {
        let escaped = url.path.appleScriptEscaped
        FinderBridge.runAppleScriptAsync("tell application \"Finder\" to set label index of (POSIX file \(escaped)) to \(index)")
    }

    static func labelColorImage(_ index: Int) -> NSImage? {
        if index == 0 {
            return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                NSColor.tertiaryLabelColor.setStroke()
                let path = NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5))
                path.lineWidth = 1.5
                path.stroke()
                return true
            }
        }
        let colors: [NSColor] = [.clear, .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .systemGray]
        guard index >= 0, index < colors.count else { return nil }
        return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            colors[index].setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }

    // 界面语言相关（Finder 菜单项名称随系统语言变化）
    private static var zhUI: Bool { (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") }
    private static var viewMenuTitle: String { zhUI ? "显示" : "View" }
    static var cleanUpTitle: String { zhUI ? "整理" : "Clean Up" }
    static var stacksTitle: String { zhUI ? "使用堆栈" : "Use Stacks" }
    static var sortByMenuTitle: String { zhUI ? "排序方式" : "Sort By" }

    static func sortOptions() -> [(String, String)] {
        zhUI
            ? [("名称", "名称"), ("种类", "种类"), ("修改日期", "修改日期"), ("大小", "大小")]
            : [("Name", "Name"), ("Kind", "Kind"), ("Date Modified", "Date Modified"), ("Size", "Size")]
    }

    /// 整理（Finder「显示」菜单，桌面/当前窗口）
    static func cleanUp() {
        clickViewMenuItem(cleanUpTitle)
    }

    /// 使用堆栈（桌面）
    static func toggleStacks() {
        clickViewMenuItem(stacksTitle)
    }

    /// 排序方式（Finder「显示」菜单子项）
    static func arrangeBy(_ option: String) {
        let src = """
        tell application "System Events"
            tell process "Finder"
                click menu item "\(option)" of menu 1 of menu item "\(sortByMenuTitle)" of menu "\(viewMenuTitle)" of menu bar 1
            end tell
        end tell
        """
        FinderBridge.runAppleScriptAsync(src)
    }

    private static func clickViewMenuItem(_ name: String) {
        let src = """
        tell application "System Events"
            tell process "Finder"
                click menu item "\(name)" of menu "\(viewMenuTitle)" of menu bar 1
            end tell
        end tell
        """
        FinderBridge.runAppleScriptAsync(src)
    }

    /// 查看显示选项（Cmd+J，语言无关的固定快捷键）
    static func showViewOptions() {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 38, keyDown: true)   // J
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 38, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// 更改桌面背景（打开系统壁纸设置）
    static func openWallpaperSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 通用

    private static func log(_ message: String) {
        NSLog("[SuperRightClick] %@", message)
    }
}
