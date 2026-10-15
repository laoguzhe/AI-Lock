import Foundation
import Combine
import SQLite3
import CryptoKit

enum AgentHookProvider: String, CaseIterable, Identifiable, Hashable {
    case claude = "Claude Code"
    case codex = "Codex"
    case cursor = "Cursor"
    case windsurf = "Windsurf"
    case gemini = "Gemini CLI"
    case opencode = "OpenCode"

    var id: String { rawValue }
    var argument: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .cursor: return "cursor"
        case .windsurf: return "windsurf"
        case .gemini: return "gemini"
        case .opencode: return "opencode"
        }
    }
    var executable: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .cursor: return "Cursor"
        case .windsurf: return "Windsurf Cascade"
        case .gemini: return "Gemini CLI"
        case .opencode: return "OpenCode"
        }
    }
    var configURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        case .codex: return home.appendingPathComponent(".codex/hooks.json")
        case .cursor: return home.appendingPathComponent(".cursor/hooks.json")
        case .windsurf: return home.appendingPathComponent(".codeium/windsurf/hooks.json")
        case .gemini: return home.appendingPathComponent(".gemini/settings.json")
        case .opencode: return home.appendingPathComponent(".config/opencode/plugins/ailock-security-monitor.ts")
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

    static func clear() {
        _ = try? database { db in sqlite3_exec(db, "DELETE FROM agent_hook_events", nil, nil, nil) }
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
    func clearHistory() { AgentHookHistory.clear(); refresh() }
    deinit { timer?.invalidate() }
}

final class AgentHookManager: ObservableObject {
    static let shared = AgentHookManager()
    @Published private(set) var statuses: [AgentHookProvider: String] = [:]

    private init() {
        for provider in AgentHookProvider.allCases {
            statuses[provider] = Self.isMonitorInstalled(provider) ? "仅监视已接入" : (Self.isInstalled(provider) ? "AI Lock Hook 已接入" : "未接入")
        }
    }

    func install(_ provider: AgentHookProvider) {
        installMonitor(provider)
    }

    /// Installs an advisory-only hook. It records tool calls and never returns a deny decision.
    func installMonitor(_ provider: AgentHookProvider) {
        do {
            try Self.editConfig(provider, install: true, monitorOnly: true)
            statuses[provider] = "仅监视已接入 · 重启 \(provider.executable) 后生效"
        } catch { statuses[provider] = "接入失败：\(error.localizedDescription)" }
    }

    func uninstall(_ provider: AgentHookProvider) {
        do {
            try Self.editConfig(provider, install: false, monitorOnly: false)
            statuses[provider] = "已移除 · 重启 \(provider.executable) 后生效"
        } catch { statuses[provider] = "移除失败：\(error.localizedDescription)" }
    }

    private static func isInstalled(_ provider: AgentHookProvider) -> Bool {
        if provider == .opencode {
            return (try? String(contentsOf: provider.configURL, encoding: .utf8))?.contains("AILOCK_AGENT_MONITOR") == true
        }
        guard let data = try? Data(contentsOf: provider.configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return containsManagedHook(object, provider: provider)
    }

    private static func isMonitorInstalled(_ provider: AgentHookProvider) -> Bool {
        if provider == .opencode {
            return (try? String(contentsOf: provider.configURL, encoding: .utf8))?.contains("AILOCK_AGENT_MONITOR") == true
        }
        guard let data = try? Data(contentsOf: provider.configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let marker = "--ailock-agent-hook \(provider.argument) watch-"
        func has(_ value: Any) -> Bool {
            if let string = value as? String { return string.contains(marker) }
            if let array = value as? [Any] { return array.contains(where: has) }
            if let dictionary = value as? [String: Any] { return dictionary.values.contains(where: has) }
            return false
        }
        return has(object)
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

    private static func editConfig(_ provider: AgentHookProvider, install: Bool, monitorOnly: Bool) throws {
        if provider == .opencode {
            try editOpenCodePlugin(install: install)
            return
        }
        let url = provider.configURL
        let data = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : Data("{}".utf8)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "AILock.AgentHooks", code: 3, userInfo: [NSLocalizedDescriptionKey: "Agent 配置必须是 JSON 对象；未修改原文件"])
        }
        let binary = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/AILock").path
        let baseCommand = "\"\(binary.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" --ailock-agent-hook \(provider.argument)"
        func hookCommand(_ mode: String) -> String { baseCommand + (monitorOnly ? " watch-" : " ") + mode }
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
                    groups.append(["matcher": "", "hooks": [["type": "command", "command": hookCommand(event == "PreToolUse" ? "pre" : "post")]]])
                } else if install && event == "PostToolUseFailure" {
                    groups.append(["matcher": "", "hooks": [["type": "command", "command": hookCommand("failure")]]])
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
                    groups.append(["matcher": "", "hooks": [["type": "command", "command": hookCommand(event == "PreToolUse" ? "pre" : "post"), "timeout": 5]]])
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
                    handlers.append(["command": hookCommand(mode), "failClosed": false, "timeout": 5])
                }
                if handlers.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = handlers }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
            if root["version"] == nil { root["version"] = 1 }
        case .windsurf:
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            for event in ["pre_read_code", "post_read_code", "pre_write_code", "post_write_code",
                          "pre_run_command", "post_run_command", "pre_mcp_tool_use", "post_mcp_tool_use"] {
                var entries = hooks[event] as? [[String: Any]] ?? []
                entries.removeAll { String(describing: $0["command"] ?? "").contains(marker) }
                if install {
                    entries.append(["command": hookCommand(event), "show_output": false])
                }
                if entries.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = entries }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        case .gemini:
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            for event in ["BeforeTool", "AfterTool"] {
                var groups = hooks[event] as? [[String: Any]] ?? []
                groups = groups.compactMap { group in
                    var copy = group
                    let original = group["hooks"] as? [Any] ?? []
                    let filtered = original.filter { item in
                        !String(describing: (item as? [String: Any])?["command"] ?? "").contains(marker)
                    }
                    if !original.isEmpty && filtered.isEmpty { return nil }
                    if group["hooks"] != nil { copy["hooks"] = filtered }
                    return copy
                }
                if install {
                    groups.append(["matcher": ".*", "hooks": [["name": "AILock monitor", "type": "command", "command": hookCommand(event == "BeforeTool" ? "pre" : "post"), "timeout": 5000]]])
                }
                if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        case .opencode:
            break // Handled by editOpenCodePlugin before decoding a JSON configuration.
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

    private static func editOpenCodePlugin(install: Bool) throws {
        let url = AgentHookProvider.opencode.configURL
        if !install {
            if let source = try? String(contentsOf: url, encoding: .utf8), source.contains("AILOCK_AGENT_MONITOR") {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        if FileManager.default.fileExists(atPath: url.path),
           let existing = try? String(contentsOf: url, encoding: .utf8),
           !existing.contains("AILOCK_AGENT_MONITOR") {
            throw NSError(domain: "AILock.AgentHooks", code: 5, userInfo: [NSLocalizedDescriptionKey: "OpenCode 插件路径已被其他文件占用；为避免覆盖，未修改该文件"])
        }
        let binary = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/AILock").path
        let quotedBinary = (try? JSONSerialization.data(withJSONObject: [binary], options: [.fragmentsAllowed]))
            .flatMap { String(data: $0, encoding: .utf8) }?.dropFirst().dropLast() ?? Substring("\"/Applications/AILock.app/Contents/MacOS/AILock\"")
        let source = #"""
        // AILOCK_AGENT_MONITOR: advisory-only OpenCode tool activity integration.
        const AILOCK_BIN = \#(quotedBinary);
        async function report(mode, input, args, outcome) {
          try {
            const payload = {
              event_name: mode === "pre" ? "tool.execute.before" : "tool.execute.after",
              session_id: input.sessionID ?? input.session_id ?? "",
              call_id: input.toolCallID ?? input.callID ?? "",
              cwd: input.directory ?? process.cwd(),
              tool_name: input.tool ?? input.name ?? "",
              tool_input: args ?? {},
              outcome: outcome ?? ""
            };
            const child = Bun.spawn([AILOCK_BIN, "--ailock-agent-hook", "opencode", `watch-${mode}`], {
              stdin: "pipe", stdout: "ignore", stderr: "ignore"
            });
            child.stdin.write(JSON.stringify(payload));
            child.stdin.end();
            await child.exited;
          } catch (_) { /* Monitoring failures never affect the agent action. */ }
        }
        export const AILockSecurityMonitor = async ({ directory }) => ({
          "tool.execute.before": async (input, output) => report("pre", { ...input, directory }, output?.args),
          "tool.execute.after": async (input, output) => report("post", { ...input, directory }, output?.args, output?.status)
        });
        """#
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = directory.appendingPathComponent(url.lastPathComponent + ".ailock-backup-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: ""))
            try FileManager.default.copyItem(at: url, to: backup)
        }
        try source.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
        let details = object["tool_info"] as? [String: Any] ?? object
        func text(_ keys: String...) -> String {
            for key in keys { if let value = object[key] as? String, !value.isEmpty { return value } }
            return ""
        }
        func detailText(_ keys: String...) -> String {
            for key in keys { if let value = details[key] as? String, !value.isEmpty { return value } }
            return ""
        }
        eventName = text("hook_event_name", "agent_action_name", "event_name", "event")
        sessionID = text("session_id", "sessionId", "trajectory_id", "conversation_id", "conversationId", "run_id", "turn_id")
        let executionID = text("execution_id")
        let eventTool = text("tool_name", "toolName", "name")
        let nestedTool = detailText("tool_name", "mcp_tool_name", "toolName", "name")
        tool = !eventTool.isEmpty ? eventTool : (!nestedTool.isEmpty ? nestedTool : eventName)
        cwd = !text("cwd", "working_directory", "workingDirectory").isEmpty
            ? text("cwd", "working_directory", "workingDirectory")
            : detailText("cwd", "working_directory", "workingDirectory")
        var args = object["tool_input"] as? [String: Any]
            ?? details["tool_input"] as? [String: Any]
            ?? details["mcp_tool_arguments"] as? [String: Any]
            ?? details["args"] as? [String: Any]
            ?? object["input"] as? [String: Any]
            ?? [:]
        if args.isEmpty, let encoded = object["tool_input"] as? String, let bytes = encoded.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] { args = decoded }
        input = args
        let pathKeys = ["file_path", "path", "target_file", "filePath", "targetPath", "filename"]
        path = pathKeys.compactMap { args[$0] as? String }.first(where: { !$0.isEmpty })
            ?? pathKeys.compactMap { details[$0] as? String }.first(where: { !$0.isEmpty })
            ?? text("file_path", "path")
        command = (args["command"] as? String) ?? (args["command_line"] as? String) ?? (args["cmd"] as? String)
            ?? (args["shell_command"] as? String) ?? (details["command_line"] as? String)
            ?? (object["command"] as? String) ?? ""
        let rawOutcome = text("outcome", "status").lowercased()
        if eventName.lowercased().contains("failure") || rawOutcome.contains("error") || rawOutcome.contains("fail") { outcome = "失败" }
        else if eventName.lowercased().contains("post") || eventName.lowercased().contains("after") { outcome = "已完成" }
        else { outcome = "执行中" }
        let explicitCallID = text("tool_use_id", "tool_call_id", "call_id", "toolCallID", "callID", "id")
        if !explicitCallID.isEmpty { callID = explicitCallID }
        else if !executionID.isEmpty {
            let correlationData = Data([executionID, tool, path, command].joined(separator: "|").utf8)
            let digest = SHA256.hash(data: correlationData)
            let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
            callID = "exec-\(fingerprint)"
        }
        else { callID = "" }
        duration = String(describing: object["duration"] ?? object["duration_ms"] ?? "")
    }
}

enum AgentHookRuntime {
    static func run(providerName: String, modeName: String = "", input: FileHandle = .standardInput, output: FileHandle = .standardOutput) -> Int32 {
        guard let provider = AgentHookProvider.allCases.first(where: { $0.argument == providerName }) else { return 0 }
        let monitorOnly = modeName.hasPrefix("watch-")
        let data = input.readDataToEndOfFile()
        guard data.count <= 4 * 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if monitorOnly && provider == .gemini { output.write(Data("{}\n".utf8)) }
            return 0
        }
        let event = AgentHookInput(provider: provider, object: object)
        guard !event.tool.isEmpty else {
            if monitorOnly && provider == .gemini { output.write(Data("{}\n".utf8)) }
            return 0
        }

        let effectiveMode = monitorOnly ? String(modeName.dropFirst("watch-".count)) : modeName
        let eventName = event.eventName.lowercased()
        let isPre = eventName.contains("pretooluse") || eventName == "beforetooluse" || eventName == "before_tool_use"
            || eventName.hasPrefix("pre_") || eventName.hasSuffix(".before") || effectiveMode == "pre"
        let isFailure = effectiveMode == "failure" || eventName.contains("failure") || event.outcome == "失败"
        let warning = warningReason(for: event)
        let status = isPre ? "执行中" : (isFailure ? "失败" : "已完成")
        let key = event.callID.isEmpty ? UUID().uuidString : event.callID
        let safeCommand = redact(event.command)
        let record = AgentHookRecord(
            id: "\(provider.argument):\(event.sessionID.isEmpty ? "unknown-session" : event.sessionID):\(key)",
            date: Date(), provider: provider.rawValue, sessionID: event.sessionID, callID: event.callID,
            tool: event.tool, workingDirectory: event.cwd, path: event.path, command: safeCommand,
            outcome: status, decision: "仅记录；允许继续", reason: warning ?? ""
        )
        AgentHookHistory.upsert(record)

        // These integrations are intentionally advisory-only, including hooks installed by older app versions.
        if provider == .gemini { output.write(Data("{}\n".utf8)) }
        return 0
    }

    /// Heuristics are labels for human review only; Agent hook calls are never blocked.
    private static func warningReason(for event: AgentHookInput) -> String? {
        if !event.path.isEmpty, let reason = AuditPathRules.sensitiveReason(path: event.path) {
            return "风险提示：工具目标位于敏感路径（\(reason)），请核对操作意图。"
        }
        let command = event.command.lowercased()
        let riskyCommands = ["rm -rf", "git push --force", "git reset --hard", "mkfs", "curl ", "wget ", "launchctl", "sudo "]
        if let fragment = riskyCommands.first(where: { command.contains($0) }) {
            return "风险提示：命令包含需要核对的操作“\(fragment.trimmingCharacters(in: .whitespaces))”。"
        }
        let tool = event.tool.lowercased()
        if ["delete", "remove", "write", "edit", "replace"].contains(where: tool.contains) {
            return "操作提示：这是文件删除或写入类工具调用；记录不证明底层操作结果。"
        }
        return nil
    }

    private static func redact(_ value: String) -> String {
        var result = String(value.prefix(2000))
        let patterns = [
            #"(?i)(sk-[A-Za-z0-9_-]{12,})"#,
            #"(?i)(gh[pousr]_[A-Za-z0-9_]{12,})"#,
            #"(?i)(AKIA[0-9A-Z]{16})"#,
            #"(?i)(authorization\s*[:=]\s*(?:bearer\s+)?)[^\s,;]+"#,
            #"(?i)(bearer\s+)[A-Za-z0-9._~+/-]{8,}"#,
            #"(?i)(password|token|secret|api[_-]?key)\s*[:=]\s*[^\s;]+"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1[REDACTED]")
        }
        return result
    }
}
