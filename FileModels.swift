import Foundation
import Darwin

struct AnalyzedFile: Identifiable {
    let url: URL
    let size: Int64
    var id: String { url.path }
}

struct StorageCategory: Identifiable {
    let name: String
    let size: Int64
    let count: Int
    var id: String { name }
}


enum FilesystemPath {
    /// Resolve ancestors while keeping a changed leaf itself, including a new symlink.
    static func eventLocation(_ url: URL) -> URL {
        guard url.path != "/" else { return url }
        return canonical(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent)
    }

    static func canonical(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            missing.append(existing.lastPathComponent); existing.deleteLastPathComponent()
        }
        let resultPath: String
        if let resolved = realpath(existing.path, nil) {
            resultPath = String(cString: resolved); free(resolved)
        } else { resultPath = existing.resolvingSymlinksInPath().path }
        var result = URL(fileURLWithPath: resultPath)
        for component in missing.reversed() { result.appendPathComponent(component) }
        return result
    }
}

/// Path-only hints: never reads content or resolves a path against the current filesystem.
enum AuditPathRules {
    static func sensitiveReason(path: String, destination: String? = nil) -> String? {
        for candidate in [path, destination].compactMap({ $0 }) {
            let components = candidate.lowercased().split(separator: "/").map(String.init)
            let name = components.last ?? ""
            if components.contains(".ssh") || components.contains(".gnupg") { return "密钥目录" }
            if components.contains("keychains") { return "钥匙串目录" }
            if components.contains(".aws") || components.contains(".azure") || components.contains(".kube") ||
                components.contains(".docker") || zip(components, components.dropFirst()).contains(where: { $0 == ".config" && $1 == "gcloud" }) {
                return "云服务 / 容器凭据目录"
            }
            if [".git-credentials", ".netrc", ".npmrc", ".pypirc", "credentials", "id_rsa", "id_ed25519"].contains(name) ||
                name == ".env" || name.hasPrefix(".env.") { return "可能含凭据" }
            let browserRoot = candidate.lowercased()
            let browser = browserRoot.contains("/library/application support/google/chrome/") ||
                browserRoot.contains("/library/application support/microsoft edge/") ||
                browserRoot.contains("/library/application support/bravesoftware/brave-browser/") ||
                browserRoot.contains("/library/application support/firefox/profiles/") ||
                browserRoot.contains("/library/safari/") || browserRoot.contains("/library/cookies/")
            let databases = ["login data", "cookies", "cookies.binarycookies", "history", "history.db", "logins.json", "key4.db", "cookies.sqlite", "places.sqlite", "web data"]
            if browser && databases.contains(where: { name == $0 || name == $0 + "-wal" || name == $0 + "-shm" }) {
                return "浏览器登录 / 会话 / 历史数据"
            }
            if ["pem", "key", "p12", "pfx"].contains(URL(fileURLWithPath: candidate).pathExtension.lowercased()) { return "证书 / 私钥文件" }
        }
        return nil
    }
}

/// Heuristic labels aid review; they do not prove application identity or content disclosure.
struct FileAuditRecord: Identifiable, Codable {
    let id: UUID
    let date: Date
    let kind: String
    let operation: String
    let pid: String
    let executable: String
    let path: String
    let destination: String?
    var application: String {
        let parts = executable.split(separator: "/").map(String.init)
        if let app = parts.first(where: { $0.lowercased().hasSuffix(".app") }) { return String(app.dropLast(4)) }
        return URL(fileURLWithPath: executable).lastPathComponent
    }
    var isAI: Bool {
        let value = (executable + " " + (processMetadata["signingID"] ?? "")).lowercased()
        return ["chatgpt", "claude", "codex", "cursor", "windsurf", "ollama", "lm studio", "lmstudio", "copilot", "gemini", "trae"].contains { value.contains($0) }
    }
    var aiEvidence: String { isAI ? "程序路径或签名标识匹配 AI 规则（推测）" : "未匹配 AI 规则；不能排除 AI 子进程" }
    var explanation: String {
        switch kind {
        case "open": return "系统报告文件被打开；不代表读取了正文，也不能证明上传。"
        case "write": return "系统报告写入事件；记录不包含写入内容。"
        case "close": return operation == "修改后关闭" ? "系统报告关闭时文件有修改。" : "关闭事件未报告修改；不能据此判断是否读取。"
        case "unlink": return "系统报告移除文件路径；历史记录不能恢复被删除的文件。"
        case "rename": return "系统报告重命名或移动；源路径和目标路径都参与敏感判断。"
        case "create": return "系统报告文件创建事件；记录不包含文件正文。"
        default: return "系统文件事件；需结合进程身份核实。"
        }
    }
    var sensitiveReason: String? { AuditPathRules.sensitiveReason(path: path, destination: destination) }
    let processMetadata: [String: String]
    init?(_ payload: [String: Any]) {
        guard let kind = payload["kind"] as? String, let path = payload["path"] as? String,
              let executable = payload["executable"] as? String, let timestamp = payload["receivedAt"] as? Double else { return nil }
        self.id = (payload["eventID"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(); self.kind = kind; self.path = path; self.executable = executable; self.date = Date(timeIntervalSince1970: timestamp)
        self.pid = String(describing: payload["pid"] ?? "?"); self.destination = payload["destinationPath"] as? String
        var metadata: [String: String] = [:]
        for key in ["pidVersion", "parentPID", "signingID", "teamID", "codeSigningFlags", "platformBinary", "openFlags"] {
            if let value = payload[key] { metadata[key] = String(describing: value) }
        }
        self.processMetadata = metadata
        switch kind {
        case "open": operation = "打开（可能读取）"
        case "close": operation = payload["modified"] as? Bool == true ? "修改后关闭" : "关闭（未报告修改）"
        case "create": operation = "创建事件"
        case "write": operation = "写入事件"
        case "unlink": operation = "删除"
        case "rename": operation = "重命名 / 移动"
        default: operation = kind
        }
    }
}
