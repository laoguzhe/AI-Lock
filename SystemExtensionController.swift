import Foundation
import SystemExtensions
import Security
import NetworkExtension
import Combine

final class SystemExtensionController: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    static let shared = SystemExtensionController()
    @Published private(set) var status = "尚未查询系统扩展"
    @Published private(set) var busy = false
    private var request: OSSystemExtensionRequest?
    static func preflight(bundleID: String) -> String? {
        let audit = bundleID == AuditIPCIdentity.bundleID
        let directory = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
              let url = urls.first(where: { $0.pathExtension == "systemextension" && Bundle(url: $0)?.bundleIdentifier == bundleID }) else {
            return "此构建未嵌入匹配的系统扩展，请使用已授权的扩展构建"
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { return "扩展签名验证失败" }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any], values[kSecCodeInfoTeamIdentifier as String] as? String != nil else { return "扩展需要有效 Team ID 签名和能力授权，不能使用临时签名" }
        guard let extensionTeam = values[kSecCodeInfoTeamIdentifier as String] as? String,
              let extensionEntitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              (audit ? extensionEntitlements["com.apple.developer.endpoint-security.client"] as? Bool == true : (extensionEntitlements["com.apple.developer.networking.networkextension"] as? [String])?.contains("content-filter-provider-systemextension") == true) else { return "扩展签名缺少所需能力" }
        var host: SecCode?
        var hostInfo: CFDictionary?
        var hostStatic: SecStaticCode?
        guard SecCodeCopySelf([], &host) == errSecSuccess, let host,
              SecCodeCopyStaticCode(host, [], &hostStatic) == errSecSuccess, let hostStatic,
              SecCodeCopySigningInformation(hostStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &hostInfo) == errSecSuccess,
              let hostValues = hostInfo as? [String: Any],
              hostValues[kSecCodeInfoTeamIdentifier as String] as? String == extensionTeam,
              let hostEntitlements = hostValues[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              hostEntitlements["com.apple.developer.system-extension.install"] as? Bool == true,
              (audit || (hostEntitlements["com.apple.developer.networking.networkextension"] as? [String])?.contains("content-filter-provider-systemextension") == true) else { return "主应用签名与扩展不匹配，或缺少安装 / 网络能力" }
        if !audit {
            let group = extensionTeam + ".com.laogu.ailock.filterprototype"
            guard (extensionEntitlements["com.apple.security.application-groups"] as? [String])?.contains(group) == true,
                  (hostEntitlements["com.apple.security.application-groups"] as? [String])?.contains(group) == true,
                  (Bundle(url: url)?.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any])?["NEMachServiceName"] as? String == group else {
                return "过滤健康服务缺少匹配的应用组或服务名，请重新配置并签名"
            }
        }
        return nil
    }
    func queryAudit() { submit(OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: AuditIPCIdentity.bundleID, queue: .main)) }
    func activateAudit() {
        if let failure = Self.preflight(bundleID: AuditIPCIdentity.bundleID) { status = failure; return }
        submit(OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: AuditIPCIdentity.bundleID, queue: .main))
    }
    func deactivateAudit() {
        AuditExtensionClient.shared.stop()
        submit(OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: AuditIPCIdentity.bundleID, queue: .main))
    }
    func queryFilter() { submit(OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: ContentFilterConfiguration.bundleID, queue: .main)) }
    func activateFilter() {
        if let failure = Self.preflight(bundleID: ContentFilterConfiguration.bundleID) { status = failure; return }
        submit(OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: ContentFilterConfiguration.bundleID, queue: .main))
    }
    func deactivateFilter() {
        guard !busy, !ContentFilterConfiguration.shared.busy else { status = "请等待过滤配置操作完成"; return }
        busy = true; status = "正在确认过滤配置已停用…"
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { [self] error in
            DispatchQueue.main.async {
                self.busy = false
                if let error { self.status = "无法确认过滤器已停用：\(error.localizedDescription)"; return }
                if manager.isEnabled && manager.providerConfiguration?.filterDataProviderBundleIdentifier == ContentFilterConfiguration.bundleID {
                    self.status = "请先停用过滤配置，再移除扩展"; return
                }
                self.submit(OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: ContentFilterConfiguration.bundleID, queue: .main))
            }
        }
    }
    private func submit(_ newRequest: OSSystemExtensionRequest) {
        guard !busy else { return }; busy = true; status = "等待系统处理…"; request = newRequest
        newRequest.delegate = self; OSSystemExtensionManager.shared.submitRequest(newRequest)
    }
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) { guard self.request === request else { return }; status = "等待用户在系统设置批准扩展" }
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        guard existing.bundleIdentifier == ext.bundleIdentifier else { return .cancel }; return .replace
    }
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        guard self.request === request else { return }
        busy = false; self.request = nil
        status = result == .willCompleteAfterReboot ? "系统将在重启后完成请求" : "系统请求已完成；请查询状态确认扩展是否启用"
    }
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) { guard self.request === request else { return }; busy = false; self.request = nil; status = "系统扩展请求失败：\(error.localizedDescription)" }
    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        guard self.request === request else { return }
        busy = false; self.request = nil
        status = properties.isEmpty ? "系统未找到此扩展" : properties.map { "\($0.bundleIdentifier)：" + ($0.isUninstalling ? "正在卸载" : $0.isAwaitingUserApproval ? "等待批准" : $0.isEnabled ? "已启用" : "未启用") }.joined(separator: "\n")
    }
}
