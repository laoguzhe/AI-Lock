import AppKit
import UserNotifications

final class ResourceAlerts {
    enum Threshold {
        case cpu, diskGB
    }

    private let defaults = UserDefaults.standard
    private var lastSent: [String: Date] = [:]

    func threshold(for threshold: Threshold) -> Double {
        switch threshold {
        case .cpu: return value("alert.cpu", fallback: 90)
        case .diskGB: return value("alert.diskGB", fallback: 10)
        }
    }

    func evaluate(_ snapshot: SystemSnapshot) {
        alert("cpu", title: "CPU 使用率过高", detail: String(format: "当前 %.0f%%", snapshot.cpuUsage * 100),
              triggered: snapshot.cpuUsage * 100 >= value("alert.cpu", fallback: 90))
        alert("memory", title: "内存压力偏高", detail: "macOS 内存压力：\(snapshot.memoryPressure)",
              triggered: snapshot.memoryPressure == "偏高" || snapshot.memoryPressure == "严重")
        let freeDisk = snapshot.diskTotal > snapshot.diskUsed ? snapshot.diskTotal - snapshot.diskUsed : 0
        let diskThreshold = UInt64(max(value("alert.diskGB", fallback: 10), 1) * 1_000_000_000)
        alert("disk", title: "磁盘空间不足", detail: "可用空间 \(formattedBytes(freeDisk))", triggered: freeDisk < diskThreshold)
        alert("network", title: "网络流量突增", detail: "↓\(formattedRate(snapshot.networkDownload))  ↑\(formattedRate(snapshot.networkUpload))",
              triggered: max(snapshot.networkDownload, snapshot.networkUpload) >= UInt64(max(value("alert.networkMB", fallback: 50), 1) * 1_000_000))
    }

    private func value(_ key: String, fallback: Double) -> Double {
        defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
    }

    private func alert(_ key: String, title: String, detail: String, triggered: Bool) {
        guard triggered else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSent[key] ?? .distantPast) >= 300 else { return }
        lastSent[key] = now
        guard defaults.object(forKey: "alert.notificationsEnabled") == nil || defaults.bool(forKey: "alert.notificationsEnabled") else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = detail
        let request = UNNotificationRequest(identifier: "ailock.\(key)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
