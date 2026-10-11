import Foundation
func entry(_ message: String, _ time: Double, _ level: SystemLogLevel = .notice) -> SystemLogEntry {
    SystemLogEntry(id: "\(time)", date: Date(timeIntervalSince1970: time), level: level, process: "AILock", subsystem: "app", category: "application", message: message)
}
let a = entry("DockLock 启动失败：辅助功能授权缺失或 CGEvent tap 创建失败", 1)
assert(a.needsAttention && a.summary == "Dock 锁定启动失败")
let unknown = entry("unknown message", 2)
assert(unknown.summary == unknown.message)
let groups = SystemLogGroup.merge([a, unknown, entry(a.message, 3), entry(a.message, 4, .error)])
assert(groups.count == 3 && groups[1].entries.count == 2)
assert(groups[1].latest.date.timeIntervalSince1970 == 3)
let redacted = LogDiagnosticReport.redact("\(NSHomeDirectory())/test token=abc Bearer xyz email=user@example.com https://example.com/?key=abc")
assert(!redacted.contains("abc") && !redacted.contains("xyz") && !redacted.contains("user@example.com") && !redacted.contains(NSHomeDirectory()))
assert(LogDiagnosticReport.make(entries: [a], scope: "测试").contains("记录数：1"))
print("Log grouping, summaries and diagnostic redaction checks passed")
