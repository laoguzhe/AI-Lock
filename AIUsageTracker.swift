import Foundation
import Combine
import SwiftUI

struct AIUsageEntry: Identifiable {
    let id: String
    let date: Date
    let tool: String
    let model: String
    let workingDirectory: String?
    let sessionID: String?
    let inputTokens: Int64
    let outputTokens: Int64
    let cachedTokens: Int64

    var totalTokens: Int64 { inputTokens + outputTokens }
}

struct AIModelUsage: Identifiable {
    let model: String
    let tool: String
    let inputTokens: Int64
    let outputTokens: Int64
    var totalTokens: Int64 { inputTokens + outputTokens }
    var id: String { tool + ":" + model }
}

/// Reads token counters from local Codex and Claude Code session logs. Prompt and response
/// text is neither retained nor written; only usage fields and session metadata are used.
final class AIUsageTracker: ObservableObject {
    static let shared = AIUsageTracker()

    @Published private(set) var todayEntries: [AIUsageEntry] = []
    @Published private(set) var recentEntries: [AIUsageEntry] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?

    private struct FileSnapshot {
        let size: Int64
        let modified: Date
        let entries: [AIUsageEntry]
    }

    private let queue = DispatchQueue(label: "com.laogu.ailock.ai-usage", qos: .utility)
    private var fileSnapshots: [String: FileSnapshot] = [:]
    private var timer: Timer?
    private var refreshInProgress = false
    private let maximumFiles = 4_000
    private let maximumFileSize: Int64 = 128 * 1024 * 1024
    private let maximumTotalBytes: Int64 = 1024 * 1024 * 1024
    private let maximumLineSize = 2 * 1024 * 1024
    private static let iso8601 = ISO8601DateFormatter()
    private static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private init() {
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    func refresh() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !refreshInProgress else { return }
        refreshInProgress = true
        isRefreshing = true
        queue.async { [weak self] in
            guard let self else { return }
            let entries = self.scan()
            DispatchQueue.main.async {
                self.recentEntries = entries.filter { $0.date >= Date().addingTimeInterval(-7 * 86400) }
                let startOfDay = Calendar.current.startOfDay(for: Date())
                self.todayEntries = self.recentEntries.filter { $0.date >= startOfDay }
                self.lastUpdated = Date()
                self.refreshInProgress = false
                self.isRefreshing = false
            }
        }
    }

    var todayInputTokens: Int64 { todayEntries.reduce(0) { $0 + $1.inputTokens } }
    var todayOutputTokens: Int64 { todayEntries.reduce(0) { $0 + $1.outputTokens } }
    var todayTotalTokens: Int64 { todayInputTokens + todayOutputTokens }

    var todayModels: [AIModelUsage] {
        let grouped = Dictionary(grouping: todayEntries, by: { $0.tool + "\u{1f}" + $0.model })
        return grouped.map { key, entries in
            let parts = key.split(separator: "\u{1f}", maxSplits: 1).map(String.init)
            return AIModelUsage(model: parts.last ?? "未知模型", tool: parts.first ?? "AI", inputTokens: entries.reduce(0) { $0 + $1.inputTokens }, outputTokens: entries.reduce(0) { $0 + $1.outputTokens })
        }.sorted { $0.totalTokens > $1.totalTokens }
    }

    /// A directory-and-time heuristic for showing nearby model usage beside file events.
    /// It is deliberately not presented as proof that a model caused a file operation.
    func likelyMatch(for event: FileAuditRecord) -> AIUsageEntry? {
        guard event.isAI else { return nil }
        let filePath = URL(fileURLWithPath: event.path).standardizedFileURL.path
        return recentEntries
            .filter { entry in
                guard let directory = entry.workingDirectory, !directory.isEmpty else { return false }
                let root = URL(fileURLWithPath: directory).standardizedFileURL.path
                let insideProject = filePath == root || filePath.hasPrefix(root.hasSuffix("/") ? root : root + "/")
                return insideProject && abs(entry.date.timeIntervalSince(event.date)) <= 30 * 60
            }
            .min { abs($0.date.timeIntervalSince(event.date)) < abs($1.date.timeIntervalSince(event.date)) }
    }

    private func scan() -> [AIUsageEntry] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        func configuredDirectory(_ key: String, fallback: URL) -> URL {
            guard let path = environment[key], !path.isEmpty else { return fallback }
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        let codexHome = configuredDirectory("CODEX_HOME", fallback: home.appendingPathComponent(".codex", isDirectory: true))
        let claudeHome = configuredDirectory("CLAUDE_CONFIG_DIR", fallback: home.appendingPathComponent(".claude", isDirectory: true))
        let roots: [(String, URL)] = [
            ("Codex", codexHome.appendingPathComponent("sessions", isDirectory: true)),
            ("Claude Code", claudeHome.appendingPathComponent("projects", isDirectory: true))
        ]
        var discovered: [String: (String, URL, Int64, Date)] = [:]
        for (tool, root) in roots where FileManager.default.fileExists(atPath: root.path) {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension.lowercased() == "jsonl",
                      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      let size = values.fileSize, Int64(size) <= maximumFileSize,
                      let modified = values.contentModificationDate,
                      modified >= Date().addingTimeInterval(-8 * 86400) else { continue }
                discovered[url.path] = (tool, url, Int64(size), modified)
                if discovered.count >= maximumFiles { break }
            }
        }

        var refreshed: [String: FileSnapshot] = [:]
        var totalBytes: Int64 = 0
        let scanOrder = discovered.sorted { $0.value.3 > $1.value.3 }
        for (path, item) in scanOrder {
            guard totalBytes + item.2 <= maximumTotalBytes else { continue }
            totalBytes += item.2
            if let cached = fileSnapshots[path], cached.size == item.2, cached.modified == item.3 {
                refreshed[path] = cached
            } else if let entries = parse(url: item.1, tool: item.0) {
                refreshed[path] = FileSnapshot(size: item.2, modified: item.3, entries: entries)
            }
        }
        fileSnapshots = refreshed
        return refreshed.values.flatMap(\.entries).sorted { $0.date > $1.date }
    }

    private func parse(url: URL, tool: String) -> [AIUsageEntry]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var entries: [AIUsageEntry] = []
        var buffer = Data()
        var recordIndex = 0
        var cwd: String?
        var sessionID: String?
        var model = tool
        var previousCodexUsage: TokenCounts?
        var seenClaudeMessages = Set<String>()

        func consume(_ data: Data) {
            guard !data.isEmpty, data.count <= maximumLineSize,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            recordIndex += 1
            let timestamp = (object["timestamp"] as? String).flatMap(Self.parseDate)
                ?? (object["created_at"] as? String).flatMap(Self.parseDate)

            if tool == "Codex" {
                let payload = object["payload"] as? [String: Any] ?? [:]
                let kind = object["type"] as? String ?? ""
                if kind == "session_meta" {
                    cwd = payload["cwd"] as? String ?? cwd
                    sessionID = payload["id"] as? String ?? sessionID
                } else if kind == "turn_context" {
                    model = payload["model"] as? String ?? model
                    cwd = payload["cwd"] as? String ?? cwd
                } else if kind == "event_msg", (payload["type"] as? String) == "token_count",
                          let info = payload["info"] as? [String: Any],
                          let total = TokenCounts(dictionary: info["total_token_usage"] as? [String: Any] ?? info) {
                    let previous = previousCodexUsage ?? .zero
                    let delta = total.positiveDifference(from: previous)
                    previousCodexUsage = total
                    guard delta.input + delta.output > 0, let timestamp else { return }
                    entries.append(AIUsageEntry(id: url.path + "#" + String(recordIndex), date: timestamp, tool: tool, model: model, workingDirectory: cwd, sessionID: sessionID, inputTokens: delta.input, outputTokens: delta.output, cachedTokens: delta.cachedInput))
                }
            } else if tool == "Claude Code", (object["type"] as? String) == "assistant",
                      let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any],
                      let timestamp {
                let messageID = message["id"] as? String ?? object["requestId"] as? String ?? String(recordIndex)
                guard seenClaudeMessages.insert(messageID).inserted else { return }
                let input = Self.number(usage["input_tokens"])
                let output = Self.number(usage["output_tokens"])
                let cacheCreate = Self.number(usage["cache_creation_input_tokens"])
                let cacheRead = Self.number(usage["cache_read_input_tokens"])
                guard input + output + cacheCreate + cacheRead > 0 else { return }
                entries.append(AIUsageEntry(id: url.path + "#" + messageID, date: timestamp, tool: tool, model: message["model"] as? String ?? "Claude", workingDirectory: object["cwd"] as? String ?? cwd, sessionID: object["sessionId"] as? String ?? sessionID, inputTokens: input + cacheCreate + cacheRead, outputTokens: output, cachedTokens: cacheCreate + cacheRead))
            }
        }

        do {
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    consume(Data(buffer[..<newline]))
                    buffer.removeSubrange(...newline)
                }
                if buffer.count > maximumLineSize { buffer.removeAll(keepingCapacity: true) }
            }
            if !buffer.isEmpty { consume(buffer) }
        } catch { return nil }
        return entries
    }

    private static func parseDate(_ value: String) -> Date? {
        iso8601.date(from: value) ?? fractionalISO8601.date(from: value)
    }

    fileprivate static func number(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return max(0, number.int64Value) }
        if let value = value as? Int64 { return max(0, value) }
        return 0
    }
}

private struct TokenCounts {
    let input: Int64
    let output: Int64
    let cachedInput: Int64

    static let zero = TokenCounts(input: 0, output: 0, cachedInput: 0)

    init(input: Int64, output: Int64, cachedInput: Int64) {
        self.input = input
        self.output = output
        self.cachedInput = cachedInput
    }

    init?(dictionary: [String: Any]) {
        guard dictionary["input_tokens"] != nil || dictionary["output_tokens"] != nil else { return nil }
        input = AIUsageTracker.number(dictionary["input_tokens"])
        output = AIUsageTracker.number(dictionary["output_tokens"])
        cachedInput = AIUsageTracker.number(dictionary["cached_input_tokens"] ?? dictionary["cache_read_input_tokens"])
    }

    func positiveDifference(from previous: TokenCounts) -> TokenCounts {
        TokenCounts(input: max(0, input - previous.input), output: max(0, output - previous.output), cachedInput: max(0, cachedInput - previous.cachedInput))
    }
}

struct AIUsageCard: View {
    @ObservedObject var tracker: AIUsageTracker
    var english = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text(english ? "Today's AI token usage" : "今日 AI 模型用量"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { tracker.refresh() } label: {
                    Image(systemName: tracker.isRefreshing ? "arrow.trianglehead.2.clockwise" : "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .disabled(tracker.isRefreshing)
                .help(L10n.text(english ? "Refresh local usage logs" : "重新扫描本机用量日志"))
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(tracker.todayTotalTokens.formatted())
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(L10n.text("tokens"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(L10n.text("输入 \(tracker.todayInputTokens.formatted()) · 输出 \(tracker.todayOutputTokens.formatted())"))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    Rectangle().fill(Color.accentColor).frame(width: proxy.size.width * inputFraction)
                    Rectangle().fill(Color.accentColor.opacity(0.38))
                }
            }
            .frame(height: 6)
            .clipShape(Capsule())
            HStack(spacing: 10) {
                if tracker.todayModels.isEmpty {
                    Text(L10n.text(english ? "No local usage records found" : "未发现 Codex / Claude Code 本机用量记录"))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                } else {
                    ForEach(tracker.todayModels.prefix(3)) { model in
                        Text("\(model.model)  \(model.totalTokens.formatted())")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
        .help(L10n.text(english ? "Local Codex and Claude Code token counters. No prompts, responses, credentials or network data are collected." : "仅读取本机 Codex 与 Claude Code 用量计数；不采集提示词、回复正文、凭据或网络数据。"))
    }

    private var inputFraction: CGFloat {
        guard tracker.todayTotalTokens > 0 else { return 0 }
        return CGFloat(tracker.todayInputTokens) / CGFloat(tracker.todayTotalTokens)
    }
}
