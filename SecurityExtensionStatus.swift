import Foundation

struct SecurityExtensionStatus {
    let title: String
    let detail: String
    let isInstalled: Bool

    static var endpointSecurity: SecurityExtensionStatus {
        SecurityExtensionStatus(title: "全量文件审计未启用",
                                detail: "需要 Apple 批准 Endpoint Security entitlement，并通过 System Extension 安装和用户批准。目前此构建没有扩展目标，不能监控全机文件读写。",
                                isInstalled: false)
    }

    static var packetCapture: SecurityExtensionStatus {
        SecurityExtensionStatus(title: "原始网络包捕获未启用",
                                detail: "需要 Network Extension entitlement 与 Packet Tunnel 扩展。该模式会接管/路由流量，不是被动旁路抓包。",
                                isInstalled: false)
    }
}
