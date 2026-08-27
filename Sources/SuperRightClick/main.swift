import AppKit

// 常驻菜单栏 App：不显示 Dock 图标，保持后台运行。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
