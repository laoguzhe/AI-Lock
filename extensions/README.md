# AI Lock 扩展开发与授权构建

默认 `build.sh` 只构建主应用，不嵌入、安装或启用扩展。设置的“系统扩展”页面提供显式安装/更新、查询及移除；没有有效团队签名和匹配能力的构建会拒绝安装。测试没有改变真实网络配置或安装系统扩展。

## 编译与可选打包

```sh
./extensions/build-prototypes.sh
```

产出 Apple Silicon（arm64）原型；Xcode 工程包含 AILock、AuditPrototype 和 FilterPrototype。编译通过不代表系统授权通过。

已有获批配置文件和匹配 Developer ID 身份时，可先构建主应用，再选择打包：

```sh
AILOCK_HOST_PROFILE=/absolute/host.provisionprofile \
AILOCK_FILTER_PROFILE=/absolute/filter.provisionprofile \
SIGN_ID='Developer ID Application: your identity' ./extensions/package-filter.sh

AILOCK_HOST_PROFILE=/absolute/host.provisionprofile \
AILOCK_AUDIT_PROFILE=/absolute/audit.provisionprofile \
SIGN_ID='Developer ID Application: your identity' ./extensions/package-audit.sh
```

脚本校验准确 Bundle ID、能力、到期时间、相同 Team ID、签名证书是否属于两个 profile，编译并嵌入对应 `.systemextension`，再签名主应用。同时嵌入两个扩展时，host profile 必须保留两者需要的能力。脚本不安装、不激活，也不申请 Apple 能力；真实授权 profile 的打包尚未执行。正式分发还需沿发布流程公证。

## Endpoint Security

仅订阅 NOTIFY_OPEN/CLOSE/CREATE/WRITE/UNLINK/RENAME，不订阅 AUTH，不读取正文、不阻断访问。OPEN/CLOSE.modified 不能解释为每次 read/write 调用。重命名包含来源与目标路径，跨目录移入/移出也会匹配。

CLI 模式仍需显式绝对目录，向 stdout 输出 JSON Lines；有界异步写入最多 500 条等待记录，输出失败会停止写入。退出不等待阻塞的 stdout。

系统扩展模式无 CLI 参数，通过 `NSEndpointSecurityMachServiceName` 的 NSXPC 服务收取目录配置。主应用和扩展双向设置同一 Team ID、准确 Bundle ID 与 Apple 签名链 requirement，macOS 检查每条消息的签名身份；不使用易复用 PID 作身份认证。未配置目录时不创建 ES 客户端；最后一个会话失效后删除客户端。最多 16 个连接、4 个活动目录会话。

每会话保留最多 500 条内存事件，每次 fetch 至多 100 条，游标和交付缺口以字符串编码。目录切换使旧回调失效并清空窗口。序列缺口按客户端、事件类型、在目录过滤之前检测，是 ES 客户端流诊断，不是所选目录准确丢失数。主应用关闭连接或退出后会停止该会话。交付窗口不跨重启保存，不保证完整可靠审计。

真实运行需要获批 ES 能力、签名、系统批准与所需 Full Disk Access；这些尚未在授权设备验收。匿名 NSXPC 检查仅验证协议与序列化传输，不验证部署服务发现、签名授权或真实 ES 事件。

## Content Filter

NEFilterDataProvider 通过 `vendorConfiguration.policyData` 收取带 UUID 版本的规则；保留旧 `blockedHosts` 配置的读取兼容。至多 256 条全局精确主机/IP 和 128 条应用规则。拒绝通配符、URL、端口及畸形主机；无效配置启动失败。只读取连接元数据，不订阅或解密载荷。

应用规则包含准确签名标识与 10 位 Team ID，可阻断应用所有新连接或指定精确主机。选择 .app 时验证 Apple 签名链和所有架构；运行时用 `sourceAppAuditToken` 查询原始进程的动态签名，避免 PID 复用。身份不能核实时不匹配应用规则，全局主机规则仍生效。未签名或无开发团队标识的应用暂不支持；相同签名身份的不同版本共用规则。socket 端点可能是 IP，规则不保证覆盖域名的 DNS/CDN、代理和辅助进程，也不会主动断开已有连接。

健康 IPC 使用稳定 Objective-C 协议、同团队准确 Bundle ID 双向签名要求和至多 8 个连接。每 5 秒检查一次，3 秒请求超时，核对 running 与规则版本；首次显式保存后的运行规则更新前重新加载系统配置，确认来源、启用状态和 UUID 都匹配。重新连接只检查心跳，不把缓存旧规则写回。应用启动只对已嵌入、具备匹配签名与能力的 NE 构建恢复自己的已有健康监测，不自动安装或启用。

“过滤器故障时优先恢复联网”默认关闭：关闭时保留阻断并提示异常；开启时连续 3 次心跳异常才尝试停用自己的同版本配置，保存后读取复核，保留规则供手动重新启用。网络不可用或休眠打断连续异常计数。扩展另有 30 秒心跳租约：仅选择此选项时，仍在运行但与主应用失联的 provider 放行新连接，正常心跳回来后恢复规则；这不等同于移除系统过滤配置，且不保证 provider/系统自身崩溃时仍可恢复。心跳证明进程响应和规则一致，不能证明实际阻断、VPN 兼容或联网质量。

主应用通过 NEFilterManager 加载原配置、保存后读取核对；失败时检查当前来源、恢复并再次核对。原先未配置时用 removeFromPreferences，停用保留规则，不覆盖其他应用配置。授权和实机验收仍未执行。

健康服务使用 `NetworkExtension.NEMachServiceName = <TEAM>.com.laogu.ailock.filterprototype`。host 与 NE profile/实际签名都需包含同名 `com.apple.security.application-groups`；打包脚本和安装前检查会拒绝缺失项，打包时写入准确服务名。此配置须在开发者账号和真实签名设备验收，不能由本地无签名编译证明。ES 能力目前仍待申请批准，NE 的准备工作不依赖 ES 批准。

受控验收步骤见 [网络扩展验收清单](../docs/网络扩展验收清单.md)。

## 官方接口依据

- [System Extensions](https://developer.apple.com/documentation/systemextensions)
- [OSSystemExtensionRequest](https://developer.apple.com/documentation/systemextensions/ossystemextensionrequest)
- [NEFilterManager](https://developer.apple.com/documentation/networkextension/nefiltermanager)
- [NEFilterProviderConfiguration](https://developer.apple.com/documentation/networkextension/nefilterproviderconfiguration)
- `NSEndpointSecurityMachServiceName` 依据本机 Apple `man EndpointSecurity`；连接签名要求依据 macOS SDK `NSXPCConnection.h` 的公开 `setCodeSigningRequirement`（macOS 13+）。

## 2026-10-09 同类工具参考补强

增加 CREATE 和 WRITE 通知；WRITE 没有正文或字节数，不保证逐次系统调用完整覆盖。CREATE 表示系统交付的创建事件，不能直接作为创建成功证明。CLI 和 IPC 共用订阅清单。

事件详情及导出增加 ES 提供的 pidVersion、父 PID、签名 ID、Team ID、签名标志、平台程序标记和 OPEN 的原始 fflag（不是 POSIX O_* 值）。签名字段不是 AI 身份认证，父 PID 不代表已经建立可靠进程树。

敏感路径增加 Git、包管理器、GCloud、Kubernetes、Docker 和常见浏览器登录/会话/历史数据库及其 WAL/SHM 路径。标签只提示可能敏感，包含样例配置和公钥的误报仍需人工核实。
