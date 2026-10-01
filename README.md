# SuperRightClick（超级右键）

macOS 右键菜单增强 App，复刻「超级右键 iRightMouse」的核心体验：在访达/桌面用自定义菜单替换原生右键菜单，实现 Windows 式的便捷操作。

## 功能

- **新建文件**：空白处右键新建 文件夹 / txt / md / json / csv / rtf / docx / xlsx（含最小可用 OOXML 生成）
- **打开方式**：列出可打开所选文件的所有 App，一键换 App 打开、选择其他应用
- **发送到**：AirDrop / 邮件 / 备忘录 / 信息等系统共享服务
- **复制路径 / 复制文件名**
- **拷贝 / 剪切 / 粘贴** 文件（文件级剪贴板）
- **压缩 / 解压**（ditto）
- **截图**：区域 / 窗口 / 全屏，可存到当前文件夹（自动在访达选中）或直接进剪贴板
- **用终端 / iTerm 打开**
- **隐藏 / 显示** 所选文件、**全局显示/隐藏隐藏文件**
- **移入废纸篓 / 立即删除**
- **显示系统菜单**（逃生口，还原 Finder 原生右键菜单）

## 架构

```
Sources/SuperRightClick/
├── main.swift            入口（菜单栏常驻、无 Dock 图标）
├── AppDelegate.swift     状态栏入口 + 权限引导 + 生命周期
├── EventTapManager.swift CGEventTap 全局右键拦截 + 逃生口 + 左键合成选中
├── FinderBridge.swift    AppleScript 桥（选中项 / 窗口目录 / reveal）
├── MenuBuilder.swift     按上下文构建 NSMenu
├── Actions.swift         全部文件动作实现
├── Screenshot.swift      截图（screencapture 封装 + 屏幕录制权限）
├── Templates.swift       新建文件模板
├── OOXML.swift           最小 .docx / .xlsx 生成
├── Shell.swift           系统命令封装
└── PermissionManager.swift 辅助功能权限
```

**原理**：`.cghidEventTap` + `.headInsertEventTap` 处拦截 `rightMouseDown/Up`，
当 Finder 前台时吞掉右键事件 → 合成左键让 Finder 先选中鼠标所指条目 → 弹出自定义 NSMenu。
菜单底部「显示系统菜单」会重新合成右键事件交还 Finder。

## 构建与运行

```bash
# 构建（debug）
swift build

# 打包成 .app（release）
./scripts/build-app.sh release

# 运行
open dist/SuperRightClick.app
```

> 需要 **Xcode 16+ / macOS 13+**。

## 权限

| 权限 | 用途 | 必须 |
|---|---|---|
| 辅助功能（Accessibility） | CGEventTap 拦截全局右键 | ✅ 必需 |
| 自动化（Automation） | AppleScript 控制「访达」读取选中项 | ✅ 首次使用时系统会提示 |
| 屏幕录制（Screen Recording） | 截图功能（`screencapture`） | 仅截图需要；未授权时截图只能拍到桌面壁纸 |

首次启动会引导前往「系统设置 → 隐私与安全性 → 辅助功能」授权。
用到截图时会自动触发「屏幕录制」授权弹窗，**授权后需退出并重新打开 App 才生效**。

### 签名与授权稳定性

`./scripts/build-app.sh` 会用**稳定的自签名证书**签名（`scripts/sign.sh` 负责创建/复用，证书存在专用钥匙串
`~/Library/Keychains/superrightclick-dev.keychain-db`，密码 `superrightclick-dev`）。
因此重新构建不会改变签名身份，辅助功能授权**只需授权一次**。

> 若签名时弹出钥匙串密码框，输入 `superrightclick-dev`；或预先执行
> `security unlock-keychain -p superrightclick-dev ~/Library/Keychains/superrightclick-dev.keychain-db`。

## 已知限制 / 后续

- MVP 仅在 **访达/桌面** 拦截（其它 App 保持原生右键）
- 尚未支持 pptx / pages / key / numbers 模板（当前 docx/xlsx 已实现）
- 「显示系统菜单」逃生口已实现；完整的 FinderSync 扩展、菜单编辑器、自定义命令模板、App Store 上架等为 P1/P2
- `NSSharingService.sharingServices` 在 macOS 13 起标记为 deprecated，但功能仍可用

## 参考

方案调研见 `../docs/超级右键-macOS-产品与实现方案.md`；竞品与开源参考：
[iRightMouse](https://www.irightmouse.com/)、[RClick](https://github.com/wflixu/RClick)、
[RightClick-Pro](https://github.com/iheeleme/RightClick-Pro)。
