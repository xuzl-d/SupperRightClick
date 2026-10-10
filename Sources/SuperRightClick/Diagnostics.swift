import AppKit
import CoreGraphics

/// 自检 / 诊断报告。
///
/// 目的：客户在远程机器上出问题时（例如「右键没反应」），让他点一下按钮，
/// 就能产出一份足够定位问题的报告 —— 覆盖权限、事件拦截状态、光标下窗口归属、
/// 系统与 App 版本、以及日志尾部。
enum Diagnostics {

    /// 生成纯文本报告（主线程调用；只做只读查询，不弹窗、不阻塞）。
    static func report() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let kernel = Shell.run("/usr/bin/uname", ["-r"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let perms = PermissionManager.shared
        let tap = EventTapManager.shared

        var lines: [String] = []
        lines.append("===== 超级右键 诊断报告 =====")
        lines.append("生成时间：\(timestamp())")
        lines.append("")
        lines.append("【App】")
        lines.append("版本：\(version) (build \(build))")
        lines.append("路径：\(Bundle.main.bundlePath)")
        lines.append("架构：\(architectures())\(rosettaNote())")
        lines.append("")
        lines.append("【系统】")
        lines.append("macOS：\(osString)（内核 \(kernel)）")
        lines.append("芯片：\(Shell.run("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        lines.append("")
        lines.append("【权限】")
        lines.append("辅助功能（Accessibility）：\(perms.isTrusted ? "✅ 已授权" : "❌ 未授权")")
        lines.append("输入监控（Input Monitoring）：\(perms.canListenEvents ? "✅ 已授权" : "❌ 未授权")")
        lines.append("")
        lines.append("【右键拦截】")
        lines.append("事件拦截：\(tap.isRunning ? "✅ 已创建" : "❌ 未创建")")
        if let place = tap.activePlace {
            let names: [CGEventTapLocation: String] = [
                .cghidEventTap: "cghidEventTap",
                .cgSessionEventTap: "cgSessionEventTap",
                .cgAnnotatedSessionEventTap: "cgAnnotatedSessionEventTap",
            ]
            lines.append("生效位置：\(names[place] ?? "未知")\(place == .cghidEventTap ? "" : "（已降级 —— HID 层被系统拒绝）")")
        }
        lines.append("tap 处于启用状态：\(tap.isTapEnabled ? "是" : "否")")
        lines.append("")
        lines.append("【光标下的判定依据】")
        let cursor = NSEvent.mouseLocation
        let flipped = CGPoint(x: cursor.x, y: screenHeight() - cursor.y)   // CG 坐标原点在左上
        lines.append("鼠标位置：屏幕坐标 \(Int(cursor.x)),\(Int(cursor.y)) → CG 坐标 \(Int(flipped.x)),\(Int(flipped.y))")
        if let pid = tap.axHitTestPID(at: flipped) {
            let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "nil"
            lines.append("辅助功能命中（判定主依据）：pid=\(pid) bundle=\(bid)")
        } else {
            lines.append("辅助功能命中（判定主依据）：失败/不可用")
        }
        lines.append("—— 以下为窗口列表（仅作兜底参考；整屏的系统 UI 覆盖层会排在真正窗口之前）——")
        let hits = tap.windows(at: flipped)
        if hits.isEmpty {
            lines.append("无窗口覆盖 → 按桌面处理（桌面归访达）")
        } else {
            for (i, win) in hits.prefix(4).enumerated() {
                lines.append("  #\(i + 1) \(win.oneLine)")
            }
            if let content = tap.topmostContentWindow(at: flipped) {
                lines.append("排除整屏覆盖层后的真正窗口：\(content.oneLine)")
                lines.append("是否识别为访达：\(content.bundleID == "com.apple.finder" ? "是" : "否")")
            } else {
                lines.append("排除整屏覆盖层后无真正窗口 → 按桌面处理（桌面归访达）")
            }
        }
        lines.append("")
        lines.append("【前台 App】")
        if let front = NSWorkspace.shared.frontmostApplication {
            lines.append("\(front.localizedName ?? "?")（\(front.bundleIdentifier ?? "?")）")
        } else {
            lines.append("未知")
        }
        lines.append("")
        lines.append("【日志尾部】/tmp/superrightclick.log")
        lines.append(tail(of: "/tmp/superrightclick.log", lines: 40))
        lines.append("")
        lines.append("【崩溃报告】若有，会出现在 ~/Library/Logs/DiagnosticReports/")
        lines.append(crashReports())
        return lines.joined(separator: "\n")
    }

    /// 生成报告 → 写到桌面 → 同时放进剪贴板 → 在访达中选中，方便客户直接发回来。
    static func collectAndExport() {
        let text = report()
        SLog.log("已生成诊断报告（\(text.count) 字符）")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let url = desktop.appendingPathComponent("超级右键-诊断报告.txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            SLog.log("诊断报告已写入: \(url.path)")
            FinderBridge.reveal(url)
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "诊断报告已生成"
            alert.informativeText = """
                已保存到桌面：超级右键-诊断报告.txt
                同时也复制到了剪贴板，可直接粘贴发送。

                \(text)
                """
            alert.addButton(withTitle: "好")
            alert.runModal()
        } catch {
            SLog.log("诊断报告写入失败: \(error)")
            let alert = NSAlert()
            alert.messageText = "诊断报告写入失败"
            alert.informativeText = "\(error)\n\n报告内容已复制到剪贴板，可直接粘贴发送。"
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    // MARK: - 工具

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    private static func screenHeight() -> CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    /// 不调用 lipo：macOS 27 上 /usr/bin/lipo 已不可用（客户报告里这一项显示「未知」，
    /// 而同样走子进程的 uname/sysctl 都正常，说明是 lipo 这个工具没了）。
    private static func architectures() -> String {
        guard let archs = Bundle.main.executableArchitectures, !archs.isEmpty else { return "未知" }
        return archs.map { number -> String in
            // cpu_type_t：CPU_ARCH_ABI64 = 0x01000000
            switch number.int32Value {
            case 0x0100_000c: return "arm64"
            case 0x0100_0007: return "x86_64"
            case 7: return "i386"
            case 18: return "ppc"
            default: return "cpu_type=\(number.int32Value)"
            }
        }.joined(separator: " ")
    }

    /// 是否正被 Rosetta 转译运行（Apple 芯片上跑 Intel 切片时为 1）。
    private static func rosettaNote() -> String {
        let value = Shell.run("/usr/sbin/sysctl", ["-n", "sysctl.proc_translated"])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == "1" ? "（经 Rosetta 转译运行）" : ""
    }

    private static func tail(of path: String, lines count: Int) -> String {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "（读取不到日志文件）"
        }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        return all.suffix(count).joined(separator: "\n")
    }

    private static func crashReports() -> String {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let mine = files.filter { $0.hasPrefix("SuperRightClick") }.sorted()
        return mine.isEmpty ? "（无）" : mine.suffix(5).joined(separator: "\n")
    }
}
