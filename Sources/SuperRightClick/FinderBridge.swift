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
