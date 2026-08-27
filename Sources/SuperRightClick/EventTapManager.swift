import AppKit
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
    private var watchdogTimer: Timer?

    var isRunning: Bool { eventTap != nil }

    /// 必须在主线程调用（将 run loop source 挂到主 run loop）。
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask = CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
                 | CGEventMask(1 << CGEventType.rightMouseUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                EventTapManager.shared.handle(type: type, event: event)
            },
            userInfo: nil
        ) else {
            SLog.log("事件拦截创建失败（辅助功能未授权？）")
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        startWatchdog()
        SLog.log("事件拦截已启动")
        return true
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
    func synthesizeLeftClick() {
        let pt = lastClickLocation
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 逃生口：放行即将到来的 N 个事件。
        if skipEvents > 0 {
            skipEvents -= 1
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .rightMouseDown:
            lastClickLocation = event.location

            if isShowingMenu {
                // 菜单展示中再次右键：吞掉本次右键，抬起后在新位置弹新菜单
                // （关闭旧菜单由 MenuBuilder.show 负责，避免事件泄漏给 Finder）。
                SLog.log("右键按下: 菜单展示中 → 吞掉，准备重定位新菜单")
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

    /// 判断鼠标坐标处是否为 Finder（窗口或桌面）。
    /// 使用 CGWindowList 直接定位光标下的窗口，避免依赖「前台 App」（时序不可靠）。
    /// 注意：必须考虑所有层级窗口——Dock/菜单栏等高层级系统 UI 若只过滤 layer 0，
    /// 会被误判为「桌面」，导致其原生右键菜单被我们吞掉。
    private func isFinder(at point: CGPoint) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        // 列表按从前到后排列，首个覆盖该点的窗口即为最上层窗口（含 Dock/菜单栏等）。
        for info in infos {
            guard let b = info[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? CGFloat,
                  let y = b["Y"] as? CGFloat,
                  let w = b["Width"] as? CGFloat,
                  let h = b["Height"] as? CGFloat else { continue }
            let rect = CGRect(x: x, y: y, width: w, height: h)
            if rect.contains(point) {
                lastClickOnDesktop = false
                guard let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return false }
                return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.finder"
            }
        }
        // 无窗口覆盖 → 桌面（归 Finder 管辖）
        lastClickOnDesktop = true
        return true
    }
}
