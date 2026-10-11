import Foundation

struct SecurityExtensionStatus {
    let title: String
    let detail: String
    let isInstalled: Bool

    static var endpointSecurity: SecurityExtensionStatus {
        SecurityExtensionStatus(title: "全量文件审计未启用",
                                detail: "需要 Apple 批准 Endpoint Security entitlement，并通过 System Extension 安装和用户批准。当前主应用没有安装或启用审计扩展，不能监控全机文件读写；开发原型需独立授权与验收。",
                                isInstalled: false)
    }

    static var packetCapture: SecurityExtensionStatus {
        SecurityExtensionStatus(title: "原始网络包捕获未启用",
                                detail: "连接允许/阻断应使用 Network Extension Content Filter；当前构建没有过滤扩展。Packet Tunnel 用于自定义 VPN，不作为普通防火墙替代。",
                                isInstalled: false)
    }
}
