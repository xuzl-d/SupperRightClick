import AppKit

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

    // MARK: - 选中项（预取缓存）

    private static var cachedSelection: [URL] = []
    private static var cachedSelectionAt: Date = .distantPast
    private static var prefetchInFlight = false

    /// 同步获取选中项（主线程；仅作为预取未就绪时的兜底）。
    static func selection() -> [URL] {
        scriptQueue.sync { parsePathList(run(selectionScript)) }
    }

    /// 后台预取选中项（右键按下时调用；弹菜单时直接用缓存）。
    static func prefetchSelection() {
        if prefetchInFlight { return }
        prefetchInFlight = true
        scriptQueue.async {
            let urls = parsePathList(run(selectionScript))
            DispatchQueue.main.async {
                cachedSelection = urls
                cachedSelectionAt = Date()
                prefetchInFlight = false
            }
        }
    }

    /// 2 秒内的预取结果视为新鲜。
    static func selectionCached() -> [URL]? {
        Date().timeIntervalSince(cachedSelectionAt) < 2.0 ? cachedSelection : nil
    }

    // MARK: - 前台窗口目标目录（TTL 缓存）

    private static var cachedFrontDir: URL?
    private static var cachedFrontDirAt: Date = .distantPast

    static func frontWindowTargetDirectory() -> URL? {
        if Date().timeIntervalSince(cachedFrontDirAt) < 5.0, let cached = cachedFrontDir {
            return cached
        }
        let url: URL? = scriptQueue.sync {
            guard let desc = run(frontWindowScript), let path = desc.stringValue, !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        }
        cachedFrontDir = url
        cachedFrontDirAt = Date()
        return url
    }

    /// 后台预热前台窗口目录缓存。
    static func prefetchFrontWindowDir() {
        scriptQueue.async {
            let url: URL? = {
                guard let desc = run(frontWindowScript), let path = desc.stringValue, !path.isEmpty else { return nil }
                return URL(fileURLWithPath: path)
            }()
            DispatchQueue.main.async {
                cachedFrontDir = url
                cachedFrontDirAt = Date()
            }
        }
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
