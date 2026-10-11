import Foundation
import Security

@objc(AILockAuditIPC) protocol AILockAuditIPC {
    func configure(root: String?, reply: @escaping (Bool, String) -> Void)
    func fetch(after cursor: String, reply: @escaping (Data?, String?) -> Void)
}

enum AuditIPCIdentity {
    static let bundleID = "com.laogu.ailock.auditprototype"
    static func team() -> String? {
        var dynamic: SecCode?; var code: SecStaticCode?; var info: CFDictionary?
        guard SecCodeCopySelf([], &dynamic) == errSecSuccess, let dynamic,
              SecCodeCopyStaticCode(dynamic, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              team.count == 10, team.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789").contains($0) }) else { return nil }
        return team
    }
    static func requirement(bundleID: String, team: String) -> String {
        "identifier \"\(bundleID)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}
