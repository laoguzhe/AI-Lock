import Foundation
import IOKit.ps

struct HardwareSnapshot {
    let model: String
    let architecture: String
    let batteryPercent: Int?
    let powerSource: String
    let temperature: String
    let fanSpeed: String

    static func read() -> HardwareSnapshot {
        let model = sysctlString("hw.model") ?? "未知设备"
        let architecture = sysctlString("hw.machine") ?? "未知架构"
        var batteryPercent: Int?
        var sourceName = "外接电源或台式机"
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { continue }
                if let current = description[kIOPSCurrentCapacityKey] as? Int,
                   let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                    batteryPercent = current * 100 / maximum
                    sourceName = description[kIOPSPowerSourceStateKey] as? String ?? "电池供电"
                    break
                }
            }
        }
        return HardwareSnapshot(model: model, architecture: architecture, batteryPercent: batteryPercent,
                                powerSource: sourceName, temperature: "系统未提供公开传感器数据",
                                fanSpeed: "系统未提供公开传感器数据")
    }

    private static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
