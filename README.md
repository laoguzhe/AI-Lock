# AI Lock

AI Lock 是原生 Swift/AppKit macOS 本机资源监控和维护工具，包含多显示器 Dock 固定功能。需要 macOS 14 或更高版本。

## 当前功能与边界

| 功能 | 当前能力 |
| --- | --- |
| 资源总览与预警 | CPU、内存、磁盘、整机网络采样；关闭总览后仍后台判断预警，提醒冷却 5 分钟 |
| 进程管理 | 查看资源、监听端口与进程网络速率；正常退出/强制结束前复核进程身份，批量退出仅处理当前用户正常应用 |
| 网络诊断 | 首页独立入口；上传/下载/延迟、多节点与接口对比、DNS、路由追踪、网段配置、Ping 丢包/抖动、TCP 端口、IPv6、报告复制与导出 |
| 网络活动 | TCP/UDP 连接与变化合并展示；支持应用/PID/IP/端口搜索、协议与范围筛选、概览、详情、CSV 导出、应用分组及汇总网络速率 |
| 应用日志 | 仅查询 AI Lock 当前进程的 Unified Logging 日志，不是全系统日志 |
| 快速搜索 | 搜索本机应用与 Spotlight 可索引文件；包含 `/Applications` 与用户应用目录 |
| 剪贴板历史 | 首次打开剪贴板模块后开始采集；可暂停、选择应用排除及恢复采集；多对象还原、Keychain 密钥与逐记录 AES-GCM 加密的 SQLite 存储；旧加密 JSON 验证迁移；后台首批读取、40 条分页解密、后台全历史搜索（最多显示 100 个匹配）；保留 1–30 天，上限 500 条/64 MiB，单次复制上限 8 MiB |
| 用户缓存检查 | 扫描缓存并确认清理；缓存由应用维护，建议先退出对应应用 |
| 应用卸载 | 用户/本机第三方应用及可识别关联项；关联路径逐项选择，移入废纸篓；系统应用不在卸载范围 |
| 启动项检查 | 查看 LaunchAgents/LaunchDaemons 配置及异常诊断；右键提供修复建议；无法解析或执行程序不存在的用户配置可确认后备份移走，操作前复核内容，完成后重新扫描；运行状态未验证，移走配置不等于立即停止服务 |
| DockLock | 在非目标显示器边缘钳制鼠标，并在空闲时自动拽回 Dock；真实鼠标移动会取消正在进行的拽回 |
| 显示器控制 | 可选模块；向 Apple Silicon 识别到的外接 DDC 通道发送统一亮度值；不读取当前亮度，不支持部分 HDMI/扩展坞连接及 Intel Mac |
| 屏幕遮罩 | 黑色视觉遮罩，至少保留一块屏幕可见；`⌘⌃⇧Esc` 解除全部遮罩，不等于关闭屏幕或阻止屏幕读取 |

文件活动页以全机程序访问审计为核心，不再提供重复搜索、目录分析或磁盘统计。支持程序、操作和敏感路径筛选，完整路径详情、暂停显示及 JSON 导出。AI 和敏感标签均为启发式规则；OPEN 不代表已读取正文，CLOSE.modified 不代表逐次 write。默认关注 AI 敏感事件，以“哪个 AI / 发生了什么 / 如何处理”组织详情；支持应用、时间及待核实筛选、人工核实、定位、复制与进程/网络入口。本地历史保留最近 7 天、最多 10000 条并提示缺口，可清空；路径和元数据以用户专属权限保存，不含文件正文。真实采集需要获批 Endpoint Security 能力、签名系统扩展和用户授权；默认构建不嵌入扩展。功能与边界见 [文件活动说明](docs/文件活动.md)，打包及授权见 [扩展说明](extensions/README.md)。

文件活动页另提供 Agent Hooks 接入，可在不申请 Endpoint Security 权限的情况下，记录 Claude Code、Codex 和 Cursor 经其 hooks 触发的会话、工具、路径或命令及完成/失败/阻止状态；本机 SQLite 保存事件元数据，不保存文件内容和工具输出。可配置敏感路径写入拦截和危险命令片段规则。该方式只覆盖实际经过 hooks 的工具调用，不是全机行为审计。首次接入后需重启对应 Agent。

网络活动每 5 秒采样。当前连接视图会将刚结束的连接保留 30 秒；最近变化展示近 60 秒的新增、结束和状态变化；全部记录保留本页面会话中最多 1,000 条已结束记录及所有当前连接。首次采样和恢复采样使用基线，暂停期间的实际变化时间未知。连接详情按需查询反向 DNS，并可复制地址、查看进程文件或导出当前筛选结果。上传/下载速率按进程去重汇总，缺失数据不会显示为零；端口服务名称仅作提示，轮询可能遗漏短连接。

整机网络速率按各网卡增量计算，使用单调时钟；新网卡、计数复位和读取失败后重新建立基线。当前排除回环、utun、awdl、llw 接口以避免常见重复计数；累计字节是当前纳入接口的系统计数，不是应用会话累计流量。

剪贴板会过滤常见 confidential/transient 标志，但采样时前台应用不一定就是复制来源；不能保证识别所有密码或敏感内容。历史默认不上传。旧版加密历史格式可继续读取，旧记录中已丢失的多对象内容不能恢复。

## 构建与验证

```bash
./build.sh                              # 本机架构开发构建
AILOCK_ARCHS='arm64 x86_64' ./build.sh    # 通用开发构建
./tests/run.sh                          # 隔离临时目录、独立剪贴板和测试配置的回归检查
swift test                              # 核心 XCTest
./tests/index-integration/run.sh         # 真实目录事件与历史补回
./tests/ipc-protocol/run.sh              # 匿名 NSXPC 传输检查，非 ES 授权检查
./install.sh                            # 安装到 ~/Applications，统一使用 SMAppService 注册登录项
```

开发构建优先选用可用的 Apple Development 证书；可设置 `DEV_SIGN_ID` 指定证书。没有开发证书时回退 ad-hoc 签名，签名身份改变后系统可能要求重新授予辅助功能权限。安装脚本不再无条件重置权限。

正式发布需要 Developer ID 证书和已配置的公证凭据：

```bash
VERSION=1.2 BUILD_NUM=3 ./release.sh
```

发布构建默认生成 arm64/x86_64 通用二进制，最低系统版本为 macOS 14；`AILOCK_ARCHS` 可显式覆盖目标架构。开发签名产物未经过发布公证。

首次打开会显示菜单栏总览。资源监控不要求辅助功能权限；DockLock 使用辅助功能权限，双击 Command 入口可能需要输入监控权限。通知由 macOS 单独管理。

## 快捷键与 Dock 配置

在快捷键设置中配置 `⌘⌃1–9`；快捷操作可选双击 Command 或 `⌘⌃⌥Space`。快速文件搜索默认 `⌥Space`，可在监控预警设置调整。快捷键冲突会显示注册失败信息。

```bash
defaults write com.laogu.ailock edgeMargin -float 6.5
defaults write com.laogu.ailock autoSnap -bool true
defaults write com.laogu.ailock targetDisplay -string builtin  # builtin | main | 显示器 ID
defaults write com.laogu.ailock verboseLog -bool true
```

配置约 3 秒内重新加载；目标显示器变化会重新计算实际目标。边缘厚度限制为 1–100 pt。文件日志位于 `~/Library/Logs/AILock.log`，超过约 1 MiB 后保留一份滚动备份。

## 主要模块

- `AppDelegate.swift`：应用入口、菜单栏与登录项。
- `MonitoringService.swift` / `SystemMonitor.swift` / `ResourceAlerts.swift`：常驻采样、快照与预警。
- `AppSupport.swift`：应用目录、配置校验、键码与有超时的后台命令执行。
- `DashboardWindow.swift`：窗口路由、设置和其他 UI；四个主要模块见 `ClipboardModuleController.swift`、`FilesModuleController.swift`、`ProcessesModuleController.swift`、`NetworkModuleController.swift`。
- `AppSettings.swift`：类型化核心配置及 schema 2 迁移；模块显示、排序与快捷键保存稳定标识。
- `DirectoryIndex.swift`：所选目录的持久元数据索引与事件游标。
- `SystemExtensionController.swift` / `ContentFilterConfiguration.swift` / `AuditExtensionClient.swift`：扩展请求、过滤配置事务及审计 IPC。
- `ClipboardHistory.swift`：共享历史、多对象保存还原与加密存储。
- `ProcessMonitor.swift` / `ProcessNetworkMonitor.swift` / `NetworkInspector.swift`：进程、nettop 与 TCP 采样。
- `MaintenanceTools.swift` / `CacheCleaner.swift`：卸载、启动项、文件和缓存检查。
- `QuickSearch.swift` / `LogStore.swift` / `HardwareInfo.swift`：搜索、应用日志与设备信息。

审查基线、替代方案与落地边界见 `docs/`，本轮记录为 `docs/方案落地记录-2026-10-09.md`。硬件传感器、完整审计与更大范围 UI/服务拆分仍需后续开发。

## 卸载

在设置中关闭“开机自启动”，退出 AI Lock，再将应用移入废纸篓。旧 LaunchAgent 安装方式会由新版安装脚本迁移。

## 许可证

[MIT](LICENSE) © 2026 老谷 laoguzhe@gmail.com

开发原型可用 `./extensions/build-prototypes.sh` 编译；Xcode 工程为 `AILock.xcodeproj`。原型构建不安装或启用系统扩展。文件页渲染检查可运行 `./tests/ui/run.sh`，会短暂显示隔离测试窗口，禁用生产快捷键并注入独立剪贴板依赖。

缓存内容及卸载项以确认前的操作计划移入废纸篓，结果逐项反馈；正在运行的卸载目标须先退出。新网络历史按观察时长聚合，休眠等长采样空档显示为缺失区间。

剪贴板页隔离渲染及分页按钮检查：`./tests/ui/run.sh /tmp/ailock-clipboard-ui.png clipboard`。测试使用临时数据库与测试密钥。

最新建议核对和未完成项见 [建议落实核对](docs/建议落实核对-2026-10-09.md)。合成剪贴板性能测量：`./tests/benchmark/run.sh`，不使用真实历史或钥匙串。

本次继续完成与剩余验收见 [继续完成记录](docs/继续完成记录-2026-10-09.md)。

启动项修复备份位于 `~/Library/Application Support/AILock/StartupItemBackups/`，每次操作独立保存原始 plist 和 `original-path.txt`。恢复时将 plist 复制回记录的原路径，再通过所属应用重新启用。系统配置、符号链接及权限问题不自动修改。

AI 工具本机访问审计的竞品、源码入口、缺失能力与本轮补强见 [同类工具对比与审计补强](docs/同类工具对比与审计补强-2026-10-09.md)。

双击 Command 现在打开独立快捷操作条：连续两次短按并松开 Command，间隔不超过 0.45 秒。支持操作名称搜索、上下键选择、回车执行、Esc 关闭；最近使用操作保存在本机并优先展示。长按、组合键和其他修饰键会取消手势。全局监听使用只读事件 tap；若权限不足，可在快捷键设置点击输入监控授权入口，监听会自动重试。

## 统一悬浮搜索

双击 Command 的搜索条现在接入真实搜索引擎，而非仅过滤内置操作名。输入名称即可同时查找应用、文件、文件夹及快捷操作；结果显示类型与完整路径。Return 打开，⌘Return 在 Finder 中显示，上下键选择；再次双击 Command 或 Esc 隐藏。

网址如 `example.com`、`https://example.com/path` 会显示“打开网页”，Return 用默认浏览器打开。输入 `> ls -la` 会显示“在终端执行”，Return 才打开 Terminal 执行；普通搜索文本不会自动执行命令。终端命令不记入最近搜索；临时执行文件权限为 0700，启动后自行删除。默认在用户主目录以 zsh 登录环境运行。

文件搜索仍遵守完全磁盘访问授权：无权限时保留应用及操作搜索，并提供统一的授权入口。Spotlight 的本机元数据索引负责普通文件与文件夹查询；应用由独立应用目录缓存提供。为刚创建或暂未进入索引的常用内容，后台另缓存 Documents/项目、Documents、Desktop、Downloads 四个目录的名称，忽略隐藏项、包内部及 node_modules/vendor/Pods/DerivedData/缓存，最多 4 层、40,000 项。此缓存只在启动预热或目录结构变化后更新，输入过程只过滤已缓存名称，不扫描整盘；深层或排除目录由 Spotlight 覆盖，未被系统索引的内容仍可能搜不到。查询使用 180 ms 防抖，Spotlight 与缓存结果合并后按匹配度排序。

验证：`AILOCK_VERIFY_SEARCH_DIRECTORY=/Users/guzhe/Documents/项目/juece ./tests/quick-search/run.sh`；`./tests/ui/run.sh /tmp/ailock-unified-search.png launcher-search`。这些检查不打开网页或执行用户的终端命令。

## 网络诊断

首页的“网络诊断”独立于网络活动和系统健康检查。系统健康检查仅保留磁盘与内存性能测试。点击“开始全面网络诊断”即可依次完成五类检查，结果逐步显示在地图与紧凑图表组成的单屏仪表盘中，无需切换标签页或下拉。上传下载测速首先执行并实时更新仪表，完成后再执行其他检查；可随时取消并保留已完成的结果。

- 上传下载测速使用 macOS `networkQuality`（每条线路约 30 秒），显示下载、上传、空闲延迟与负载响应能力。
- 多节点默认提供清华镜像、阿里云镜像、Cloudflare、OVH 法国；每节点顺序下载最多 4 MiB，支持上传的节点额外 POST 2 MiB 测试数据。支持自定义 HTTP/HTTPS 下载和上传端点。镜像样本不代表宽带峰值；CDN 实际位置可能就近，报告展示连接 IP，VPN 或透明代理可能使其不同于源站 IP。Cloudflare 端点参见其[官方测速项目](https://github.com/cloudflare/speedtest)。
- 可指定本机接口或逐条比较接口。指定接口的 HTTP 测试绑定接口并绕过 HTTP 代理；VPN 隧道仍可能影响选路。无法绑定接口会显示失败，不静默切回默认线路；DNS 仅绑定源 IP，出口由系统路由决定。
- DNS 比较系统解析器与阿里、腾讯、Cloudflare、Google 公共 DNS，可添加自定义服务器；路由追踪最多 16 跳；Ping 显示 6 次探测的丢包与延迟标准差。中间路由和目标可能屏蔽探测，不响应不代表断网。
- 本机检查展示 IPv4/IPv6、子网掩码、网关、DNS、代理、隧道、路由表和已有 ARP 邻居，核查自分配地址、本机重复 IP、网段重叠、默认网关所在网段。不修改配置、不扫描全网，也不能排除其他设备的 IP 冲突。
- TCP 只检查输入的单个端口；IPv6 通过 HTTPS 验证联网。结果可复制或导出为文本报告。测试通过直接参数调用系统工具，有超时、取消和临时文件清理。

网络诊断采用工业仪表盘，支持浅色、深色及跟随系统外观：实时更新的紧凑测速仪表（读取测速工具的实际过程数据，结束后显示最终结果）、34 个省级地区延时地图与 4 个海外节点卡片、DNS 响应图、路由跳点及延迟图、Ping 与 TCP/IPv6 状态、本机 IP/子网、网关与公网出口 IP 摘要。顶部合并目标、线路、参数和测试控制，完整接口、原始数据及说明按需打开详情。参考 [Cloudflare Speed Test](https://speed.cloudflare.com/) 的指标布局和 [PingPlotter](https://www.pingplotter.com/fix-your-network/getting-started/timeline-graphs/) 的延迟图表达方式。图表使用真实测试数据，缺失响应保留空缺；完成测速历史仅记录当前窗口会话的已完成结果。每轮全面诊断替换上一轮结果，测速历史继续保留。卡片右上角可打开完整测量详情，多线路结果通过顶部线路选择器切换。

地区地图的节点来源、测量方式及限制见 [地区延时地图说明](docs/network-latency-map.md)。

DNS 对比现在使用三次真实查询中位数，并提供成功率、AAAA 与不存在域名检查；开源参考与适配边界见 [测速开源项目评估](docs/network-open-source-review.md)。
