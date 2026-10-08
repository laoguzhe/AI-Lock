# AI Lock

AI Lock 是一款 macOS 本机活动与资源监控工具，目标是让用户及时看见 AI 与其他软件对电脑、文件和网络的操作。当前版本正在从 DockLock 演进，包含原有的多显示器 Dock 固定能力与第一阶段资源仪表盘。

文件审计、逐进程网络、系统日志、快速搜索、剪贴板和硬件监控将按开发计划逐步接入。全量文件审计和原始网络包捕获需要额外 Apple entitlement 与系统扩展授权，不属于当前版本能力。

## 下载

**AI Lock 正在开发中，当前请从源码构建。**

需要 macOS 14 (Sonoma) 或更高版本，Apple Silicon 与 Intel 通用。

当前开发构建为临时签名，不代表已完成正式发布公证。

## 安装与授权

1. 运行 `./build.sh` 构建 `build/AILock.app`。
2. 启动 AI Lock。主窗口显示资源总览，菜单栏提供状态和 Dock 锁定入口。
3. 首次启动会请求辅助功能授权，用于保留的 Dock 固定功能。只使用资源总览时无需此权限。

> 辅助功能权限只用于 Dock 固定能力，不是资源监控的前置条件。未授权时资源仪表盘仍可使用。

## 使用

点菜单栏图标：

| 菜单项 | 说明 |
| --- | --- |
| **启用 Dock 锁定** | 临时开关。想让 Dock 自由活动一会儿就关掉它 |
| **Dock 固定在…** | 选哪块屏。默认「自动（主屏优先）」 |
| **开机自启** | 注册为登录项，开机自动运行 |
| **退出 AI Lock** | 退出 |

「Dock 固定在…」子菜单里，✓ 表示你手动指定的屏幕，– 表示自动模式下当前实际选中的那块。插拔显示器后菜单会自动刷新。

改完目标屏不用自己去搬 Dock，巡检会发现它不在新目标屏，一秒内自动拽过去。

## 工作原理

两道防线：

**1. 边缘钳制** —— 在非目标屏的 Dock 触发边上立一道"隐形墙"。鼠标事件经过时把坐标钳住，指针进不去触发区，Dock 自然就不搬家。

墙的默认厚度是 6pt。这个值需要现场标定：太薄拦不住（Dock 的触发热区比想象中厚），太厚会觉得屏幕底部够不到。

**2. 自动拽回** —— 快速甩动鼠标、或者相邻屏放行区这类情况下 Dock 还是可能溜走。所以每 0.6 秒巡检一次 Dock 的实际位置，发现跑偏就把光标瞬移到目标屏底边，合成一串鼠标微动事件把 Dock 叫回来，再把光标放回原处。

拽回操作只在鼠标静止 0.5 秒后才执行，不会打断你正在进行的操作；连续拽不动会自动降频退避，不会空转。

## 高级配置

所有参数都存在 `UserDefaults`，改完 3 秒内自动生效，不用重启：

```bash
# 隐形墙厚度（点）。拦不住就调大，觉得够不到屏幕底部就调小
defaults write com.laogu.ailock edgeMargin -int 24

# 第二道防线开关
defaults write com.laogu.ailock autoSnap -bool true

# 目标屏：builtin（内置屏）| main（主屏）| 具体的显示器 ID 数字
defaults write com.laogu.ailock targetDisplay -string builtin

# 详细日志，标定墙厚度时打开
defaults write com.laogu.ailock verboseLog -bool true
```

日志在 `~/Library/Logs/AILock.log`。

## 从源码构建

当前使用原生 Swift/AppKit 多文件架构，不需要 Xcode 工程：

```bash
./build.sh          # 开发构建：临时签名，编完即用
./install.sh        # 装到 ~/Applications 并注册开机自启（开发用）
```

出正式的公证 DMG（需要 Developer ID 证书和公证凭据，见 `release.sh` 顶部注释）：

```bash
VERSION=1.0 BUILD_NUM=1 ./release.sh
```

| 文件 | 作用 |
| --- | --- |
| `AppDelegate.swift` | 应用入口、菜单栏与 DockLock 模块接入 |
| `DockController.swift` | 原 Dock 固定功能 |
| `DashboardWindow.swift` | AI Lock 主窗口与资源总览 UI |
| `SystemMonitor.swift` | CPU、内存、磁盘与整机网络采样 |
| `LogStore.swift` | Unified Logging 查询 |
| `ProcessMonitor.swift` | 进程采样与保护规则 |
| `ResourceAlerts.swift` | 本机资源阈值预警 |
| `QuickSearch.swift` | 应用与 Spotlight 文件搜索 |
| `ClipboardHistory.swift` | Keychain 加密的本地剪贴板历史 |
| `NetworkInspector.swift` | TCP 连接元数据视图 |
| `SecurityExtensionStatus.swift` | Endpoint Security / packet capture 能力状态 |
| `HardwareInfo.swift` | 系统设备与电源信息 |
| `makeicon.swift` | 现画 1024 图标，构建时生成 icns |
| `probe.swift` | 排查用：打印屏幕拓扑和 Dock 实际位置 |
| `build.sh` | 构建 .app |
| `install.sh` | 本地安装（开发用） |
| `release.sh` | 签名 → 公证 → 打 DMG → 装订 |

## 卸载

菜单里关掉「开机自启」，退出 AI Lock，然后把 AI Lock 拖进废纸篓。

如果之前用过旧版 DockLock 的 `install.sh`：

```bash
launchctl bootout gui/$(id -u)/com.laogu.docklock
rm -rf ~/Applications/DockLock.app ~/Library/LaunchAgents/com.laogu.docklock.plist
```

## 许可证

[MIT](LICENSE) © 2026 老谷 laoguzhe@gmail.com
