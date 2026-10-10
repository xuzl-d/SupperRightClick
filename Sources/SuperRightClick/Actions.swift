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

        // 1) 常规：系统按文件类型枚举可打开的应用。
        //    多选时按扩展名去重：LaunchServices 查询是按类型（UTI）来的，
        //    对每个文件各查一次纯属浪费（实测 60 个同扩展名文件 12.0 ms → 0.2 ms）。
        //    注意：扩展名各不相同的大批多选收益有限（20 个不同扩展名 7.3 ms → 2.7 ms），
        //    那种情况下的开销主要来自并集 App 的图标/名称加载。
        var queried = Set<String>()
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard queried.insert(ext).inserted else { continue }
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

    // MARK: 打开方式缓存（按扩展名组合缓存）

    static var openableAppsCache: [String: [AppInfo]] = [:]
    /// 已枚举完成的 key —— 包含「结果为空」的情况。
    /// 必须与 openableAppsCache 分开记录，否则空结果会被误判成「尚未加载」而反复枚举。
    private static var appsLoaded = Set<String>()
    private static var appsWarming = Set<String>()
    private static var appsBuiltAt: [String: Date] = [:]

    /// **内容型缓存**的保鲜期。
    ///
    /// 这里用「时间」判断是**合适**的：缓存内容取决于系统里装了什么 App / 有哪些共享服务，
    /// 与「用户这一次操作」无关，只是变化很慢。用时间做粗粒度失效即可。
    ///
    /// ⚠️ 与「选中项 / 前台窗口目录」严格区分：那两个是**交互态**，必须绑定到具体这次右键
    /// （token）。用时间窗口去判断它们是不是"新鲜"，正是之前两个 bug 的根源。
    private static let contentCacheTTL: TimeInterval = 10 * 60

    static func appsKey(for urls: [URL]) -> String {
        urls.map { $0.pathExtension.lowercased() }.sorted().joined(separator: "|")
    }

    /// 是否已完成过枚举（含空结果）。超过保鲜期视为未加载，会重新枚举。
    static func isOpenableAppsLoaded(for urls: [URL]) -> Bool {
        let key = appsKey(for: urls)
        guard appsLoaded.contains(key) else { return false }
        guard let builtAt = appsBuiltAt[key] else { return true }
        return Date().timeIntervalSince(builtAt) < contentCacheTTL
    }

    /// 取「可打开这些文件的应用」：缓存优先（超过保鲜期则重算），未命中就**同步**枚举。
    ///
    /// 为什么必须同步：子菜单内容是在 `menuNeedsUpdate` 里填的，而那一刻主线程正卡在
    /// `NSMenu.popUp` 的跟踪循环中。真实使用日志显示，后台枚举 44 ms 就跑完了，但
    /// 「枚举完成 → 回填子菜单」这段要等菜单关闭之后才执行，界面于是永远停在「加载中…」。
    /// 枚举本身只要 30~90 ms，同步做完远比比绕一层异步（还要赌回填时机）更可靠。
    static func openableAppsSync(for urls: [URL]) -> [AppInfo] {
        let key = appsKey(for: urls)
        if isOpenableAppsLoaded(for: urls) { return openableAppsCache[key] ?? [] }

        let started = Date()
        let apps = openableApplications(for: urls)
        openableAppsCache[key] = apps
        appsLoaded.insert(key)
        appsBuiltAt[key] = Date()
        SLog.log(String(format: "「打开方式」同步枚举: %d 个 App，耗时 %.1f ms（key=%@）",
                        apps.count, Date().timeIntervalSince(started) * 1000,
                        key.isEmpty ? "(文件夹)" : key))
        return apps
    }

    /// 预热用的常见类型（新建模板 + 常见文档/图片/媒体/压缩包）。
    private static let warmExtensions = [
        "txt", "md", "json", "csv", "rtf", "docx", "xlsx", "doc", "xls", "ppt", "pptx", "pdf",
        "png", "jpg", "jpeg", "gif", "heic", "webp", "svg",
        "mp4", "mov", "mp3", "zip", "rar", "7z", "html", "swift", "js", "py",
    ]

    /// 后台预热常见类型的枚举结果，让「首次右键」也直接命中缓存。
    /// 纯优化：预热失败或过期都无害，未命中时 `openableAppsSync` 会自己同步补上。
    /// 注意：`urlsForApplications(toOpen:)` 对不存在的路径返回空，所以必须落真实（空）文件。
    static func warmOpenableAppsCache() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("superrightclick-warm", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
                || FileManager.default.fileExists(atPath: dir.path) else { return }

        var samples: [URL] = [dir]                     // 文件夹（key 为空串）
        for ext in warmExtensions {
            let file = dir.appendingPathComponent("warm.\(ext)")
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: Data())
            }
            samples.append(file)
        }

        for url in samples {
            let key = appsKey(for: [url])
            // 已有未过期结果、或正在预热 → 跳过
            guard !isOpenableAppsLoaded(for: [url]), !appsWarming.contains(key) else { continue }
            appsWarming.insert(key)
            DispatchQueue.global(qos: .utility).async {
                let apps = openableApplications(for: [url])
                DispatchQueue.main.async {
                    if !self.isOpenableAppsLoaded(for: [url]) {   // 同步路径可能已先填好，别覆盖
                        openableAppsCache[key] = apps
                        appsLoaded.insert(key)
                        appsBuiltAt[key] = Date()
                    }
                    appsWarming.remove(key)
                }
            }
        }
        SLog.log("已启动「打开方式」缓存预热（\(samples.count) 种类型）")
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
        SLog.log("已拷贝 \(urls.count) 项到剪贴板：\(urls.map(\.lastPathComponent).joined(separator: "、"))")
    }

    static func cutFiles(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        pb.setString("1", forType: cutFlagType)
        SLog.log("已剪切 \(urls.count) 项到剪贴板：\(urls.map(\.lastPathComponent).joined(separator: "、"))")
    }

    static func pasteboardHasFileURLs() -> Bool {
        let objects = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
        return (objects?.isEmpty == false)
    }

    static func pasteFiles(to dir: URL?) {
        guard let target = dir ?? FinderBridge.frontWindowTargetDirectory() else {
            SLog.log("粘贴中止：无法确定目标目录（右键处既非文件夹、也读不到访达窗口目录）")
            return
        }
        let pb = NSPasteboard.general
        let isCut = pb.string(forType: cutFlagType) == "1"
        guard let objects = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !objects.isEmpty else {
            SLog.log("粘贴中止：剪贴板里没有文件（可能被「复制路径/复制文件名」或其它 App 的复制覆盖）")
            return
        }

        SLog.log("粘贴开始：目标=\(target.path) 剪切=\(isCut) 源 \(objects.count) 项")
        let fm = FileManager.default
        var skipped: [String] = []
        for src in objects {
            let dest = target.appendingPathComponent(src.lastPathComponent)
            let sameFile = src.standardizedFileURL.path == dest.standardizedFileURL.path

            // 剪切贴回原处：直接跳过，绝不执行「先删目标」这类会删掉源文件的操作。
            if isCut && sameFile {
                SLog.log("剪切贴回原目录，跳过：\(src.lastPathComponent)")
                skipped.append(src.lastPathComponent)
                continue
            }

            // 目标处已有同名文件（或复制贴回原处）→ 生成「保留两者」的唯一名字，
            // 绝不覆盖、绝不删除已有文件（原来的实现会先删目标再移动，一旦移动失败
            // 或目标就是源文件自身，就会把文件删没 —— 数据丢失）。
            var finalDest = dest
            if sameFile || fm.fileExists(atPath: dest.path) {
                finalDest = uniqueDestURL(for: src, in: target)
                SLog.log("目标已存在，改为「保留两者」：\(finalDest.lastPathComponent)")
            }

            do {
                if isCut {
                    do {
                        try fm.moveItem(at: src, to: finalDest)
                    } catch {
                        // 跨卷移动失败 → 回退为「拷贝 + 删源」。
                        // 只有拷贝完全成功后才删源；删源失败也不影响已拷贝的结果，且不丢数据。
                        try fm.copyItem(at: src, to: finalDest)
                        do {
                            try fm.removeItem(at: src)
                        } catch {
                            SLog.log("剪切已复制成功，但删除源文件失败（源保留，非数据丢失）: \(error)")
                        }
                    }
                } else {
                    try fm.copyItem(at: src, to: finalDest)
                }
            } catch {
                SLog.log("粘贴失败 \(src.lastPathComponent): \(error)")
            }
        }
        if isCut { pb.clearContents() }
        SLog.log("粘贴结束")

        // 静默跳过是「粘贴失败」错觉的来源：这里必须给用户明确反馈。
        if !skipped.isEmpty {
            let alert = NSAlert()
            alert.messageText = "未移动：文件已在目标文件夹「\(target.lastPathComponent)」里"
            alert.informativeText = """
                源文件本来就在这个文件夹中，所以没有做任何移动：
                \(skipped.prefix(10).joined(separator: "\n"))

                如果你本意是贴到别的文件夹，请先打开那个文件夹，在它的空白处右键再选「粘贴」。
                （直接右键侧边栏项目时，旧版会解析错目标目录 —— 新版已修正。）
                """
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// 生成「保留两者」的唯一目标路径（`名字 2.扩展`），绝不覆盖已有文件。
    private static func uniqueDestURL(for src: URL, in dir: URL) -> URL {
        let base = src.deletingPathExtension().lastPathComponent
        let ext = src.pathExtension
        return dir.appendingPathComponent(uniqueName(baseName: base, ext: ext, in: dir))
    }

    // MARK: - 发送到（NSSharingService：AirDrop / 邮件 / 备忘录 / 信息 …）

    static var sharingCache: [String: [NSSharingService]] = [:]
    /// 同 openableAppsCache：完成标记与结果分开，空结果也算「已加载」。
    private static var sharingLoaded = Set<String>()
    private static var sharingBuiltAt: [String: Date] = [:]

    static func sharingServices(for urls: [URL]) -> [NSSharingService] {
        NSSharingService.sharingServices(forItems: urls)
    }

    /// 是否已枚举过（含空结果）；超过内容保鲜期视为未加载，会重新枚举。
    static func isSharingServicesLoaded(for urls: [URL]) -> Bool {
        let key = appsKey(for: urls)
        guard sharingLoaded.contains(key) else { return false }
        guard let builtAt = sharingBuiltAt[key] else { return true }
        return Date().timeIntervalSince(builtAt) < contentCacheTTL
    }

    /// 取「可用的共享服务」：缓存优先（超过保鲜期则重算），未命中就同步枚举
    /// （理由同 `openableAppsSync`）。共享服务枚举较慢（实测约 90 ms），更不能赌异步回填。
    static func sharingServicesSync(for urls: [URL]) -> [NSSharingService] {
        let key = appsKey(for: urls)
        if isSharingServicesLoaded(for: urls) { return sharingCache[key] ?? [] }

        let started = Date()
        let services = NSSharingService.sharingServices(forItems: urls)
        sharingCache[key] = services
        sharingLoaded.insert(key)
        sharingBuiltAt[key] = Date()
        SLog.log(String(format: "「共享」同步枚举: %d 项服务，耗时 %.1f ms",
                        services.count, Date().timeIntervalSince(started) * 1000))
        return services
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

    // MARK: - 隐藏 / 取消隐藏

    static func firstIsHidden(_ urls: [URL]) -> Bool {
        guard let first = urls.first else { return false }
        return (try? first.resourceValues(forKeys: [.isHiddenKey]).isHidden) ?? false
    }

    static func setHidden(_ hidden: Bool, _ urls: [URL]) {
        for url in urls {
            Shell.run("/usr/bin/chflags", [hidden ? "hidden" : "nohidden", url.path])
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
        // 列表要限长：多选几百个文件时，把文件名全列进 informativeText 会把
        // 弹窗撑到超出屏幕，按钮被挤出可见区域（同诊断报告弹窗的那个坑）。
        let shown = urls.prefix(10).map(\.lastPathComponent).joined(separator: "\n")
        let more = urls.count > 10 ? "\n……等共 \(urls.count) 项" : ""
        alert.informativeText = "此操作不可撤销。\n\n" + shown + more
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

    /// 在新标签页中打开文件夹（等价访达「文件 → 在新标签页中打开」）。
    /// 访达的 AppleScript 没有「新标签页」这个动词，只能：
    /// 1. 激活访达 → 2. 发 ⌘T 开一个标签页 → 3. 把该标签页定位到目标文件夹。
    /// 若当前没有访达窗口（⌘T 无处可开），则退回「打开新窗口」。
    static func openInNewTab(_ url: URL) {
        let path = url.path
        FinderBridge.runAppleScriptAsync("tell application \"Finder\" to activate")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            postCommandT()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                let escaped = path.appleScriptEscaped
                FinderBridge.runAppleScriptAsync("""
                    tell application "Finder"
                        if (count of windows) > 0 then
                            set target of front window to (POSIX file \(escaped))
                        else
                            open (POSIX file \(escaped))
                        end if
                    end tell
                    """)
            }
        }
    }

    /// 向系统发送 ⌘T（用于访达开新标签页）。本 App 已有辅助功能，可正常投递键盘事件。
    private static func postCommandT() {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x11, keyDown: true)   // kVK_ANSI_T
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x11, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
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

    // MARK: - 系统菜单复刻（标签 / 桌面整理 / 堆栈 / 排序 / 显示选项 / 壁纸）

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
