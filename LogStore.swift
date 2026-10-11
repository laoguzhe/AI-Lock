import Foundation
import OSLog

enum SystemLogLevel: String, CaseIterable {
    case all = "全部级别"
    case debug = "调试"
    case info = "信息"
    case notice = "通知"
    case error = "错误"
    case fault = "严重错误"
}

struct SystemLogEntry: Identifiable {
    let id: String
    let date: Date
    let level: SystemLogLevel
    let process: String
    let subsystem: String
    let category: String
    let message: String

    var formattedTime: String {
        Self.timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}

final class SystemLogStore {
    private let queue = DispatchQueue(label: "com.laogu.ailock.system-logs", qos: .utility)
    private let maximumEntries = 2_000

    func fetch(since interval: TimeInterval = 10 * 60,
               onBatch: @escaping ([SystemLogEntry], Int, Bool) -> Void,
               completion: @escaping (Error?) -> Void) {
        queue.async {
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                let start = Date().addingTimeInterval(-interval)
                let position = store.position(date: start)
                let entries = try store.getEntries(at: position, matching: NSPredicate(format: "eventType == 1024 OR eventType == 2"))

                var retained: [SystemLogEntry] = []
                var count = 0
                for entry in entries {
                    guard let log = entry as? OSLogEntryLog else { continue }
                    let value = SystemLogEntry(id: "\(log.date.timeIntervalSince1970)-\(log.processIdentifier)-\(count)",
                                               date: log.date, level: Self.level(for: log.level), process: log.process,
                                               subsystem: log.subsystem, category: log.category, message: log.composedMessage)
                    if retained.count < self.maximumEntries { retained.append(value) }
                    else { retained[count % self.maximumEntries] = value }
                    count += 1
                }
                let ordered = retained.sorted { $0.date < $1.date }
                for start in stride(from: 0, to: ordered.count, by: 100) {
                    onBatch(Array(ordered[start..<min(start + 100, ordered.count)].reversed()), count, false)
                }
                onBatch([], count, true)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    private static func level(for level: OSLogEntryLog.Level) -> SystemLogLevel {
        switch level {
        case .debug: return .debug
        case .info: return .info
        case .notice: return .notice
        case .error: return .error
        case .fault: return .fault
        default: return .info
        }
    }
}

// Interpret only known application messages; unknown messages keep their original wording.
extension SystemLogEntry {
    var needsAttention: Bool {
        level == .error || level == .fault || message.contains("失败") || message.hasPrefix("未就绪：") || message.contains("找不到 Dock 进程")
    }
    var summary: String {
        if message.hasPrefix("未就绪：AXIsProcessTrusted=false") { return "辅助功能权限尚未授权" }
        if message.contains("DockLock 启动失败") { return "Dock 锁定启动失败" }
        if message.contains("AX: 找不到 Dock 进程") { return "暂时找不到 Dock 进程" }
        if message.contains("AX: 读 Dock children 失败") { return "无法读取 Dock 状态" }
        if message.contains("event tap 被系统关闭，已重新启用") { return "鼠标监听已自动恢复" }
        if message.contains("开机自启切换失败") { return "开机自启设置未成功" }
        if message.hasPrefix("目标屏改为") { return "Dock 锁定的目标屏幕已更新" }
        if message.hasPrefix("检测到 Dock 在屏") { return "已尝试将 Dock 移回目标屏幕" }
        if message.hasPrefix("状态栏图标：") { return "状态栏图标已加载" }
        return message
    }
    var guidance: String {
        if message.hasPrefix("未就绪：AXIsProcessTrusted=false") || message.contains("DockLock 启动失败") {
            return "Dock 锁定可能无法工作。请在系统设置 → 隐私与安全性 → 辅助功能中检查 AI Lock 授权，然后重新启动应用。"
        }
        if message.contains("拽回连续失败") { return "请将鼠标手动移到目标屏幕底边一次，再观察 Dock 是否恢复锁定。" }
        if message.contains("开机自启切换失败") { return "请在系统设置 → 通用 → 登录项中检查 AI Lock。" }
        if needsAttention { return "请结合下面的原始记录检查问题；仅凭这条日志无法确定原因。可导出诊断报告供排查。" }
        return "这是一条运行记录，通常无需操作。"
    }
}

struct SystemLogGroup {
    let entries: [SystemLogEntry]
    var latest: SystemLogEntry { entries[0] }
    var title: String { latest.summary + (entries.count > 1 ? "（重复 \(entries.count) 次）" : "") }
    var detail: String {
        let first = entries.last!
        return "\(title)\n\(latest.guidance)\n\n首次：\(first.formattedTime)\n最近：\(latest.formattedTime)\n级别：\(latest.level.rawValue) · 进程：\(latest.process)\n子系统：\(latest.subsystem)\n类别：\(latest.category)\n\n原始消息：\n\(latest.message)"
    }
    static func merge(_ entries: [SystemLogEntry]) -> [SystemLogGroup] {
        let buckets = Dictionary(grouping: entries) { [$0.level.rawValue, $0.process, $0.subsystem, $0.category, $0.message] }
        return buckets.values.map { SystemLogGroup(entries: $0.sorted { $0.date > $1.date }) }.sorted { $0.latest.date > $1.latest.date }
    }
}

enum LogDiagnosticReport {
    static func redact(_ text: String) -> String {
        var value = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        for pattern in [#"(?i)(bearer\s+)[^\s,;]+"#, #"(?i)((?:token|password|secret|api[_-]?key|authorization|cookie)\s*[:=]\s*)[^\s,;]+"#, #"[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, #"https?://[^\s]+"#] {
            value = value.replacingOccurrences(of: pattern, with: "[已隐藏]", options: .regularExpression)
        }
        return value
    }
    static func make(entries: [SystemLogEntry], scope: String) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let header = "AI Lock 诊断报告\n生成时间：\(Date())\n应用版本：\(version)\n系统：\(ProcessInfo.processInfo.operatingSystemVersionString)\n范围：当前进程最近 10 分钟，最多 2000 条；\(scope)\n记录数：\(entries.count)\n已自动隐藏常见凭据、网址、邮箱和用户主目录；分享前请检查内容。\n"
        return header + entries.sorted { $0.date < $1.date }.map {
            redact("\n[\($0.formattedTime)] [\($0.level.rawValue)] \($0.process) / \($0.subsystem) / \($0.category)\n\($0.summary)\n\($0.message)\n")
        }.joined()
    }
}
