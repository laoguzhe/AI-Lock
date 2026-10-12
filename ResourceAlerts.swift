import Foundation

extension Notification.Name {
    static let resourceAlertPreview = Notification.Name("resourceAlertPreview")
}

final class ResourceAlerts {
    enum Threshold { case cpu, memory, diskGB }
    enum Metric: String, CaseIterable { case cpu, memory, disk, network, swap, battery, thermal, camera, microphone }
    private let defaults: UserDefaults
    private(set) var activeMetrics: Set<Metric> = []

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func threshold(for threshold: Threshold) -> Double {
        switch threshold {
        case .cpu: return value("alert.cpu", fallback: 90)
        case .memory: return value("alert.memory", fallback: 80)
        case .diskGB: return value("alert.diskGB", fallback: 10)
        }
    }

    @discardableResult
    func evaluate(_ snapshot: SystemSnapshot) -> Set<Metric> {
        var active = Set<Metric>()
        if snapshot.cpuUsage * 100 >= value("alert.cpu", fallback: 90) { active.insert(.cpu) }
        let memoryUsage = snapshot.memoryTotal > 0 ? Double(snapshot.memoryUsed) / Double(snapshot.memoryTotal) * 100 : 0
        if snapshot.memoryPressure == "偏高" || snapshot.memoryPressure == "严重" ||
            (snapshot.memoryTotal > 0 && memoryUsage >= value("alert.memory", fallback: 80)) { active.insert(.memory) }
        let freeDisk = snapshot.diskTotal > snapshot.diskUsed ? snapshot.diskTotal - snapshot.diskUsed : 0
        if snapshot.diskTotal > 0 && Double(freeDisk) < value("alert.diskGB", fallback: 10) * 1_000_000_000 { active.insert(.disk) }
        if Double(max(snapshot.networkDownload, snapshot.networkUpload)) >= value("alert.networkMB", fallback: 50) * 1_000_000 { active.insert(.network) }
        let swapMonitoringEnabled = defaults.object(forKey: "alert.swap.enabled") as? Bool ?? true
        if swapMonitoringEnabled,
           Double(snapshot.swapUsed) >= value("alert.swapGB", fallback: 4) * 1_000_000_000 {
            active.insert(.swap)
        }
        if snapshot.isOnBattery, let percent = snapshot.batteryPercent,
           Double(percent) <= value("alert.batteryPercent", fallback: 20) { active.insert(.battery) }
        if snapshot.thermalLevel >= Int(value("alert.thermalLevel", fallback: 2)) { active.insert(.thermal) }
        if defaults.bool(forKey: "alert.camera.enabled"), MediaAccessMonitor.shared.cameraInUse { active.insert(.camera) }
        if defaults.bool(forKey: "alert.microphone.enabled"), MediaAccessMonitor.shared.microphoneInUse { active.insert(.microphone) }
        activeMetrics = active
        return active
    }

    private func value(_ key: String, fallback: Double) -> Double {
        SettingValue.read(key, fallback: fallback, defaults: defaults)
    }
}
