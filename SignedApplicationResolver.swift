import Foundation
import Security
import Darwin

/// Audit-token lookup binds code identity to this flow's original process, without a reusable PID.
enum SignedApplicationResolver {
    static func selectedApplication(_ url: URL) throws -> SignedApplicationIdentity {
        guard url.pathExtension == "app", Bundle(url: url) != nil else { throw ExactHostPolicy.Failure("请选择应用程序 .app") }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              let requirement = appleRequirement(), SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess,
              let identity = identity(code) else { throw ExactHostPolicy.Failure("此应用缺少有效开发团队签名，不能建立可靠身份规则") }
        return try identity.validated()
    }
    static func flowApplication(auditToken: Data?) -> SignedApplicationIdentity? {
        guard let auditToken, auditToken.count == MemoryLayout<audit_token_t>.size else { return nil }
        var guest: SecCode?; var code: SecStaticCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: auditToken] as CFDictionary, [], &guest) == errSecSuccess, let guest,
              let requirement = appleRequirement(), SecCodeCheckValidity(guest, [], requirement) == errSecSuccess,
              SecCodeCopyStaticCode(guest, [], &code) == errSecSuccess, let code,
              let identity = identity(code) else { return nil }
        return try? identity.validated()
    }
    private static func appleRequirement() -> SecRequirement? {
        var value: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &value) == errSecSuccess else { return nil }; return value
    }
    private static func identity(_ code: SecStaticCode) -> SignedApplicationIdentity? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any], let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String else { return nil }
        return SignedApplicationIdentity(identifier: identifier, teamID: team)
    }
}
