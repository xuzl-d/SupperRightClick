import AppKit
import CoreGraphics

/// 截图（封装系统 `/usr/sbin/screencapture`）。
///
/// 权限说明：macOS 10.15 起，截图必须由已获「屏幕录制」权限的 App 发起，否则
/// 只能拍到桌面壁纸、拍不到任何窗口内容。所以这里先预检权限，再执行截图。
enum Screenshot {

    enum Mode {
        case region      // 拖框选区
        case window      // 点选窗口
        case screen      // 主显示器全屏
    }

    enum Destination {
        case file        // 存到当前文件夹，并在访达里选中
        case clipboard   // 只放进剪贴板
    }

    /// 是否已获「屏幕录制」权限。
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// 截图入口（由菜单动作调用）。
    /// 交互式模式会等用户画完选区，因此进程异步执行，不阻塞菜单。
    static func capture(_ mode: Mode, to destination: Destination, in directory: URL?) {
        guard ensurePermission() else { return }

        var args: [String] = []
        switch mode {
        case .region: args += ["-i", "-s"]              // 交互式，仅允许框选
        case .window: args += ["-i", "-w", "-o"]        // 交互式，仅允许选窗口，不含阴影
        case .screen: args += ["-m"]                    // 非交互，主显示器全屏
        }

        var output: URL?
        switch destination {
        case .file:
            let url = uniqueURL(in: directory ?? desktopDirectory())
            output = url
            args.append(url.path)
        case .clipboard:
            args.append("-c")
        }

        run(args: args, output: output)
    }

    // MARK: - 权限

    private static func ensurePermission() -> Bool {
        if hasPermission { return true }

        SLog.log("截图：尚无「屏幕录制」权限，先触发系统授权")
        if CGRequestScreenCaptureAccess() { return true }    // 在系统弹窗里直接授权成功

        let alert = NSAlert()
        alert.messageText = "截图需要「屏幕录制」权限"
        alert.informativeText = """
            请到「系统设置 → 隐私与安全性 → 屏幕录制」勾选「超级右键」，\
            然后退出并重新打开本 App 再试。

            未授权时截图只能拍到桌面壁纸，拍不到任何窗口内容。
            """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    // MARK: - 执行

    private static func run(args: [String], output: URL?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = args
        process.terminationHandler = { proc in
            let status = proc.terminationStatus

            // 只进剪贴板：没有文件可展示，记一条日志即可。
            guard let output else {
                DispatchQueue.main.async { SLog.log("截图已复制到剪贴板（退出码 \(status)）") }
                return
            }

            // 交互式截图被 Esc 取消时不会生成文件，这里据此区分「完成」与「取消」。
            let exists = FileManager.default.fileExists(atPath: output.path)
            DispatchQueue.main.async {
                if exists {
                    SLog.log("截图完成: \(output.path)")
                    FinderBridge.reveal(output)
                } else {
                    // 不武断说是「取消」：没有屏幕录制权限时 screencapture 同样不会生成文件。
                    SLog.log("截图未生成文件（可能已取消，或缺少屏幕录制权限；退出码 \(status)）")
                }
            }
        }

        do {
            try process.run()
        } catch {
            SLog.log("截图调用失败: \(error)")
        }
    }

    // MARK: - 工具

    /// 生成带时间戳的文件名。时间用「.」分隔 —— Finder 会把文件名里的「:」显示成「/」。
    private static func uniqueURL(in directory: URL) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "截图 \(formatter.string(from: Date()))"

        var candidate = directory.appendingPathComponent("\(base).png")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(index).png")
            index += 1
        }
        return candidate
    }

    private static func desktopDirectory() -> URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }
}
