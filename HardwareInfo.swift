import Foundation
import IOKit
import IOKit.ps
import CoreGraphics

struct HardwareSnapshot {
    let model: String
    let modelName: String
    let serialNumber: String?
    let architecture: String
    let chip: String
    let coreCount: String
    let memory: String
    let displaySummary: String
    let batteryPercent: Int?
    let batteryState: String
    let powerSource: String
    let temperature: String
    let fanSpeed: String

    static func read() -> HardwareSnapshot {
        let model = sysctlString("hw.model") ?? "未知设备"
        let overview = readSystemHardwareOverview()
        let modelName = overview["machine_name"] as? String ?? overview["machine_model"] as? String ?? model
        let serialNumber = readSerialNumber()
        let architecture = sysctlString("machdep.cpu.brand_string") ?? sysctlString("hw.machine") ?? "未知芯片"
        let chip = overview["chip_type"] as? String ?? architecture
        let coreCount = (overview["number_processors"] as? String)?
            .split(whereSeparator: { !$0.isNumber }).first.map(String.init)
            ?? String(ProcessInfo.processInfo.activeProcessorCount)
        let memory = overview["physical_memory"] as? String ?? ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)
        var batteryPercent: Int?
        var batteryState = "无内置电池（台式机或未读取到电池）"
        var sourceName = "外接电源或台式机"
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { continue }
                if let current = description[kIOPSCurrentCapacityKey] as? Int,
                   let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                    batteryPercent = min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
                    let powerState = description[kIOPSPowerSourceStateKey] as? String
                    let isCharging = description[kIOPSIsChargingKey] as? Bool == true
                    let isCharged = description[kIOPSIsChargedKey] as? Bool == true
                    if powerState == kIOPSBatteryPowerValue {
                        batteryState = "正在放电（使用电池）"
                    } else if isCharging {
                        batteryState = "正在充电"
                    } else if isCharged {
                        batteryState = "已充满"
                    } else if powerState == kIOPSACPowerValue {
                        batteryState = "已接电源，当前未充电"
                    }
                    sourceName = powerState ?? "未知电源"
                    break
                }
            }
        }
        let sensorReadings = AppleSMCSensors.read()
        return HardwareSnapshot(model: model, modelName: modelName, serialNumber: serialNumber, architecture: architecture,
                                chip: chip, coreCount: coreCount, memory: memory, displaySummary: activeDisplaySummary(),
                                batteryPercent: batteryPercent, batteryState: batteryState,
                                powerSource: sourceName, temperature: sensorReadings.temperature,
                                fanSpeed: sensorReadings.fans)
    }

    private static func readSystemHardwareOverview() -> [String: Any] {
        guard let output = try? CommandRunner.run("/usr/sbin/system_profiler", arguments: ["SPHardwareDataType", "-json"], timeout: 8),
              let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hardware = root["SPHardwareDataType"] as? [[String: Any]] else { return [:] }
        return hardware.first(where: { $0["_name"] as? String == "hardware_overview" }) ?? hardware.first ?? [:]
    }

    private static func readSerialNumber() -> String? {
        let matching = IOServiceMatching("IOPlatformExpertDevice")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "IOPlatformSerialNumber" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else {
            return nil
        }
        let serialNumber = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return serialNumber.isEmpty ? nil : serialNumber
    }

    private static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func activeDisplaySummary() -> String {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return "显示器信息不可用" }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return "显示器信息不可用" }
        let resolutions = displays.prefix(Int(count)).compactMap { id -> String? in
            guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
            return "\(mode.pixelWidth)×\(mode.pixelHeight)"
        }
        let displayCount = L10n.format("%{0} 台显示器", arguments: [String(count)])
        guard !resolutions.isEmpty else { return displayCount }
        return displayCount + " · " + resolutions.joined(separator: ", ")
    }
}

/// Read-only AppleSMC access, following the message layout and sensor-key
/// conventions used by SMCKit and MacMonitor. SMC key availability and formats
/// vary by Mac model, so absent or undecodable values stay unavailable.
private enum AppleSMCSensors {
    private struct Version { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
    private struct PLimit { var version: UInt16 = 0; var length: UInt16 = 0; var cpu: UInt32 = 0; var gpu: UInt32 = 0; var memory: UInt32 = 0 }
    private struct KeyInfo { var size: UInt32 = 0; var type: UInt32 = 0; var attributes: UInt8 = 0 }
    private typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                               UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                               UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                               UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    private struct Parameter {
        var key: UInt32 = 0
        var version = Version()
        var limit = PLimit()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    static func read() -> (temperature: String, fans: String) {
        guard MemoryLayout<Parameter>.stride == 80 else {
            return ("温度传感器不可用", "风扇传感器不可用")
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return ("温度传感器不可用", "风扇传感器不可用") }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else {
            return ("温度传感器不可用", "风扇传感器不可用")
        }
        defer { IOServiceClose(connection) }
        let reader = Reader(connection: connection)
        return (reader.temperatureSummary(), reader.fanSummary())
    }

    private struct Reader {
        let connection: io_connect_t

        func temperatureSummary() -> String {
            let cpu = firstValue(["TCMz", "TCMb", "TC0D", "TC0P", "TC0F"])
                ?? averageValues(prefixes: ["Tp", "Te"])
            let gpu = firstValue(["TRDX", "TG0D", "TG0P"])
                ?? averageValues(prefixes: ["Tg"])
            let soc = firstValue(["TPMP"])
            let ssd = firstValue(["T5SP", "TH0T", "Ts1P"])
            let battery = firstValue(["TB0T", "TB1T", "TB2T"])
            var fields: [String] = []
            if let cpu { fields.append(L10n.format("%{0} %{1}°C", arguments: [L10n.text("CPU"), format(cpu)])) }
            if let gpu { fields.append(L10n.format("%{0} %{1}°C", arguments: [L10n.text("GPU"), format(gpu)])) }
            if let soc { fields.append(L10n.format("%{0} %{1}°C", arguments: [L10n.text("SoC"), format(soc)])) }
            if let ssd { fields.append(L10n.format("%{0} %{1}°C", arguments: [L10n.text("SSD"), format(ssd)])) }
            if let battery { fields.append(L10n.format("%{0} %{1}°C", arguments: [L10n.text("电池"), format(battery)])) }
            return fields.isEmpty ? "温度传感器不可用" : fields.joined(separator: " · ")
        }

        func fanSummary() -> String {
            let reportedCount = readValue("FNum").flatMap { value -> Int? in
                value.isFinite && (0...15).contains(value) ? Int(value) : nil
            }
            if reportedCount == 0 { return "无风扇（被动散热）" }
            let indexes = reportedCount.map { Array(0..<$0) } ?? Array(0..<8)
            let speeds = indexes.compactMap { index -> String? in
                guard let rpm = readValue("F\(index)Ac"), rpm.isFinite, rpm >= 0 else { return nil }
                let minimum = readValue("F\(index)Mn").flatMap { $0.isFinite && $0 > 0 ? Int($0.rounded()) : nil }
                let maximum = readValue("F\(index)Mx").flatMap { $0.isFinite && $0 > 0 ? Int($0.rounded()) : nil }
                let range = minimum.flatMap { minRPM in
                    maximum.map { L10n.format("（%{0}–%{1}）", arguments: [String(minRPM), String($0)]) }
                } ?? ""
                return L10n.format("风扇%{0} %{1} RPM", arguments: [String(index + 1), String(Int(rpm.rounded()))]) + range
            }
            if reportedCount == nil && speeds.isEmpty { return "风扇传感器不可用" }
            if reportedCount == nil && !speeds.isEmpty { return speeds.joined(separator: " · ") }
            let fanCount = reportedCount ?? 0
            return speeds.isEmpty
                ? L10n.format("检测到 %{0} 个风扇，转速不可用", arguments: [String(fanCount)])
                : speeds.joined(separator: " · ")
        }

        private func firstValue(_ keys: [String]) -> Double? {
            keys.compactMap(readValue).first(where: { (0...125).contains($0) })
        }

        private func averageValues(prefixes: [String]) -> Double? {
            let letters = Array("0123456789abcdefghijklmnopqrstuvwxyz")
            let keys = prefixes.flatMap { prefix in letters.map { prefix + "0" + String($0) } }
            let values = keys.compactMap(readValue).filter { (0...125).contains($0) }
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }

        private func readValue(_ name: String) -> Double? {
            guard let key = fourCC(name),
                  let info = call(key: key, command: 9), info.result == 0,
                  info.keyInfo.size > 0, info.keyInfo.size <= 32 else { return nil }
            var input = Parameter()
            input.key = key
            input.keyInfo.size = info.keyInfo.size
            input.command = 5
            guard let output = invoke(input), output.result == 0 else { return nil }
            let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.keyInfo.size))) }
            let type = info.keyInfo.type
            if type == fourCC("flt "), bytes.count >= 4 {
                let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
                let value = Double(Float(bitPattern: raw))
                return value.isFinite ? value : nil
            }
            if type == fourCC("sp78"), bytes.count >= 2 {
                let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
                return Double(raw) / 256
            }
            if type == fourCC("fpe2"), bytes.count >= 2 {
                return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
            }
            if type == fourCC("ui8 "), let first = bytes.first { return Double(first) }
            if type == fourCC("ui16"), bytes.count >= 2 { return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) }
            return nil
        }

        private func call(key: UInt32, command: UInt8) -> Parameter? {
            var input = Parameter()
            input.key = key
            input.command = command
            return invoke(input)
        }

        private func invoke(_ input: Parameter) -> Parameter? {
            var input = input
            var output = Parameter()
            var outputSize = MemoryLayout<Parameter>.stride
            let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<Parameter>.stride,
                                                   &output, &outputSize)
            return result == kIOReturnSuccess ? output : nil
        }

        private func fourCC(_ text: String) -> UInt32? {
            let bytes = Array(text.utf8)
            guard bytes.count == 4 else { return nil }
            return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }

        private func format(_ value: Double) -> String { String(format: "%.1f", value) }
    }
}

enum MachineInspectionStatus {
    case passed
    case attention
    case informational
    case unavailable
}

struct MachineInspectionItem: Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let status: MachineInspectionStatus
}

/// Read-only, best-effort checks used during the automatic Mac health scan.
/// Hardware checks stay local; the serial number is sent to Apple only when the user opens its lookup page.
enum MachineInspection {
    static func read() -> [MachineInspectionItem] {
        [battery(), storage(), management(), fileVault(), systemIntegrity()]
    }

    private static func battery() -> MachineInspectionItem {
        let id = "battery"
        do {
            let output = try CommandRunner.run("/usr/sbin/system_profiler", arguments: ["SPPowerDataType", "-json"], timeout: 8)
            guard let data = output.data(using: .utf8),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let powerSources = root["SPPowerDataType"] as? [[String: Any]],
                  let battery = powerSources.first(where: { $0["_name"] as? String == "spbattery_information" }) else {
                return item(id, "电池", "不适用", "未检测到内置电池（台式机或外接供电设备）", .informational)
            }
            let healthInfo = battery["sppower_battery_health_info"] as? [String: Any] ?? [:]
            let chargeInfo = battery["sppower_battery_charge_info"] as? [String: Any] ?? [:]
            let chargerInfo = powerSources.first(where: { $0["_name"] as? String == "sppower_ac_charger_information" }) ?? [:]
            let cycle = stringValue(healthInfo["sppower_battery_cycle_count"])
            let capacity = healthInfo["sppower_battery_health_maximum_capacity"] as? String
            let health = healthInfo["sppower_battery_health"] as? String
            var details: [String] = []
            if boolValue(chargeInfo["sppower_battery_is_charging"]) == true {
                details.append("正在充电")
            } else if boolValue(chargeInfo["sppower_battery_fully_charged"]) == true {
                details.append("已充满")
            } else if boolValue(chargerInfo["sppower_battery_charger_connected"]) == true {
                details.append("已接电源，当前未充电")
            } else if boolValue(chargerInfo["sppower_battery_charger_connected"]) == false {
                details.append("正在放电（使用电池）")
            } else {
                details.append("充放电状态未知")
            }
            if let cycle { details.append("循环次数 \(cycle) 次") }
            if let capacity { details.append("最大容量 \(capacity)") }
            let unhealthy = health?.localizedCaseInsensitiveContains("service") == true
                || health?.localizedCaseInsensitiveContains("replace") == true
                || (capacity.flatMap { Int($0.filter(\.isNumber)) }.map { $0 < 80 } ?? false)
            let hasHealthData = health != nil || capacity != nil || cycle != nil
            let healthLabel: String
            switch health?.lowercased() {
            case "good": healthLabel = "状态正常"
            case "replace soon", "replace now", "service recommended": healthLabel = "建议检查或维修"
            default: healthLabel = health ?? (capacity.map { "设计容量健康度 \($0)%" } ?? (hasHealthData ? "已读取电池数据" : "健康数据不可用"))
            }
            let status: MachineInspectionStatus = unhealthy ? .attention : hasHealthData ? .passed : .unavailable
            return item(id, "电池", healthLabel, details.joined(separator: " · "), status)
        } catch {
            return item(id, "电池", "暂不可读取", "读取电池健康数据失败", .unavailable)
        }
    }

    private static func storage() -> MachineInspectionItem {
        do {
            let output = try CommandRunner.run("/usr/sbin/diskutil", arguments: ["info", "-plist", "/"], timeout: 5)
            guard let data = output.data(using: .utf8),
                  let info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let smart = info["SMARTStatus"] as? String else {
                return item("storage", "存储健康", "未提供状态", "当前存储设备或文件系统未公开 S.M.A.R.T. 状态", .unavailable)
            }
            if smart.localizedCaseInsensitiveContains("verified") {
                return item("storage", "存储健康", "S.M.A.R.T 正常", "系统报告存储设备状态正常", .passed)
            }
            if smart.localizedCaseInsensitiveContains("failing") {
                return item("storage", "存储健康", "检测到异常", "系统报告存储设备可能存在故障", .attention)
            }
            return item("storage", "存储健康", smart, "系统返回的设备状态", .informational)
        } catch {
            return item("storage", "存储健康", "未读取到状态", "无法从当前卷读取设备 S.M.A.R.T. 状态", .unavailable)
        }
    }

    private static func management() -> MachineInspectionItem {
        do {
            let output = try CommandRunner.run("/usr/bin/profiles", arguments: ["status", "-type", "enrollment"], timeout: 5)
            if output.localizedCaseInsensitiveContains("MDM enrollment: Yes") {
                return item("management", "远程管理", "已注册 MDM", "如果用于转售或交付，请确认组织已解除此设备的管理", .attention)
            }
            if output.localizedCaseInsensitiveContains("MDM enrollment: No") {
                return item("management", "远程管理", "未发现 MDM 注册", "当前系统报告未注册移动设备管理", .passed)
            }
            return item("management", "远程管理", "状态不明确", "系统返回的信息不足以判断 MDM 注册状态", .unavailable)
        } catch {
            return item("management", "远程管理", "暂不可读取", "无法读取本机 MDM 注册状态", .unavailable)
        }
    }

    private static func fileVault() -> MachineInspectionItem {
        do {
            let output = try CommandRunner.run("/usr/bin/fdesetup", arguments: ["status"], timeout: 5)
            if output.localizedCaseInsensitiveContains("FileVault is On") {
                return item("filevault", "磁盘加密", "FileVault 已开启", "交付前确认客户是否需要保留加密设置", .passed)
            }
            if output.localizedCaseInsensitiveContains("FileVault is Off") {
                return item("filevault", "磁盘加密", "FileVault 未开启", "这是安全设置提示，不代表硬件故障", .informational)
            }
            return item("filevault", "磁盘加密", "状态不明确", output.trimmingCharacters(in: .whitespacesAndNewlines), .unavailable)
        } catch {
            return item("filevault", "磁盘加密", "暂不可读取", "无法读取 FileVault 状态", .unavailable)
        }
    }

    private static func systemIntegrity() -> MachineInspectionItem {
        do {
            let output = try CommandRunner.run("/usr/bin/csrutil", arguments: ["status"], timeout: 5)
            if output.localizedCaseInsensitiveContains("System Integrity Protection status: enabled") {
                return item("sip", "系统完整性", "SIP 已开启", "系统完整性保护处于开启状态", .passed)
            }
            if output.localizedCaseInsensitiveContains("System Integrity Protection status: disabled") {
                return item("sip", "系统完整性", "SIP 已关闭", "建议确认这是客户预期的安全配置", .attention)
            }
            return item("sip", "系统完整性", "状态不明确", "系统未返回可识别的 SIP 状态", .unavailable)
        } catch {
            return item("sip", "系统完整性", "暂不可读取", "无法读取系统完整性保护状态", .unavailable)
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let number = value as? NSNumber { return number.stringValue }
        return value as? String
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? String {
            switch value.uppercased() {
            case "TRUE", "YES": return true
            case "FALSE", "NO": return false
            default: return nil
            }
        }
        return nil
    }

    private static func item(_ id: String, _ title: String, _ value: String, _ detail: String, _ status: MachineInspectionStatus) -> MachineInspectionItem {
        MachineInspectionItem(id: id, title: title, value: value, detail: detail, status: status)
    }
}
