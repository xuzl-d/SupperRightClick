# macOS「超级右键」App — 产品功能梳理与实现方案

> 调研日期：2026 年 · 目标平台：macOS 13+（Apple Silicon + Intel）
> 参考竞品：超级右键 iRightMouse（免费版/专业版）、xClick 专业版、eMouse 我的右键、开源项目 RClick / RightClick-Pro / SzContext / MenuHelper

---

## 1. 市场与竞品分析

### 1.1 为什么有需求

macOS Finder 的原生右键菜单相比 Windows 明显"简陋"：

| 能力 | Windows 资源管理器 | macOS Finder |
|---|---|---|
| 空白处右键新建各类文件 | ✅ 内置（新建文本文档/文件夹/快捷方式…） | ❌ 只有"新建文件夹" |
| 打开方式 | ✅ 列表清晰、可改默认 | ⚠️ "打开方式"子菜单功能弱、入口深 |
| 发送到（AirDrop/邮件/App/文件夹） | ✅ 内置"发送到" | ❌ 需拖拽或共享按钮 |
| 复制文件路径 | ✅ 内置 | ❌ 需要按住 Option 或第三方 |
| 剪切/粘贴文件 | ✅ | ⚠️ 无"剪切"概念（Cmd+X 后 Cmd+V 是移动，但 UX 不直观） |

这正是「超级右键」这类工具的价值空间，也是国内用户的核心痛点。

### 1.2 竞品盘点

| 产品 | 形态 | 核心卖点 | 分发渠道 |
|---|---|---|---|
| **超级右键 iRightMouse**（宁波上官科技） | 免费版 + 专业版 | 新建各类文件、发送到、打开方式、复制路径、隐藏文件、压缩、终端打开、截图、自定义菜单 | App Store + 官网 |
| **xClick 专业版** | 付费 | 右键菜单扩展、命令自定义 | App Store |
| **eMouse 我的右键** | 付费 | 超级右键扩展、菜单自定义 | App Store |
| **RClick**（开源，GPLv3） | 免费开源 | 外部 App 打开、复制路径、直接删除、隐藏/显示、AirDrop、新建文件模板、常用目录、深色模式 | GitHub |
| **RightClick-Pro**（开源） | 免费开源 | FinderSync + XPC 架构、命令模板、操作日志、图标缓存 | GitHub |
| **SzContext / MenuHelper / SwiftyMenu** | 开源 | 菜单增强参考实现 | GitHub |

**结论**：市场已被验证，产品同质化严重。差异化机会在于：
1. 更完整的"Windows 习惯迁移"体验（新建文件 + 打开方式 + 发送到三大件做透）
2. 自定义命令模板 + 菜单编辑器（让用户自建右键动作，对标 Windows 注册表式扩展）
3. 更现代的原生 UI（SwiftUI，而非 iRightMouse 的老式界面）
4. 价格/授权策略（买断、家庭组、开源社区版）

---

## 2. 目标用户与产品定位

- **核心用户**：从 Windows 迁移到 Mac 的用户、办公人群、效率工具爱好者
- **定位**：Finder 右键菜单的"全面增强层"——不改变 Finder 本身，只增强右键
- **形态**：菜单栏常驻 App（设置与开关）+ 全局右键事件处理器 + 可选 Finder 扩展

---

## 3. 功能矩阵

### P0 — MVP 必做（决定产品生死）

| 功能 | 说明 | 技术要点 |
|---|---|---|
| **空白处右键新建文件** | 桌面/Finder 窗口空白处右键 → 新建 txt / rtf / md / docx / xlsx / pptx / pages / key / numbers / 文件夹 | CGEventTap 拦截 + 模板写入 + 目标目录定位 |
| **自定义新建模板** | 用户可添加自己的模板文件（含内容/格式） | 模板目录 + 文件拷贝 |
| **打开方式** | 列出所有可打开该文件的 App，点击即用指定 App 打开；可设默认 | NSWorkspace 枚举 + setDefaultApplication |
| **选择其他应用打开** | 弹出 App 选择面板 | NSOpenPanel（.app 过滤） |
| **复制路径 / 复制文件名** | 复制选中文件的完整路径或纯文件名 | Finder 选中项获取 + NSPasteboard |
| **发送到 → AirDrop / 邮件 / 备忘录** | 一键分享 | NSSharingService |
| **发送到 → 常用文件夹 / 指定 App** | 拷贝或移动文件到固定目标 | NSFileManager / Finder AppleScript |
| **用终端/iTerm 打开** | 在选中目录/文件所在目录打开终端 | NSWorkspace + AppleScript |
| **用 VSCode / Xcode / 编辑器打开** | 常用开发工具快捷打开 | NSWorkspace.open(URL, withApplicationAt:) |
| **显示/隐藏隐藏文件（全局开关）** | 一键切换 Finder 显示隐藏文件 | defaults write + killall Finder |
| **压缩 / 解压** | 右键压缩为 zip、解压 | /usr/bin/ditto |
| **直接删除 / 移入废纸篓** | 绕过废纸篓或标准删除 | NSFileManager.trashItem / rm |
| **剪切 / 复制 / 粘贴文件** | 文件级剪贴板操作 | Pasteboard + Finder move |
| **系统菜单逃生口** | 菜单底部"显示系统菜单"→ 还原 Finder 原生右键 | 重新合成并 post 右键事件 |
| **菜单自定义** | 开关各功能分组、排序 | 设置页持久化配置 |

### P1 — 增强功能（拉开差距）

| 功能 | 说明 |
|---|---|
| **自定义命令动作** | 用户配置"名称 + 命令 + 参数 + 环境变量"，右键一键执行（对标 RightClick-Pro 的命令模板） |
| **显示/隐藏文件扩展名** | 局部或全局切换 |
| **重命名（含批量）** | 选中后重命名、批量加前缀/序号 |
| **快速预览（Quick Look）** | 空格键等效 |
| **显示简介** | 打开 Finder 信息窗口 |
| **制作替身（Alias）** | Finder 替身 |
| **常用目录收藏** | 右键直达收藏目录 |
| **最近使用** | 最近打开的文件/目录 |
| **菜单图标** | 文件类型图标、App 图标实时加载（含缓存） |
| **多语言** | 中/英/日 |

### P2 — 远期（差异化探索）

- 触控板/鼠标手势自定义（三指轻点、按键组合触发不同菜单）
- 截图/录屏入口
- 剪贴板历史整合
- 云同步配置（iCloud/自建）
- 图标叠加层（badge，需要 FinderSync 的 badge API）

---

## 4. 技术实现方案

### 4.1 三条技术路线对比

| 方案 | 原理 | 优点 | 缺点 |
|---|---|---|---|
| **A. Finder Sync Extension** | 官方 App Extension，通过 `FIFinderSyncController.menu(for:)` 注入菜单 | 官方支持、沙盒安全、可上架 App Store、无需辅助功能权限 | 菜单只能作为 Finder 原生菜单中的一个**子菜单/分区**，无法整体替换；只能操作选中项或容器（`contextualMenuForContainer` 可覆盖空白区右键，但能力有限）；无法接管"打开方式"等系统菜单项；注册目录有限制 |
| **B. CGEventTap 全局拦截 + 自定义 NSMenu** | 低层 API 监听全局右键事件（`.cghidEventTap` + `.headInsertEventTap`），**吞掉**事件后弹出自己的 NSMenu，实现 Windows 式整体替换 | 完全可控、体验最佳（超级右键/多数国产工具均为此路线）；可覆盖桌面空白、Finder 窗口空白、选中文件全场景 | 需要**辅助功能（Accessibility）权限**；需处理与原生菜单的衔接（逃生口）；存在被系统限制/误判风险；App Store 审核需谨慎 |
| **C. Accessibility AX 注入** | 用 AXUIElement 读取选中项/窗口信息，配合菜单栏模拟 | 可获取跨 App 选中文本/文件 | 不能注入 Finder 真实菜单；性能差；仅适合辅助功能（如 send-to-gpt 的"追加菜单"） |

### 4.2 推荐架构：混合方案（B 为主 + A 为辅）

```
┌──────────────────────────────────────────────────────┐
│  主 App（SwiftUI 菜单栏应用）                           │
│  · 设置页：功能开关、模板管理、菜单编辑器、权限向导       │
│  · 登录启动：SMAppService（macOS 13+）                │
└───────────────┬──────────────────────────────────────┘
                │ DistributedNotificationCenter / NSXPC
┌───────────────▼──────────────────────────────────────┐
│  Global Right-Click Handler（CGEventTap）             │
│  · 监听 rightMouseDown/Up（.cghidEventTap 头部插入）   │
│  · 吞掉事件 → 主线程构建并弹出自定义 NSMenu             │
│  · 菜单项点击 → 分发到 Action 层                      │
│  · 逃生口：重新 post 右键事件还原系统菜单               │
└───────────────┬──────────────────────────────────────┘
┌───────────────▼──────────────────────────────────────┐
│  Action Layer（文件操作/App 启动/AppleScript）         │
│  · 新建文件、打开方式、发送到、压缩、复制路径…          │
│  · 通过 AppleScript 驱动 Finder 执行需权限的操作        │
└──────────────────────────────────────────────────────┘

可选组件：
  FinderSync Extension（App Store 友好版）→ 官方注入路径，作为兜底
  XPC Service（RightClick-Pro 模式）→ 操作与 UI 隔离，权限最小化
```

**关键进程模型**：主 App 常驻菜单栏；CGEventTap 放在独立后台进程（或主进程专用 RunLoop 线程），避免菜单 UI 卡顿影响事件处理。参照 [RClick 双进程架构](https://github.com/wflixu/RClick)（主 App + FinderSyncExt，DistributedNotificationCenter 通信）与 [RightClick-Pro](https://github.com/iheeleme/RightClick-Pro/blob/main/docs/architecture.md)（FinderSync + XPC ActionRunner + JSON 配置 + 图标缓存）。

### 4.3 核心技术实现要点

#### ① CGEventTap 事件拦截（核心中的核心）

```swift
// 参考 send-to-gpt 项目验证过的模式
let mask = (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.rightMouseUp.rawValue)
let tap = CGEvent.tapCreate(
    tap: .cghidEventTap,
    place: .headInsertEventTap,          // 头部插入，先于 Finder 拿到事件
    options: .defaultTap,
    eventsOfInterest: CGEventMask(mask),
    callback: callback, userInfo: nil
)
```

- **权限**：创建事件 tap 需要辅助功能权限（`AXIsProcessTrusted`），需做权限引导（检测 → 弹窗 → 打开系统设置 → 监听授权回调）。
- **回调必须极快**：回调里只做标记 + 派发到主线程，**禁止**在回调里做磁盘 I/O、图标加载、JSON 解析（RightClick-Pro 明确警告：菜单渲染不得同步做图标/配置解析，用后台队列 + 缓存）。
- **坐标换算**：CGEvent 坐标原点在左上，NSEvent.mouseLocation 原点在左下，弹菜单前需换算；多显示器按屏幕包含关系定位。

#### ② 新建文件（最核心卖点）

1. 判断右键落点：桌面（Desktop 路径）还是 Finder 窗口（AppleScript 取 front window 的 target 路径）还是某目录；
2. 若落点下有选中文件 → 目标目录为选中文件所在目录；
3. 用模板文件（内置 + 用户自定义）`FileManager.createFile` / `copyItem` 写入；
4. 创建后 `NSWorkspace.activateFileViewerSelecting` 选中新文件并尝试进入重命名态（iRightMouse 的做法：创建后自动高亮待重命名）。

#### ③ 打开方式

```swift
// 枚举可打开该文件的所有 App
NSWorkspace.shared.urlsForApplications(toOpen: url)
// 查询当前默认
// LSCopyDefaultApplicationURLForURL
// 设为默认
NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: url) { error in }
// 指定 App 打开
NSWorkspace.shared.open(url, withApplicationAt: appURL, configuration: .init())
```

#### ④ 发送到

- **AirDrop**：`NSSharingService(named: .sendViaAirDrop)`（官方能力，直接唤起 AirDrop 面板，见 [Apple 文档](https://developer.apple.com/documentation/appkit/nssharingservice/name/sendviaairdrop?language=objc)）；
- **邮件/备忘录**：对应 NSSharingService 服务；
- **常用文件夹**：文件移动/拷贝（NSFileManager 或 Finder AppleScript `move`/`duplicate`）。

#### ⑤ 获取 Finder 选中项（全局场景）

FinderSync 扩展内可用 `selectedItemURLs`；全局场景用 AppleScript：

```applescript
tell application "Finder" to get selection as alias list
-- 或获取窗口目标目录：
tell application "Finder" to get target of front window
```

#### ⑥ 文件操作

| 操作 | 实现 |
|---|---|
| 复制路径 | `NSPasteboard` 写入 `public.file-url` / 纯文本路径 |
| 剪切/粘贴 | 自定义 Pasteboard 标记 + `Finder move` 或 `FileManager.moveItem` |
| 移入废纸篓 | `FileManager.trashItem(at:)`（macOS 10.8+，可撤销） |
| 直接删除 | `rm -rf`（需谨慎 + 二次确认） |
| 压缩/解压 | `ditto -c -k --sequesterRsrc --keepParent` / `ditto -x -k` |
| 显示/隐藏文件 | `chflags hidden`/`nohidden`；全局开关 `defaults write com.apple.finder AppleShowAllFiles` + `killall Finder` |
| 显示简介 | AppleScript `open information window of` |
| 快速预览 | `QLPreviewPanel` |

#### ⑦ 系统菜单逃生口（降低风险）

自定义菜单底部放"显示系统菜单"项：关闭自己的菜单后，用 CGEvent 合成 `rightMouseDown/Up` 重新 `CGEventPost` 到 `.cghidEventTap`，让 Finder 弹出原生菜单。

#### ⑧ 权限策略

| 权限 | 用途 | 必须性 |
|---|---|---|
| 辅助功能（Accessibility） | CGEventTap 监听全局右键 | **必需** |
| 输入监控（Input Monitoring） | 若监听键盘事件（快捷键） | 可选 |
| 完全磁盘访问（Full Disk Access） | 访问系统/隐藏文件、非沙盒写盘 | 增强版 |
| 沙盒 | App Store 版强制 | 分版本 |

**分版本策略**（参照 iRightMouse 免费/专业双轨）：
- **官网版**（Developer ID + 公证）：非沙盒，全功能，体验完整；
- **App Store 版**：沙盒，文件操作尽量经 AppleScript 驱动 Finder（Finder 进程持有权限），CGEventTap 依然可用（沙盒不禁止事件 tap）。

### 4.4 技术栈与工程结构

```text
SuperRightClick/
├── App/                    # SwiftUI 主 App（菜单栏 + 设置）
│   ├── Settings/           # 功能开关、模板管理、菜单编辑器、权限向导
│   ├── MenuBuilder/        # NSMenu 构建（分组、图标、状态）
│   └── Models/             # 配置模型（Codable）
├── Core/                   # 共享核心（Swift Package）
│   ├── EventTap/           # CGEventTap 封装（监听/吞事件/重发）
│   ├── Finder/             # AppleScript 桥、选中项/窗口目录获取
│   ├── Actions/            # 新建/打开方式/发送到/压缩/路径/终端…
│   ├── Templates/          # 内置 + 用户模板管理
│   └── IPC/                # DistributedNotificationCenter / NSXPC
├── FinderSyncExt/          # 可选：官方注入扩展（App Store 版兜底）
├── XPCService/             # 可选：ActionRunner（权限隔离）
└── Shared/                 # App Group、共享 UserDefaults/JSON
```

- **语言/框架**：Swift 6.2 + SwiftUI（设置 UI）+ AppKit（NSMenu/NSWorkspace/NSSharingService/QLPreviewPanel 系统集成）+ SwiftData 或 JSON（配置持久化）
- **最低系统**：macOS 13（Ventura）起步，兼容 14/15/26（Tahoe）
- **构建**：Xcode 16.4+，`xcodebuild` 脚本化构建 + Developer ID 签名 + 公证（notarytool）

### 4.5 里程碑路线

| 阶段 | 内容 | 验收标准 |
|---|---|---|
| **M1 MVP（2-3 周）** | 工程骨架 + CGEventTap 拦截 + 自定义菜单弹出 + 新建文件（内置模板）+ 复制路径 + 打开方式 + 系统菜单逃生口 | 桌面/Finder 空白右键可新建文件；文件右键可换 App 打开 |
| **M2 核心增强（2-3 周）** | 发送到（AirDrop/邮件/文件夹）+ 压缩/解压 + 终端/编辑器打开 + 隐藏文件 + 剪切/粘贴 + 废纸篓/直接删除 | 功能矩阵 P0 全部可用 |
| **M3 个性化（2 周）** | 菜单编辑器 + 自定义命令动作 + 模板管理 + 多语言 + 图标缓存 | 用户可自建右键动作 |
| **M4 分发（1-2 周）** | 签名 + 公证 + DMG/官网下载 + 自动更新（Sparkle）+ 可选 App Store 上架 | 全功能稳定版对外发布 |

---

## 5. 关键风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| 吞掉右键事件后原生菜单缺失 | 用户困惑 | 菜单底部常驻"显示系统菜单"逃生口；提供"追加模式"开关（不吞事件，浮动面板追加，参照 send-to-gpt） |
| 与其它右键增强工具冲突 | 双菜单/失效 | 事件 tap 用 `.headInsertEventTap`；检测已知冲突 App 并提示 |
| CGEventTap 回调阻塞导致系统卡顿 | 体验灾难 | 回调零 I/O、极速返回；菜单构建异步；压力测试 |
| 系统版本升级（macOS 26）行为变化 | 功能失效 | 运行时检测版本动态适配（iRightMouse 同策略）；持续跟进 beta |
| App Store 审核拒绝 | 无法上架 | 官网版为主；MAS 版用 FinderSync + 受限能力 |
| 安全审计（恶意命令模板） | 信任受损 | 命令模板默认白名单 + 二次确认 + 日志记录 |
| 坐标/多显示器/深色模式 | UI 瑕疵 | 按屏幕枚举定位；NSMenu 自适应深色；真机多屏测试 |

---

## 6. 参考资料

- 竞品：超级右键 iRightMouse [App Store](https://apps.apple.com/cn/app/%E8%B6%85%E7%BA%A7%E5%8F%B3%E9%94%AE-irightmouse/id1497428978?mt=12) / [官网](https://www.irightmouse.com/) / [少数派评测](https://sspai.com/post/59097)、[xClick](https://apps.apple.com/cn/app/xclick%E4%B8%93%E4%B8%9A%E7%89%88-%E5%BC%BA%E5%A4%A7%E7%9A%84%E5%8F%B3%E9%94%AE%E8%8F%9C%E5%8D%95%E6%89%A9%E5%B1%95%E5%B7%A5%E5%85%B7/id6475661239?mt=12)、[eMouse](https://apps.apple.com/cn/app/emouse-%E6%88%91%E7%9A%84%E5%8F%B3%E9%94%AE-%E8%B6%85%E7%BA%A7%E5%8F%B3%E9%94%AE-%E6%89%A9%E5%B1%95/id1597745644?mt=12)
- 开源参考：[RClick](https://github.com/wflixu/RClick)（SwiftUI + FinderSync 双进程）、[RightClick-Pro 架构文档](https://github.com/iheeleme/RightClick-Pro/blob/main/docs/architecture.md)（FinderSync + XPC + 图标缓存 + 命令模板）、[SzContext](https://github.com/RoadToDream/SzContext)、[MenuHelper](https://github.com/Kyle-Ye/MenuHelper)、[SwiftyMenu](https://github.com/lexrus/SwiftyMenu)
- 官方文档：[Finder Sync 编程指南](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html)、[FIMenuKind](https://developer.apple.com/documentation/findersync/fimenukind)、[NSSharingService.sendViaAirDrop](https://developer.apple.com/documentation/appkit/nssharingservice/name/sendviaairdrop?language=objc)、[NSWorkspace.setDefaultApplication](https://developer.apple.com/documentation/appkit/nsworkspace/setdefaultapplication(at:toopen:completion:)?changes=_7)
- 事件拦截验证：[macos-right-click-send-to-gpt implementation-notes](https://github.com/bra1nDump/macos-right-click-send-to-gpt/blob/main/implementation-notes.md)（CGEventTap + Accessibility 完整代码模式）
