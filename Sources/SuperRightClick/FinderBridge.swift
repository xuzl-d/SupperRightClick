import AppKit
import ApplicationServices

/// 通过 AppleScript 与 Finder 交互，获取选中项、当前窗口目标目录等。
/// 脚本预编译 + 串行队列执行（NSAppleScript 非线程安全），并提供预取缓存。
enum FinderBridge {

    // MARK: - 预编译脚本（避免每次调用重新编译的开销）

    private static let scriptQueue = DispatchQueue(label: "com.superrightclick.applescript")

    private static let selectionScript = NSAppleScript(source: """
        tell application "Finder"
            set out to {}
            repeat with theItem in (get selection)
                set end of out to (POSIX path of (theItem as alias))
            end repeat
            return out
        end tell
        """)

    private static let frontWindowScript = NSAppleScript(source: """
        tell application "Finder"
            if (count of windows) > 0 then
                return POSIX path of (target of front window as alias)
            else
                return POSIX path of (path to desktop folder)
            end if
        end tell
        """)

    private static func run(_ script: NSAppleScript?) -> NSAppleEventDescriptor? {
        guard let script else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error = error {
            SLog.log("AppleScript 错误: \(error)")
        }
        return result
    }

    private static func parsePathList(_ desc: NSAppleEventDescriptor?) -> [URL] {
        guard let desc else { return [] }
        var urls: [URL] = []
        let count = desc.numberOfItems
        guard count > 0 else { return [] }
        for i in 1...count {
            if let path = desc.atIndex(i)?.stringValue, !path.isEmpty {
                urls.append(URL(fileURLWithPath: path))
            }
        }
        return urls
    }

    // MARK: - 选中项（按「这一次右键」预取）

    private static var cachedSelection: [URL] = []
    /// 缓存结果对应的「右键 token」。只有 token 相同才算数 ——
    /// 不能用「N 秒内的结果都算新鲜」的 TTL：那样右键文件后再右键空白处，
    /// 只要间隔够短就会拿上一次的选中项去建菜单，于是又弹出长菜单。
    private static var cachedSelectionToken: UUID?

    /// 同步获取选中项（主线程；仅作为预取未就绪时的兜底）。
    static func selection() -> [URL] {
        scriptQueue.sync { parsePathList(run(selectionScript)) }
    }

    /// 带超时的同步兜底：AppleScript 若被系统授权弹窗或卡住的访达拖住，
    /// 这里最多等 `timeout` 秒就放弃（返回空选中），避免右键后菜单永远不出现。
    /// 注意：绝不能在这里无上限等待 —— 菜单是在主线程上构建的。
    static func selectionWithTimeout(_ timeout: TimeInterval = 1.0) -> [URL] {
        let semaphore = DispatchSemaphore(value: 0)
        // 用类引用传递结果，避免在闭包外读取未同步的变量。
        final class Box: @unchecked Sendable { var value: [URL] = [] }
        let box = Box()

        scriptQueue.async {
            box.value = parsePathList(run(selectionScript))
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            SLog.log("⚠️ 读取访达选中项超时（\(timeout)s）：先用空选中弹菜单，避免菜单不出现")
            return []
        }
        return box.value
    }

    /// 右键按下时调用：为「这一次右键」开一次后台预取，并返回它的 token。
    /// 延迟 60 ms 是为了让 Finder 先处理完我们合成的左键，否则读到的还是旧选中项。
    @discardableResult
    static func beginSelectionPrefetch() -> UUID {
        let token = UUID()
        scriptQueue.asyncAfter(deadline: .now() + 0.06) {
            let urls = parsePathList(run(selectionScript))
            DispatchQueue.main.async {
                cachedSelection = urls
                cachedSelectionToken = token
            }
        }
        return token
    }

    /// 取「本次右键」的预取结果。不是本次的就返回 nil，
    /// 由调用方走带超时的同步兜底 —— 宁可贵一点，也不能拿陈旧选中项建菜单。
    static func selectionForCurrentClick(token: UUID?) -> [URL]? {
        guard let token, cachedSelectionToken == token else { return nil }
        return cachedSelection
    }

    // MARK: - 前台窗口目标目录（按「这一次右键」快照）

    private static var cachedFrontDir: URL?
    /// 缓存对应的「右键 token」。**不能用时间窗口（TTL）**：那会让「刚在废纸篓窗口剪切、
    /// 2 秒后到文稿窗口粘贴」这种操作拿到上一次的 .Trash 作为目标目录 ——
    /// 于是粘贴被判定成「贴回原目录」而静默跳过（用户看到"粘贴失败"）。
    private static var cachedFrontDirToken: UUID?

    private static func readFrontWindowDirectory() -> URL? {
        guard let desc = run(frontWindowScript), let path = desc.stringValue, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// 同步读取前台窗口目录（不带缓存）。仅用于没有本次快照时的兜底，
    /// 以及新建文件 / 终端打开等少量调用点。
    static func frontWindowTargetDirectory() -> URL? {
        let url: URL? = scriptQueue.sync { readFrontWindowDirectory() }
        cachedFrontDir = url
        cachedFrontDirToken = nil    // 同步读到的结果不绑定任何 token
        return url
    }

    /// 右键按下时调用：为「这一次右键」开一次后台预取，返回 token。
    @discardableResult
    static func beginFrontDirPrefetch() -> UUID {
        let token = UUID()
        scriptQueue.asyncAfter(deadline: .now() + 0.06) {
            let url = readFrontWindowDirectory()
            DispatchQueue.main.async {
                cachedFrontDir = url
                cachedFrontDirToken = token
            }
        }
        return token
    }

    /// 取「本次右键」的前台窗口目录；不是本次的就返回 nil，
    /// 由调用方走带超时的同步兜底 —— 宁可贵一点，也不能用上一次的快照当目标。
    static func frontDirForCurrentClick(token: UUID?) -> URL? {
        guard let token, cachedFrontDirToken == token else { return nil }
        return cachedFrontDir
    }

    /// 带超时的同步兜底（菜单在主线程上构建，不能无限等待）。
    static func frontWindowTargetDirectoryWithTimeout(_ timeout: TimeInterval = 1.0) -> URL? {
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var value: URL? }
        let box = Box()
        scriptQueue.async {
            box.value = readFrontWindowDirectory()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            SLog.log("⚠️ 读取访达窗口目录超时（\(timeout)s）")
            return nil
        }
        return box.value
    }

    // MARK: - 访达侧边栏项目 → 真实目录

    /// 右键落在访达**侧边栏项目**（文稿 / 下载 / 桌面 …）上时，解析该项目对应的文件夹。
    ///
    /// 为什么必须单独处理：右键侧边栏时 AppleScript 的 `selection` 是空的，目标目录会退化成
    /// 「**最前面窗口**的目录」——而那一刻最前面的可能还是上一个窗口（例如刚从废纸篓过来），
    /// 于是粘贴目标被算成废纸篓，命中「剪切贴回原目录」→ 静默跳过 → 用户看到"粘贴失败"。
    ///
    /// 实现：辅助功能命中光标下的元素 → 向上找到侧边栏行 → 读行内文字（`AXStaticText` 的
    /// `AXValue`，注意侧边栏行的 `AXTitle` 是空的）→ 按「显示名 → 路径」映射出真实目录。
    /// 虚拟项（最近使用 / 隔空投送 / 网络 / 位置…）解析不到，返回 nil 由调用方退回原逻辑。
    static func sidebarFolder(at point: CGPoint) -> URL? {
        guard let element = EventTapManager.shared.axElement(at: point) else { return nil }

        // 向上找行（命中点可能是行内的文字或图标）
        guard let row = rowElement(at: element) else { return nil }
        guard isInsideSidebar(row) else { return nil }

        guard let label = firstStaticTextValue(in: row), !label.isEmpty else { return nil }
        guard let folder = folder(matchingDisplayName: label) else {
            SLog.log("侧边栏项目「\(label)」无法解析为目录，退回原目标目录逻辑")
            return nil
        }
        SLog.log("右键目标是侧边栏项目「\(label)」→ \(folder.path)")
        return folder
    }

    /// 光标下的访达条目是否**已经是选中状态**。
    /// 返回 nil 表示无法判定（不是访达条目 / 辅助功能取不到）→ 调用方按原逻辑处理。
    ///
    /// 为什么要判断：条目已经选中时，我们**根本不需要**再合成左键。而多合成一次左键在访达里有三个副作用：
    ///   1) 落点在文件名上 → 直接进入 **重命名**（访达既有行为：单击已选中条目的名字即改名）；
    ///   2) 多选状态下 → 把选择**塌缩**成这一个，右键菜单内容随之出错；
    ///   3) 落在系统双击间隔内 → 被判成双击而**打开文件**。
    static func isFinderItemAlreadySelected(at point: CGPoint) -> Bool? {
        guard let element = EventTapManager.shared.axElement(at: point) else { return nil }
        return isFinderItemAlreadySelected(element: element)
    }

    /// 判定核心（与屏幕坐标解耦，便于测试）：从命中元素向上找**最近一个带 AXSelected 的元素**。
    ///
    /// 不能只认某一种视图的节点：
    ///   · 列表视图：条目是 AXRow / AXOutlineRow
    ///   · 图标视图：条目是 AXGroup（内含带文件名的 AXImage，两者都带 AXSelected）
    /// 从"光标命中的叶子元素"向上找，第一个带 AXSelected 的即条目本身；
    /// 容器（AXList / AXSectionList）虽然也有该属性，但在更上层，不会先被取到。
    static func isFinderItemAlreadySelected(element: AXUIElement) -> Bool? {
        var current: AXUIElement? = element
        for _ in 0..<6 {
            guard let el = current else { return nil }
            // 不越过窗口/应用边界：实测 **AXApplication 竟然也带 AXSelected=false**，
            // 链浅时会一路爬到它，把"无法判定"错判成"未选中"。
            let role = axString(el, kAXRoleAttribute)
            if role == "AXWindow" || role == "AXApplication" { return nil }
            if let value = axAttribute(el, kAXSelectedAttribute) {
                // 侧边栏条目也带 AXSelected，但它不是"待选文件"，不参与判定
                if isInsideSidebar(el) { return nil }
                return (value as? NSNumber)?.boolValue ?? (value as? Bool)
            }
            current = axElementValue(axAttribute(el, kAXParentAttribute))
        }
        return nil
    }

    /// 光标下是否是「条目文件名文本框」——列表/分栏视图里访达把文件名暴露成可编辑的
    /// `AXTextField`（这正是「单击已选中条目的名字 = 重命名」的由来）。返回该元素。
    static func nameTextField(at point: CGPoint) -> AXUIElement? {
        guard let element = EventTapManager.shared.axElement(at: point) else { return nil }
        var current: AXUIElement? = element
        for _ in 0..<4 {
            guard let el = current else { return nil }
            if axString(el, kAXRoleAttribute) == "AXTextField" { return el }
            current = axElementValue(axAttribute(el, kAXParentAttribute))
        }
        return nil
    }

    /// 取元素 / 其父元素的 frame（辅助功能坐标，原点左上，与 CG 一致）。
    static func frame(of element: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let positionRef = axAttribute(element, kAXPositionAttribute),
              let sizeRef = axAttribute(element, kAXSizeAttribute),
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID(),
              AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func frameOfParent(of element: AXUIElement) -> CGRect? {
        guard let parent = axElementValue(axAttribute(element, kAXParentAttribute)) else { return nil }
        return frame(of: parent)
    }

    /// 从命中元素向上找到所在的行（列表视图/侧边栏用；命中点通常是行内的文字或图标）。
    private static func rowElement(at element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<6 {
            guard let el = current else { return nil }
            if axString(el, kAXRoleAttribute) == "AXRow" { return el }
            current = axElementValue(axAttribute(el, kAXParentAttribute))
        }
        return nil
    }

    /// 该元素是否位于访达侧边栏子树内（祖先里有描述为「边栏」/Sidebar 的 AXOutline）。
    /// 侧边栏条目同样带 AXSelected / 也是 AXRow，必须与内容区的文件条目区分开。
    private static func isInsideSidebar(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<6 {
            guard let el = current else { return false }
            if axString(el, kAXRoleAttribute) == "AXOutline" {
                let desc = axString(el, kAXDescriptionAttribute).lowercased()
                if desc.contains("边栏") || desc.contains("sidebar") { return true }
            }
            current = axElementValue(axAttribute(el, kAXParentAttribute))
        }
        return false
    }

    private static func axAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func axString(_ element: AXUIElement, _ name: String) -> String {
        (axAttribute(element, name) as? String) ?? ""
    }

    /// CFTypeRef → AXUIElement（带类型校验，避免误转崩溃）。
    private static func axElementValue(_ ref: CFTypeRef?) -> AXUIElement? {
        guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    /// 取元素子树里第一段非空文字（侧边栏项目的名称在 AXStaticText 的 AXValue 里）。
    private static func firstStaticTextValue(in element: AXUIElement, depth: Int = 0) -> String? {
        if depth > 3 { return nil }
        if axString(element, kAXRoleAttribute) == "AXStaticText" {
            let value = axString(element, kAXValueAttribute)
            if !value.isEmpty { return value }
        }
        for child in (axAttribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            if let found = firstStaticTextValue(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    /// 侧边栏显示名 → 真实目录。用系统本地化显示名比对（`displayName(atPath:)` 在中文系统
    /// 侧边栏项目名 → 标准用户目录（中英文都认）。
    ///
    /// 为什么要硬编码别名：侧边栏行**没有任何语言无关的标识**（实测：无 AXURL、无 identifier、
    /// AXTitle 为空，文字只在 `AXStaticText` 的 `AXValue` 里），而名字是 Finder 按系统语言
    /// 本地化的；本 App 的 Info.plist 未声明中文本地化，`displayName(atPath:)` 很可能返回
    /// 英文名，因此不能只靠 displayName 比对。
    private static let sidebarFolderAliases: [String: String] = [
        "Desktop": "Desktop", "桌面": "Desktop",
        "Documents": "Documents", "文稿": "Documents", "文档": "Documents",
        "Downloads": "Downloads", "下载": "Downloads", "下载项": "Downloads",
        "Pictures": "Pictures", "图片": "Pictures", "图像": "Pictures",
        "Music": "Music", "音乐": "Music",
        "Movies": "Movies", "影片": "Movies", "视频": "Movies",
        "Public": "Public", "公共": "Public", "公用": "Public",
    ]

    /// 侧边栏显示名 → 真实目录。虚拟项（最近使用 / 隔空投送 / 网络 / 位置…）返回 nil。
    static func folder(matchingDisplayName label: String) -> URL? {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())

        if let name = sidebarFolderAliases[label] {
            let url = home.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url }
        }
        if ["Applications", "应用程序", "應用程式"].contains(label) {
            return URL(fileURLWithPath: "/Applications")
        }
        if ["Trash", "废纸篓", "垃圾桶"].contains(label) {
            return home.appendingPathComponent(".Trash")
        }
        if label == NSUserName() { return home }

        // 磁盘卷：卷名本身不本地化，可直接比对
        for volume in fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [] {
            if (fm.displayName(atPath: volume.path) ?? volume.lastPathComponent) == label { return volume }
        }
        if (fm.displayName(atPath: "/") ?? "/") == label { return URL(fileURLWithPath: "/") }
        return nil
    }

    // MARK: - 其它

    static func reveal(_ url: URL) {
        let escaped = url.path.appleScriptEscaped
        let src = "tell application \"Finder\"\nreveal (POSIX file \(escaped))\nactivate\nend tell"
        scriptQueue.async { _ = run(NSAppleScript(source: src)) }
    }

    static func runAppleScript(_ source: String) -> NSAppleEventDescriptor? {
        scriptQueue.sync { run(NSAppleScript(source: source)) }
    }

    /// 异步执行 AppleScript（不阻塞主线程）。
    static func runAppleScriptAsync(_ source: String) {
        scriptQueue.async { _ = run(NSAppleScript(source: source)) }
    }

    /// 桌面文件夹（唯一入口，避免各处各写一份）。
    static func desktopDirectory() -> URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    }
}

extension String {
    /// 转义为 AppleScript 字符串字面量（双引号）。
    var appleScriptEscaped: String {
        let escaped = self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
