#!/usr/bin/env swift
// 生成 AppIcon.icns（圆角渐变底 + 白色右键菜单符号）与预览图
// 用法: swift scripts/make-icon.swift Assets
import AppKit
import Foundation

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Assets"
let outURL = URL(fileURLWithPath: outDir)

func render(px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: px, height: px))

    let scale = CGFloat(px) / 1024.0
    let rect = CGRect(x: 0, y: 0, width: px, height: px)

    // 1) 背景：圆角渐变方块（macOS 图标风格，圆角 ≈ 22.5%）
    let bgRect = rect.insetBy(dx: 16 * scale, dy: 16 * scale)
    let path = NSBezierPath(
        roundedRect: bgRect,
        xRadius: bgRect.width * 0.225, yRadius: bgRect.height * 0.225
    )
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.57, blue: 0.98, alpha: 1.0),
        NSColor(calibratedRed: 0.45, green: 0.32, blue: 0.94, alpha: 1.0),
    ])!
    gradient.draw(in: path, angle: -70)

    // 2) 顶部柔光
    ctx.saveGState()
    path.addClip()
    let glow = NSGradient(colors: [
        NSColor(calibratedWhite: 1.0, alpha: 0.22),
        NSColor(calibratedWhite: 1.0, alpha: 0.0),
    ])!
    let glowRect = CGRect(x: bgRect.minX, y: bgRect.midY, width: bgRect.width, height: bgRect.height / 2)
    glow.draw(in: NSBezierPath(rect: glowRect), angle: -90)
    ctx.restoreGState()

    // 3) 白色符号：右键菜单光标
    if let symbol = NSImage(systemSymbolName: "filemenu.and.cursorarrow", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white])) {
        let s = bgRect.width * 0.62
        let symbolRect = CGRect(x: rect.midX - s / 2, y: rect.midY - s / 2, width: s, height: s)
        symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ name: String) {
    let url = outURL.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
    try! data.write(to: url)
    print("写入 \(url.path)")
}

// 1) 预览图 1024
write(render(px: 1024), "icon-preview.png")

// 2) iconset
let iconset = outURL.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in sizes {
    try! render(px: px).write(to: iconset.appendingPathComponent(name))
}

// 3) iconutil 打包
let icns = outURL.appendingPathComponent("AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! p.run()
p.waitUntilExit()
print("生成 \(icns.path) (exit \(p.terminationStatus))")
