import AppKit
import ApplicationServices
import CoreGraphics

/// 全局右键事件拦截器（CGEventTap）。
///
/// 原理：在 `.cghidEventTap` + `.headInsertEventTap` 处监听 rightMouseDown/Up，
/// 当右键目标为 Finder/桌面时「吞掉」右键事件，改由本 App 弹出自定义菜单，
/// 实现 Windows 式的右键菜单替换。
final class EventTapManager {
    static let shared = EventTapManager()

    /// 右键抬起时回调（主线程）。
    var onRightClick: (() -> Void)?

    /// 右键按下并确认拦截时回调（主线程），用于后台预取菜单数据。
    var prepareMenu: (() -> Void)?

    /// 菜单展示期间再次右键时调用，用于关闭当前菜单。
    var cancelCurrentMenu: (() -> Void)?

    /// 最近一次被拦截的右键坐标（CG 坐标系，原点左上）。
    private(set) var lastClickLocation: CGPoint = .zero

    /// 最近一次右键是否落在桌面（无任何窗口覆盖）。
    private(set) var lastClickOnDesktop = false

    /// 自定义菜单是否正在展示。
    var isShowingMenu = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pendingRightDown = false
    private var skipEvents = 0
    /// 上一次右键按下的时间 + 「因抖动被吞掉」的抬起事件计数。
    /// 鼠标微动/驱动补发会在几毫秒内再发一对 down/up；若把它当成"菜单展示中再次右键"，
    /// 就会在菜单刚弹出时合成一次左键 → 被系统当成点击菜单外部 → 菜单**一闪**。
    private var lastRightDownAt: Date = .distantPast
    private var swallowRightUps = 0
    /// 抖动判定窗口（人类的第二次右键通常 > 200ms，这里取 180ms）
    private let duplicateRightClickWindow: TimeInterval = 0.18
    /// 本次菜单弹出的时刻（用于诊断"存活过短"）
    var menuOpenedAt: Date?
    private var watchdogTimer: Timer?
    /// 最近一次鼠标左键点击（含我们合成的）的时间与位置：
    /// 用来判断光标下的条目是否已经被选中，避免把合成的左键变成双击。
    private var lastLeftClickAt: Date = .distantPast
    private var lastLeftClickPoint: CGPoint = .zero

    var isRunning: Bool { eventTap != nil }

    /// tap 是否处于系统启用状态（被系统因回调超时等原因停用时为 false）。
    var isTapEnabled: Bool {
        guard let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// 实际生效的 tap 位置（写进诊断报告，便于判断是否被降级）。
    private(set) var activePlace: CGEventTapLocation?

    /// 必须在主线程调用（将 run loop source 挂到主 run loop）。
    /// 依次尝试从「最激进」到「较保守」的 tap 位置：新版 macOS 可能拒绝 HID 层拦截，
    /// 但会话层通常仍可用，且仍足以吞掉右键事件。
    func start() -> Bool {
        guard eventTap == nil else { return true }

        // 除了右键，也监听左键「按下」：只用来记录用户最近点过哪里，
        // 以便判断光标下的条目是否已被选中（否则合成的左键会变成双击打开文件）。
        // 左键事件我们原样放行，不做任何拦截。
        let mask = CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
                 | CGEventMask(1 << CGEventType.rightMouseUp.rawValue)
                 | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
                 | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)

        let candidates: [(CGEventTapLocation, String)] = [
            (.cghidEventTap, "cghidEventTap"),
            (.cgSessionEventTap, "cgSessionEventTap"),
            (.cgAnnotatedSessionEventTap, "cgAnnotatedSessionEventTap"),
        ]

        for (place, name) in candidates {
            guard let tap = CGEvent.tapCreate(
                tap: place,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, _ in
                    EventTapManager.shared.handle(type: type, event: event)
                },
                userInfo: nil
            ) else {
                SLog.log("事件拦截创建失败于 \(name)（辅助功能/输入监控未授权，或该系统版本不允许）")
                continue
            }

            eventTap = tap
            activePlace = place
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            startWatchdog()
            if place == .cghidEventTap {
                SLog.log("事件拦截已启动（\(name)）")
            } else {
                SLog.log("事件拦截已启动，但降级到 \(name)（HID 层被系统拒绝）")
            }
            return true
        }
        return false
    }

    func stop() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        SLog.log("事件拦截已停止")
    }

    /// 看门狗：若系统因回调超时等原因停用了 tap，自动重新启用。
    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self, let tap = self.eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                SLog.log("⚠️ 事件拦截被系统停用，尝试重新启用")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
    }

    /// 吞掉一次右键后，重新合成右键事件交给 Finder 弹出「系统原生菜单」（逃生口）。
    func showSystemMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.skipEvents = 2
            let pt = self.lastClickLocation
            CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: pt, mouseButton: .right)?
                .post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: pt, mouseButton: .right)?
                .post(tap: .cghidEventTap)
        }
    }

    /// 在右键按下时合成一次左键点击，让 Finder 先完成「选中/取消选中」，
    /// 这样后续通过 AppleScript 读到的 selection 才与鼠标所指一致。
    ///
    /// 关键：**不能盲目合成**。如果光标下的条目刚刚已经被点过（用户先左键选中再右键、
    /// 或连续两次右键），这次合成的左键会被访达判定成**双击 → 直接打开文件**。
    /// 那时条目本来就已经是选中状态，跳过合成即可，既避免误开也不影响菜单内容。
    func synthesizeLeftClick() {
        let raw = lastClickLocation

        // ① 条目本来就已选中 → 一次点击都不需要。
        //    多合成这一下会：点在文件名上→进入重命名；多选→塌缩成一个；间隔太短→被当成双击打开。
        if FinderBridge.isFinderItemAlreadySelected(at: raw) == true {
            SLog.log("光标下的条目已是选中状态，跳过合成左键（避免误入重命名 / 塌缩多选 / 误打开）")
            return
        }

        // ② 刚在同一位置点过（系统双击间隔内）→ 同样跳过，避免被判成双击。
        let elapsed = Date().timeIntervalSince(lastLeftClickAt)
        let distance = hypot(raw.x - lastLeftClickPoint.x, raw.y - lastLeftClickPoint.y)
        if elapsed < NSEvent.doubleClickInterval && distance < 4 {
            SLog.log(String(format: "跳过合成左键：%.0f ms 前同一位置已有点击（距离 %.1f px），"
                         + "再点会被判成双击打开文件", elapsed * 1000, distance))
            return
        }

        // ③ 落点若正落在「文件名文本框」上，左移到同一行的图标区 ——
        //    列表/分栏视图里文件名是可编辑的 AXTextField，而「单击已选中条目的名字」在访达里
        //    就是重命名。左移到图标后，这次点击永远只表示选中，不可能触发改名。
        let pt = clickPointAvoidingNameField(raw)

        lastLeftClickAt = Date()
        lastLeftClickPoint = raw

        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left)
        // 显式标记为「第 1 次点击」，避免与相邻点击被系统合并成双击。
        down?.setIntegerValueField(.mouseEventClickState, value: 1)
        up?.setIntegerValueField(.mouseEventClickState, value: 1)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// 把落在「条目文件名文本框」上的落点左移到同一行的图标区（y 不变）。
    /// 实测分栏视图的一行：行 x=2161..2351，文件名文本框 x=2181..2348 ——
    /// 左移 10px 落在图标区，且仍在同一行内。
    /// （internal 而非 private：便于用真实分栏视图做验证。）
    func clickPointAvoidingNameField(_ point: CGPoint) -> CGPoint {
        guard let field = FinderBridge.nameTextField(at: point),
              let fieldFrame = FinderBridge.frame(of: field),
              let rowFrame = FinderBridge.frameOfParent(of: field) else { return point }
        let shiftedX = max(rowFrame.minX + 2, fieldFrame.minX - 10)
        guard shiftedX < fieldFrame.minX, shiftedX >= rowFrame.minX else { return point }
        SLog.log(String(format: "合成左键落点从文件名文本框左移到图标区：x %.0f → %.0f", point.x, shiftedX))
        return CGPoint(x: shiftedX, y: point.y)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 逃生口：放行即将到来的 N 个事件（只针对右键，别被左键把计数吃掉）。
        if skipEvents > 0, type == .rightMouseDown || type == .rightMouseUp {
            skipEvents -= 1
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown:
            // 只记录「用户刚点过哪里」：用于判断光标下的条目是否已被选中，
            // 从而避免合成左键被误判成双击。事件原样放行。
            lastLeftClickAt = Date()
            lastLeftClickPoint = event.location
            return Unmanaged.passUnretained(event)

        case .leftMouseUp:
            return Unmanaged.passUnretained(event)
        case .rightMouseDown:
            lastClickLocation = event.location

            // ① 过滤「抖动/重复」右键：直接吞掉，且**完全不动菜单**。
            let now = Date()
            let sinceLast = now.timeIntervalSince(lastRightDownAt)
            if sinceLast < duplicateRightClickWindow {
                swallowRightUps += 1
                SLog.log(String(format: "右键按下来得太密（%.0f ms 内重复）→ 判定为抖动/重复，吞掉且不动菜单", sinceLast * 1000))
                return nil
            }
            lastRightDownAt = now

            if isShowingMenu {
                // ② 菜单展示中再次右键（用户有意重定位）：**先关旧菜单，再合成左键**。
                //    顺序若反过来，这次合成左键会被系统当成"点击菜单外部"，把刚弹出的菜单顶掉
                //    —— 用户看到的就是「菜单一闪就消失」。
                SLog.log("右键按下: 菜单展示中 → 先关旧菜单，再合成左键重定位")
                cancelCurrentMenu?()
                cancelCurrentMenu = nil
                isShowingMenu = false
                pendingRightDown = true
                synthesizeLeftClick()
                prepareMenu?()
                return nil
            }

            guard isFinder(at: event.location) else {
                SLog.log("右键按下: 非 Finder 目标，放行（系统菜单）")
                return Unmanaged.passUnretained(event)
            }

            SLog.log("右键按下: Finder 目标，拦截并合成左键选中")
            pendingRightDown = true
            synthesizeLeftClick()
            prepareMenu?()                                 // 后台预取选中项等数据
            return nil

        case .rightMouseUp:
            if swallowRightUps > 0 {
                swallowRightUps -= 1
                SLog.log("右键抬起: 与已过滤的抖动 down 配对 → 一并吞掉")
                return nil
            }
            if pendingRightDown {
                pendingRightDown = false
                lastClickLocation = event.location
                SLog.log("右键抬起: 触发自定义菜单")
                DispatchQueue.main.async { [weak self] in
                    self?.onRightClick?()
                }
                return nil
            }
            if isShowingMenu {
                return nil   // 菜单展示中的右键抬起一并吞掉
            }

        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// 光标处最上层窗口的归属信息（Finder 判定与诊断报告共用）。
    struct WindowInfo {
        let ownerName: String
        let pid: pid_t
        let bundleID: String?
        let layer: Int
        let bounds: CGRect

        var oneLine: String {
            "owner=\(ownerName) pid=\(pid) bundle=\(bundleID ?? "nil") layer=\(layer) bounds=\(Int(bounds.origin.x)),\(Int(bounds.origin.y)) \(Int(bounds.width))x\(Int(bounds.height))"
        }
    }

    /// 取指定坐标处所有包含该点的窗口（列表顺序 = 前后顺序）。
    func windows(at point: CGPoint) -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result: [WindowInfo] = []
        for info in infos {
            guard let b = info[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? CGFloat,
                  let y = b["Y"] as? CGFloat,
                  let w = b["Width"] as? CGFloat,
                  let h = b["Height"] as? CGFloat else { continue }
            let rect = CGRect(x: x, y: y, width: w, height: h)
            guard rect.contains(point) else { continue }
            let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            result.append(WindowInfo(
                ownerName: info[kCGWindowOwnerName as String] as? String ?? "?",
                pid: pid,
                bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                bounds: rect
            ))
        }
        return result
    }

    /// 取指定坐标处最上层窗口（不过滤覆盖层，用于诊断展示）。
    func topmostWindow(at point: CGPoint) -> WindowInfo? {
        windows(at: point).first
    }

    /// 「真正的应用窗口」：跳过覆盖整屏的系统 UI 窗口（程序坞/通知中心等）。
    ///
    /// 为什么要跳：新版 macOS 上这些进程会挂出**覆盖整屏**的窗口
    /// （macOS 27 的程序坞 layer=20 `0,0 2056x1329`；macOS 26 的通知中心 layer=21 全屏），
    /// 且排在真正的应用窗口之前。程序坞图标条、菜单栏那种小窗口仍算真实命中。
    func topmostContentWindow(at point: CGPoint) -> WindowInfo? {
        let screenArea = NSScreen.screens
            .map { $0.frame.width * $0.frame.height }
            .max() ?? 0
        for win in windows(at: point) {
            if let bid = win.bundleID, Self.systemOverlayBundles.contains(bid) {
                let area = win.bounds.width * win.bounds.height
                if screenArea > 0 && area >= screenArea * 0.9 { continue }   // 整屏覆盖层
            }
            return win
        }
        return nil
    }

    /// 覆盖整屏的系统 UI 进程（这些窗口不应当作「光标下的应用」）。
    private static let systemOverlayBundles: Set<String> = [
        "com.apple.dock",
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
        "com.apple.wallpaper",
        "com.apple.WallpaperAgent",
        "com.apple.WindowManager",
        "com.apple.Spotlight",
        "com.apple.WindowServer",
    ]

    /// 桌面在辅助功能语义上归属的进程（点桌面等同点访达）。
    private static let desktopBundles: Set<String> = [
        "com.apple.finder",
        "com.apple.wallpaper",
        "com.apple.WallpaperAgent",
    ]

    /// 用辅助功能命中测试取出光标下的元素（坐标用 CG 系，原点左上）。
    /// 这是唯一能绕开「整屏系统覆盖层」的判定手段：它按真实可交互元素命中，
    /// 而不是「谁先覆盖了这个坐标」。
    func axElement(at point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element
        )
        guard error == .success, let element else { return nil }
        return element
    }

    /// 光标下元素所属进程。
    func axHitTestPID(at point: CGPoint) -> pid_t? {
        guard let element = axElement(at: point) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    /// 判断鼠标坐标处是否为访达（窗口或桌面）。
    ///
    /// 血泪教训：**不要**用「窗口列表里第一个包含该点的窗口」来判定。新版 macOS 上
    /// 系统 UI 会挂出覆盖整屏的窗口并排在真正的应用窗口之前，于是任何位置都被判成
    /// 「非访达」，右键全部放行给系统菜单 —— 客户在 macOS 27 上遇到的正是这个：
    /// `owner=程序坞 layer=20 bounds=0,0 2056x1329`。
    /// 现在以辅助功能命中测试为准，窗口列表只作为命中测试不可用时的兜底。
    private func isFinder(at point: CGPoint) -> Bool {
        let axPid = axHitTestPID(at: point)
        let axBundle = axPid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        let contentWindow = topmostContentWindow(at: point)

        // 桌面判定：光标下没有「真正的应用窗口」→ 视为桌面。
        lastClickOnDesktop = (contentWindow == nil)

        if let axBundle {
            let matched = Self.desktopBundles.contains(axBundle)
            if !matched {
                SLog.log("右键目标非访达，放行给系统：AX 命中 \(axBundle)"
                         + (axPid.map { " pid=\($0)" } ?? "")
                         + "，窗口=\(contentWindow?.oneLine ?? "无（桌面）")")
            }
            return matched
        }

        // 兜底：辅助功能命中测试不可用时，才退回窗口列表判定。
        if let win = contentWindow {
            SLog.log("辅助功能命中测试不可用，改用窗口判定：\(win.oneLine)")
            return win.bundleID == "com.apple.finder"
        }
        return true   // 无内容窗口覆盖 → 桌面（归访达管辖）
    }
}
