import Foundation
import Combine
import SQLite3

enum AgentHookProvider: String, CaseIterable, Identifiable, Hashable {
    case claude = "Claude Code"
    case codex = "Codex"
    case cursor = "Cursor"

    var id: String { rawValue }
    var argument: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .cursor: return "cursor"
        }
    }
    var executable: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .cursor: return "Cursor"
        }
    }
    var configURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        case .codex: return home.appendingPathComponent(".codex/hooks.json")
        case .cursor: return home.appendingPathComponent(".cursor/hooks.json")
        }
    }
}

struct AgentHookRecord: Identifiable {
    let id: String
    let date: Date
    let provider: String
    let sessionID: String
    let callID: String
    let tool: String
    let workingDirectory: String
    let path: String
    let command: String
    let outcome: String
    let decision: String
    let reason: String
}

struct AgentHookPolicy: Codable, Equatable {
    var blockSensitiveWrites = true
    var blockDestructiveCommands = true
    var commandFragments = ["rm -rf /", "git push --force", "git reset --hard"]

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AILock/agent-hook-policy.json")
    }

    static func load() -> AgentHookPolicy {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(AgentHookPolicy.self, from: data) else { return AgentHookPolicy() }
        return value
    }

    func save() throws {
        let directory = Self.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: Self.url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
    }
}

/// Local, metadata-only hook history. Tool output and file contents are never persisted.
private enum AgentHookHistory {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AILock/agent-hook-history.sqlite3")
    }

    private static func database<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw NSError(domain: "AILock.AgentHooks", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法打开 Agent hook 历史数据库"])
        }
        defer { sqlite3_close(pointer) }
        sqlite3_busy_timeout(pointer, 3000)
        guard sqlite3_exec(pointer, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; CREATE TABLE IF NOT EXISTS agent_hook_events (id TEXT PRIMARY KEY, event_date REAL NOT NULL, provider TEXT NOT NULL, session_id TEXT NOT NULL, call_id TEXT NOT NULL, tool TEXT NOT NULL, working_directory TEXT NOT NULL, path TEXT NOT NULL, command TEXT NOT NULL, outcome TEXT NOT NULL, decision TEXT NOT NULL, reason TEXT NOT NULL); CREATE INDEX IF NOT EXISTS agent_hook_events_date ON agent_hook_events(event_date DESC);", nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "AILock.AgentHooks", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(pointer))])
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return try body(pointer)
    }

    static func upsert(_ record: AgentHookRecord) {
        try? database { db in
            let sql = "INSERT INTO agent_hook_events VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET event_date=excluded.event_date, working_directory=CASE WHEN excluded.working_directory='' THEN working_directory ELSE excluded.working_directory END, path=CASE WHEN excluded.path='' THEN path ELSE excluded.path END, command=CASE WHEN excluded.command='' THEN command ELSE excluded.command END, outcome=excluded.outcome, decision=excluded.decision, reason=excluded.reason"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
            defer { sqlite3_finalize(statement) }
            let values = [record.id, record.provider, record.sessionID, record.callID, record.tool,
                          record.workingDirectory, record.path, record.command, record.outcome,
                          record.decision, record.reason]
            sqlite3_bind_text(statement, 1, record.id, -1, transient)
            sqlite3_bind_double(statement, 2, record.date.timeIntervalSince1970)
            for (offset, value) in values.dropFirst().enumerated() {
                sqlite3_bind_text(statement, Int32(offset + 3), value, -1, transient)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else { return }
            sqlite3_exec(db, "DELETE FROM agent_hook_events WHERE id IN (SELECT id FROM agent_hook_events ORDER BY event_date DESC LIMIT -1 OFFSET 5000)", nil, nil, nil)
        }
    }

    static func recent(limit: Int = 300) -> [AgentHookRecord] {
        (try? database { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT id,event_date,provider,session_id,call_id,tool,working_directory,path,command,outcome,decision,reason FROM agent_hook_events ORDER BY event_date DESC LIMIT ?", -1, &statement, nil) == SQLITE_OK,
                  let statement else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(clamping: limit))
            func string(_ index: Int32) -> String {
                guard let value = sqlite3_column_text(statement, index) else { return "" }
                return String(cString: value)
            }
            var result: [AgentHookRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(AgentHookRecord(id: string(0), date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    provider: string(2), sessionID: string(3), callID: string(4), tool: string(5),
                    workingDirectory: string(6), path: string(7), command: string(8), outcome: string(9),
                    decision: string(10), reason: string(11)))
            }
            return result
        }) ?? []
    }
}

final class AgentHookStore: ObservableObject {
    static let shared = AgentHookStore()
    @Published private(set) var events: [AgentHookRecord] = []
    private var timer: Timer?
    private init() {
        refresh()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func refresh() { events = AgentHookHistory.recent() }
    deinit { timer?.invalidate() }
}

final class AgentHookManager: ObservableObject {
    static let shared = AgentHookManager()
    @Published private(set) var statuses: [AgentHookProvider: String] = [:]
    @Published private(set) var policy = AgentHookPolicy.load()
    @Published private(set) var policyStatus = ""

    private init() {
        for provider in AgentHookProvider.allCases { statuses[provider] = Self.isInstalled(provider) ? "已接入" : "未接入" }
    }

    func install(_ provider: AgentHookProvider) {
        do {
            try Self.editConfig(provider, install: true)
            statuses[provider] = "已接入 · 重启 \(provider.executable) 后生效"
        } catch { statuses[provider] = "接入失败：\(error.localizedDescription)" }
    }

    func uninstall(_ provider: AgentHookProvider) {
        do {
            try Self.editConfig(provider, install: false)
            statuses[provider] = "已移除 · 重启 \(provider.executable) 后生效"
        } catch { statuses[provider] = "移除失败：\(error.localizedDescription)" }
    }

    func savePolicy(blockSensitiveWrites: Bool, blockDestructiveCommands: Bool, commandFragments: String) {
        var next = policy
        next.blockSensitiveWrites = blockSensitiveWrites
        next.blockDestructiveCommands = blockDestructiveCommands
        next.commandFragments = commandFragments.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(30).map { String($0.prefix(160)) }
        do {
            try next.save()
            policy = next
            policyStatus = "策略已保存"
        } catch {
            policyStatus = "策略保存失败：\(error.localizedDescription)"
        }
    }

    private static func isInstalled(_ provider: AgentHookProvider) -> Bool {
        guard let data = try? Data(contentsOf: provider.configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return containsManagedHook(object, provider: provider)
    }

    private static func containsManagedHook(_ object: [String: Any], provider: AgentHookProvider) -> Bool {
        let marker = "--ailock-agent-hook \(provider.argument)"
        func has(_ value: Any) -> Bool {
            if let string = value as? String { return string.contains(marker) }
            if let array = value as? [Any] { return array.contains(where: has) }
            if let dictionary = value as? [String: Any] { return dictionary.values.contains(where: has) }
            return false
        }
        return has(object)
    }

    private static func editConfig(_ provider: AgentHookProvider, install: Bool) throws {
        let url = provider.configURL
        let data = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : Data("{}".utf8)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "AILock.AgentHooks", code: 3, userInfo: [NSLocalizedDescriptionKey: "Agent 配置必须是 JSON 对象；未修改原文件"])
        }
        let binary = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/AILock").path
        let baseCommand = "\"\(binary.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" --ailock-agent-hook \(provider.argument)"
        let marker = "--ailock-agent-hook \(provider.argument)"
        func isManaged(_ value: Any) -> Bool { (value as? [String: Any])?["command"].map { String(describing: $0).contains(marker) } ?? false }
        func removeManaged(_ list: [Any]) -> [Any] { list.filter { !isManaged($0) } }

        switch provider {
        case .claude:
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            for event in ["PreToolUse", "PostToolUse", "PostToolUseFailure"] {
                var groups = hooks[event] as? [[String: Any]] ?? []
                groups = groups.compactMap { group in
                    var copy = group
                    let original = group["hooks"] as? [Any] ?? []
                    let filtered = removeManaged(original)
                    if !original.isEmpty && filtered.isEmpty { return nil }
                    if group["hooks"] != nil { copy["hooks"] = filtered }
                    return copy
                }
                if install && event != "PostToolUseFailure" {
                    groups.append(["matcher": "", "hooks": [["type": "command", "command": baseCommand + (event == "PreToolUse" ? " pre" : " post")]]])
                } else if install && event == "PostToolUseFailure" {
                    groups.append(["matcher": "", "hooks": [["type": "command", "command": baseCommand + " failure"]]])
                }
                if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        case .codex:
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            for event in ["PreToolUse", "PostToolUse"] {
                var groups = hooks[event] as? [[String: Any]] ?? []
                groups = groups.compactMap { group in
                    var copy = group
                    let original = group["hooks"] as? [Any] ?? []
                    let filtered = removeManaged(original)
                    if !original.isEmpty && filtered.isEmpty { return nil }
                    if group["hooks"] != nil { copy["hooks"] = filtered }
                    return copy
                }
                if install {
                    groups.append(["matcher": "", "hooks": [["type": "command", "command": baseCommand + (event == "PreToolUse" ? " pre" : " post"), "timeout": 5]]])
                }
                if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        case .cursor:
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            for event in ["preToolUse", "postToolUse", "postToolUseFailure"] {
                var handlers = removeManaged(hooks[event] as? [Any] ?? [])
                if install {
                    let mode = event == "preToolUse" ? "pre" : (event == "postToolUse" ? "post" : "failure")
                    handlers.append(["command": baseCommand + " " + mode, "failClosed": false, "timeout": 5])
                }
                if handlers.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = handlers }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
            if root["version"] == nil { root["version"] = 1 }
        }

        guard JSONSerialization.isValidJSONObject(root) else { throw NSError(domain: "AILock.AgentHooks", code: 4, userInfo: [NSLocalizedDescriptionKey: "更新后的配置无法编码"]) }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = directory.appendingPathComponent(url.lastPathComponent + ".ailock-backup-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: ""))
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        let output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: url, options: [.atomic])
    }
}

private struct AgentHookInput {
    let provider: AgentHookProvider
    let eventName: String
    let sessionID: String
    let callID: String
    let tool: String
    let cwd: String
    let path: String
    let command: String
    let outcome: String
    let duration: String
    let input: [String: Any]

    init(provider: AgentHookProvider, object: [String: Any]) {
        self.provider = provider
        func text(_ keys: String...) -> String {
            for key in keys { if let value = object[key] as? String, !value.isEmpty { return value } }
            return ""
        }
        eventName = text("hook_event_name", "event_name", "event")
        sessionID = text("session_id", "sessionId", "conversation_id", "conversationId", "run_id", "turn_id")
        callID = text("tool_use_id", "tool_call_id", "call_id", "id")
        tool = text("tool_name", "toolName", "name")
        cwd = text("cwd", "working_directory", "workingDirectory")
        var args = object["tool_input"] as? [String: Any] ?? object["input"] as? [String: Any] ?? [:]
        if args.isEmpty, let encoded = object["tool_input"] as? String, let bytes = encoded.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] { args = decoded }
        input = args
        let pathKeys = ["file_path", "path", "target_file", "filePath", "targetPath", "filename"]
        path = pathKeys.compactMap { args[$0] as? String }.first(where: { !$0.isEmpty }) ?? text("file_path", "path")
        command = (args["command"] as? String) ?? (args["cmd"] as? String) ?? (object["command"] as? String) ?? (args["shell_command"] as? String) ?? ""
        if eventName.lowercased().contains("failure") { outcome = "失败" }
        else if eventName.lowercased().contains("post") { outcome = "已完成" }
        else { outcome = "执行中" }
        duration = String(describing: object["duration"] ?? object["duration_ms"] ?? "")
    }
}

enum AgentHookRuntime {
    static func run(providerName: String, modeName: String = "", input: FileHandle = .standardInput, output: FileHandle = .standardOutput) -> Int32 {
        guard let provider = AgentHookProvider.allCases.first(where: { $0.argument == providerName }) else { return 0 }
        let data = input.readDataToEndOfFile()
        guard data.count <= 4 * 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        let event = AgentHookInput(provider: provider, object: object)
        guard !event.tool.isEmpty else { return 0 }

        let eventName = event.eventName.lowercased()
        let isPre = eventName.contains("pretooluse") || eventName == "beforetooluse" || eventName == "before_tool_use" || modeName == "pre"
        let isFailure = modeName == "failure" || eventName.contains("failure") || event.outcome == "失败"
        let policy = AgentHookPolicy.load()
        let blockedReason = isPre ? denyReason(for: event, policy: policy) : nil
        let status = blockedReason.map { _ in "已阻止" } ?? (isPre ? "执行中" : (isFailure ? "失败" : "已完成"))
        let key = event.callID.isEmpty ? UUID().uuidString : event.callID
        let safeCommand = redact(event.command)
        let record = AgentHookRecord(
            id: "\(provider.argument):\(event.sessionID.isEmpty ? "unknown-session" : event.sessionID):\(key)",
            date: Date(), provider: provider.rawValue, sessionID: event.sessionID, callID: event.callID,
            tool: event.tool, workingDirectory: event.cwd, path: event.path, command: safeCommand,
            outcome: status, decision: blockedReason == nil ? "允许继续" : "拒绝", reason: blockedReason ?? ""
        )
        AgentHookHistory.upsert(record)

        guard let blockedReason else {
            // No decision means the agent's own permission flow remains authoritative.
            return 0
        }
        let response: [String: Any]
        switch provider {
        case .claude, .codex:
            response = ["hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": blockedReason
            ]]
        case .cursor:
            response = ["permission": "deny", "user_message": blockedReason, "agent_message": blockedReason]
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: response),
              var line = String(data: encoded, encoding: .utf8) else { return 0 }
        line += "\n"
        output.write(Data(line.utf8))
        return 0
    }

    private static func denyReason(for event: AgentHookInput, policy: AgentHookPolicy) -> String? {
        if policy.blockSensitiveWrites {
            let name = event.tool.lowercased()
            let isWriteTool = ["write", "edit", "delete", "create", "write_file", "writefile", "replace"].contains(where: name.contains)
            if isWriteTool, !event.path.isEmpty, let reason = AuditPathRules.sensitiveReason(path: event.path) {
                return "AI Lock 策略阻止对敏感路径的写入（\(reason)）：\(event.path)"
            }
            let mutation = [">", "tee ", "rm ", "mv ", "cp ", "chmod ", "chown ", "sed -i", "perl -i", "install ", "touch ", "truncate "]
            if !event.command.isEmpty, mutation.contains(where: { event.command.lowercased().contains($0) }) {
                let pattern = #""([^"]+)"|'([^']+)'|([^\s;|&]+)"#
                let range = NSRange(event.command.startIndex..<event.command.endIndex, in: event.command)
                let paths = (try? NSRegularExpression(pattern: pattern).matches(in: event.command, range: range))?.compactMap { match -> String? in
                    for index in 1..<match.numberOfRanges {
                        if let range = Range(match.range(at: index), in: event.command) {
                            let value = String(event.command[range]).trimmingCharacters(in: CharacterSet(charactersIn: "()[]{};,"))
                            guard !value.isEmpty, !value.hasPrefix("-") else { return nil }
                            let expanded = (value as NSString).expandingTildeInPath
                            if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL.path }
                            guard !event.cwd.isEmpty else { return nil }
                            return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: event.cwd)).standardizedFileURL.path
                        }
                    }
                    return nil
                } ?? []
                if let reason = paths.compactMap({ AuditPathRules.sensitiveReason(path: $0) }).first {
                    return "AI Lock 策略阻止命令修改敏感路径（\(reason)）"
                }
            }
        }
        if policy.blockDestructiveCommands {
            let command = event.command.lowercased()
            if let fragment = policy.commandFragments.first(where: { !command.isEmpty && command.localizedCaseInsensitiveContains($0) }) {
                return "AI Lock 策略阻止匹配危险命令规则“\(fragment)”"
            }
        }
        return nil
    }

    private static func redact(_ value: String) -> String {
        var result = String(value.prefix(2000))
        let patterns = [
            "(?i)(sk-[A-Za-z0-9_-]{12,})",
            "(?i)(gh[pousr]_[A-Za-z0-9_]{12,})",
            "(?i)(AKIA[0-9A-Z]{16})",
            "(?i)(password|token|secret|api[_-]?key)\\s*[:=]\\s*[^\\s;]+"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1[REDACTED]")
        }
        return result
    }
}
