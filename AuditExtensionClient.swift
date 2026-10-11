import Foundation
import Combine

/// Connects only after an explicit UI action. Both peers require the same Team ID.
final class AuditExtensionClient: ObservableObject {
    static let shared = AuditExtensionClient()
    @Published private(set) var status = "文件审计尚未连接"
    @Published private(set) var active = false
    @Published private(set) var busy = false
    @Published private(set) var lines: [String] = []
    @Published private(set) var events: [FileAuditRecord] = []
    @Published private(set) var gaps: [String] = []
    @Published private(set) var reviewed: Set<UUID> = []
    @Published private(set) var historyStatus = "本地历史加载中"
    private let historyQueue = DispatchQueue(label: "com.laogu.ailock.audit-history")
    private let historyURL: URL
    private var clearedAt: Date?
    private struct History: Codable { let events: [FileAuditRecord]; let gaps: [String]; let reviewed: Set<UUID>; let clearedAt: Date? }
    init(historyURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AILock/file-audit-history.json")) {
        self.historyURL = historyURL
        do {
            if FileManager.default.fileExists(atPath: historyURL.path) {
                let size = (try FileManager.default.attributesOfItem(atPath: historyURL.path)[.size] as? NSNumber)?.intValue ?? 0
                guard size <= 32 * 1024 * 1024 else { historyStatus = "本地历史超过大小限制，未加载"; return }
                let history = try JSONDecoder().decode(History.self, from: Data(contentsOf: historyURL))
                events = Array(history.events.filter { $0.date > Date().addingTimeInterval(-7 * 86400) }.prefix(10000))
                clearedAt = history.clearedAt
                gaps = Array(history.gaps.suffix(20)); reviewed = history.reviewed.intersection(Set(events.map(\.id)))
            }
            historyStatus = "本地历史：最近 7 天，最多 10000 条"
            if FileManager.default.fileExists(atPath: historyURL.path) { persist() }
        } catch { historyStatus = "本地历史加载失败：" + error.localizedDescription }
        let retention = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let retained = self.events.filter { $0.date > Date().addingTimeInterval(-7 * 86400) }
            if retained.count != self.events.count { self.events = retained; self.persist() }
        }
        retentionTimer = retention; RunLoop.main.add(retention, forMode: .common)
    }
    func clearHistory() { clearedAt = Date(); events = []; gaps = []; reviewed = []; persist() }
    func markReviewed(_ record: FileAuditRecord) { reviewed.insert(record.id); persist() }
    private func persist() {
        reviewed.formIntersection(Set(events.map(\.id)))
        let history = History(events: events, gaps: gaps, reviewed: reviewed, clearedAt: clearedAt)
        let url = historyURL
        historyQueue.async { [weak self] in
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let data = try JSONEncoder().encode(history)
                try data.write(to: url, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                DispatchQueue.main.async { self?.historyStatus = "本地历史：最近 7 天，最多 10000 条" }
            } catch { DispatchQueue.main.async { self?.historyStatus = "本地历史保存失败：" + error.localizedDescription } }
        }
    }
    private var connection: NSXPCConnection?
    private var timer: Timer?
    private var retentionTimer: Timer?
    private var cursor = "0"
    private var generation = UUID()
    private var fetching = false
    func start(root: URL) {
        guard !busy else { return }
        disconnect(); lines = []; cursor = "0"
        guard let team = AuditIPCIdentity.team() else { status = "文件审计需要有效团队签名"; return }
        let current = UUID(); generation = current
        let connection = NSXPCConnection(machServiceName: team + "." + AuditIPCIdentity.bundleID, options: .privileged)
        connection.setCodeSigningRequirement(AuditIPCIdentity.requirement(bundleID: AuditIPCIdentity.bundleID, team: team))
        connection.remoteObjectInterface = NSXPCInterface(with: AILockAuditIPC.self)
        let failed: (String) -> Void = { [weak self] message in DispatchQueue.main.async {
            guard let self, self.generation == current else { return }; self.disconnect(); self.status = message
        } }
        connection.interruptionHandler = { failed("审计连接中断；请重新选择目录连接") }
        connection.invalidationHandler = { failed("审计连接已失效；采集已停止") }
        self.connection = connection; busy = true; status = "正在配置审计目录…"; connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ failed($0.localizedDescription) }) as? AILockAuditIPC else { failed("审计服务不可用"); return }
        proxy.configure(root: root.path) { [weak self] success, message in DispatchQueue.main.async {
            guard let self, self.generation == current else { return }
            self.busy = false; self.status = message; self.active = success
            guard success else { self.disconnect(); self.status = message; return }
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.fetch() }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common); self.fetch()
        } }
    }
    func stop() { disconnect(); status = "审计连接已停止；扩展在连接失效后停止此会话采集" }
    private func disconnect() {
        generation = UUID(); timer?.invalidate(); timer = nil; active = false; busy = false; fetching = false
        connection?.invalidationHandler = nil; connection?.interruptionHandler = nil; connection?.invalidate(); connection = nil
    }
    private func fetch() {
        guard active, !fetching, let connection else { return }
        let current = generation; fetching = true
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in DispatchQueue.main.async {
            guard let self, self.generation == current else { return }; self.disconnect(); self.status = error.localizedDescription
        } }) as? AILockAuditIPC else { disconnect(); status = "审计服务不可用"; return }
        proxy.fetch(after: cursor) { [weak self] data, failure in DispatchQueue.main.async {
            guard let self, self.generation == current else { return }; self.fetching = false
            guard let data, data.count <= 8 * 1024 * 1024, let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cursor = payload["cursor"] as? String, UInt64(cursor) != nil,
                  let events = payload["events"] as? [[String: Any]], events.count <= 100 else { self.disconnect(); self.status = failure ?? "审计返回的数据无效"; return }
            self.cursor = cursor
            if payload["reset"] as? Bool == true { self.lines.insert("扩展交付窗口已重置", at: 0); self.gaps.append("扩展交付窗口已重置") }
            if let gap = payload["deliveryGap"] as? String, gap != "0" { self.lines.insert("交付窗口遗漏 \(gap) 条；不是完整审计日志", at: 0); self.gaps.append("交付遗漏 \(gap) 条") }
            var knownIDs = Set(self.events.map(\.id))
            for event in events {
                if let record = FileAuditRecord(event), self.clearedAt.map({ record.date > $0 }) ?? true, knownIDs.insert(record.id).inserted { self.events.insert(record, at: 0) }
                if event["kind"] as? String == "kernel-events-dropped" { self.gaps.append("系统事件存在序列缺口") }
                let kind = event["kind"] as? String ?? "未知事件"
                let line = kind == "kernel-events-dropped" ? "ES 客户端序列缺口：\(event["count"] ?? "未知")" : "\(kind) · PID \(event["pid"] ?? "?") · \(event["path"] ?? "")" + (event["destinationPath"].map { " → \($0)" } ?? "")
                self.lines.insert(line, at: 0)
            }
            self.lines = Array(self.lines.prefix(500))
            self.events = Array(self.events.filter { $0.date > Date().addingTimeInterval(-7 * 86400) }.prefix(10000)); self.gaps = Array(self.gaps.suffix(20))
            if !events.isEmpty || payload["reset"] as? Bool == true { self.persist() }
        } }
    }
    deinit { timer?.invalidate(); retentionTimer?.invalidate(); connection?.invalidate() }
}


