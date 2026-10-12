import AppKit
import Darwin
import IOKit
import IOKit.ps
import MachO

struct SystemSnapshot {
    var cpuUsage: Double
    var userCPU: Double
    var systemCPU: Double
    var memoryUsed: UInt64
    var memoryTotal: UInt64
    var memoryPressure: String
    var diskUsed: UInt64
    var diskTotal: UInt64
    var networkDownload: UInt64
    var networkUpload: UInt64
    var totalReceived: UInt64
    var totalSent: UInt64
    var swapUsed: UInt64
    var batteryPercent: Int? = nil
    var isOnBattery = false
    // ProcessInfo thermal state: nominal=0, fair=1, serious=2, critical=3.
    var thermalLevel = 0
    var networkSampleDuration: TimeInterval = 0
    var timestamp: Date

    static let empty = SystemSnapshot(cpuUsage: 0, userCPU: 0, systemCPU: 0,
                                      memoryUsed: 0, memoryTotal: 0, memoryPressure: "读取中",
                                      diskUsed: 0, diskTotal: 0, networkDownload: 0,
                                      networkUpload: 0, totalReceived: 0, totalSent: 0,
                                      swapUsed: 0,
                                      timestamp: .now)
}


struct NetworkCounters {
    var received: UInt64
    var sent: UInt64
}

/// Compare only interfaces present in both successful samples. A newly attached
/// interface's lifetime counters are a baseline, never traffic for this interval.
struct NetworkCounterTracker {
    private var previous: [String: NetworkCounters]?
    private var previousTime: TimeInterval?
    private var totals = NetworkCounters(received: 0, sent: 0)

    mutating func sample(_ interfaces: [String: NetworkCounters]?, at time: TimeInterval)
        -> (download: UInt64, upload: UInt64, received: UInt64, sent: UInt64, duration: TimeInterval) {
        guard let interfaces, time.isFinite else {
            // A failed read invalidates the baseline so recovery cannot create a spike.
            previous = nil
            previousTime = nil
            return (0, 0, totals.received, totals.sent, 0)
        }
        func sum(_ values: [UInt64]) -> UInt64 {
            values.reduce(0) { partial, value in
                let result = partial.addingReportingOverflow(value)
                return result.overflow ? UInt64.max : result.partialValue
            }
        }
        totals = NetworkCounters(received: sum(interfaces.values.map(\.received)),
                                 sent: sum(interfaces.values.map(\.sent)))
        defer { previous = interfaces; previousTime = time }
        guard let previous, let previousTime, time > previousTime else {
            return (0, 0, totals.received, totals.sent, 0)
        }
        var received: [UInt64] = []
        var sent: [UInt64] = []
        for (name, current) in interfaces {
            guard let old = previous[name] else { continue }
            received.append(current.received >= old.received ? current.received - old.received : 0)
            sent.append(current.sent >= old.sent ? current.sent - old.sent : 0)
        }
        func rate(_ bytes: UInt64) -> UInt64 {
            let value = Double(bytes) / (time - previousTime)
            // Double(UInt64.max) rounds upward: check before conversion.
            guard value.isFinite, value < Double(UInt64.max) else { return UInt64.max }
            return UInt64(max(0, value))
        }
        return (rate(sum(received)), rate(sum(sent)), totals.received, totals.sent, time - previousTime)
    }
}

final class SystemMonitor {
    private var previousCPUTicks: [UInt64]?
    private var networkTracker = NetworkCounterTracker()
    private var pressureSource: DispatchSourceMemoryPressure?
    private var currentPressure = "正常"
    private let pressureLock = NSLock()

    init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let events = self?.pressureSource?.data else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pressureLock.lock()
                defer { self.pressureLock.unlock() }
                if events.contains(.critical) { self.currentPressure = "严重" }
                else if events.contains(.warning) { self.currentPressure = "偏高" }
                else { self.currentPressure = "正常" }
            }
        }
        pressureSource = source
        source.resume()
    }

    deinit { pressureSource?.cancel() }

    func sample() -> SystemSnapshot {
        var snapshot = SystemSnapshot.empty
        let cpu = readCPU()
        snapshot.cpuUsage = cpu.total
        snapshot.userCPU = cpu.user
        snapshot.systemCPU = cpu.system

        let memory = readMemory()
        snapshot.memoryUsed = memory.used
        snapshot.memoryTotal = memory.total
        snapshot.memoryPressure = memory.pressure
        snapshot.swapUsed = readSwapUsed()
        snapshot.thermalLevel = ProcessInfo.processInfo.thermalState.rawValue
        let battery = readBattery()
        snapshot.batteryPercent = battery.percent
        snapshot.isOnBattery = battery.onBattery

        let disk = readDisk()
        snapshot.diskUsed = disk.used
        snapshot.diskTotal = disk.total

        let network = networkTracker.sample(readNetwork(), at: ProcessInfo.processInfo.systemUptime)
        snapshot.networkDownload = network.download
        snapshot.networkUpload = network.upload
        snapshot.totalReceived = network.received
        snapshot.totalSent = network.sent
        snapshot.networkSampleDuration = network.duration
        snapshot.timestamp = Date()
        return snapshot
    }

    private func readBattery() -> (percent: Int?, onBattery: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, false) }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return (min(100, max(0, Int(Double(current) / Double(maximum) * 100))),
                    description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue)
        }
        return (nil, false)
    }

    private func readCPU() -> (total: Double, user: Double, system: Double) {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0, 0) }

        let current = [UInt64(info.cpu_ticks.0), UInt64(info.cpu_ticks.1),
                       UInt64(info.cpu_ticks.2), UInt64(info.cpu_ticks.3)]
        defer { previousCPUTicks = current }
        guard let previousCPUTicks else { return (0, 0, 0) }
        let deltas = zip(current, previousCPUTicks).map { $0 >= $1 ? $0 - $1 : 0 }
        let sum = max(deltas.reduce(0, +), 1)
        let userIndex = Int(CPU_STATE_USER)
        let niceIndex = Int(CPU_STATE_NICE)
        let systemIndex = Int(CPU_STATE_SYSTEM)
        let idleIndex = Int(CPU_STATE_IDLE)
        let userTicks = deltas[userIndex] + deltas[niceIndex]
        let user = Double(userTicks) / Double(sum)
        let system = Double(deltas[systemIndex]) / Double(sum)
        let idle = Double(deltas[idleIndex]) / Double(sum)
        return (min(max(1 - idle, 0), 1), user, system)
    }

    private func readMemory() -> (used: UInt64, total: UInt64, pressure: String) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let pageSize = UInt64(vm_kernel_page_size)
        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS else { return (0, total, "不可用") }

        let free = UInt64(stats.free_count + stats.inactive_count + stats.speculative_count) * pageSize
        let used = total > free ? total - free : 0
        pressureLock.lock(); let pressure = currentPressure; pressureLock.unlock()
        return (used, total, pressure)
    }

    private func readDisk() -> (used: UInt64, total: UInt64) {
        let path = URL(fileURLWithPath: NSHomeDirectory()).path
        var stats = statfs()
        guard statfs(path, &stats) == 0 else { return (0, 0) }
        let total = UInt64(stats.f_blocks) * UInt64(stats.f_bsize)
        let available = UInt64(stats.f_bavail) * UInt64(stats.f_bsize)
        return (total > available ? total - available : 0, total)
    }

    private func readSwapUsed() -> UInt64 {
        var size = 0
        guard sysctlbyname("vm.swapusage", nil, &size, nil, 0) == 0, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<UInt64>.alignment)
        defer { raw.deallocate() }
        guard sysctlbyname("vm.swapusage", raw, &size, nil, 0) == 0 else { return 0 }
        let values = raw.assumingMemoryBound(to: xsw_usage.self).pointee
        return UInt64(values.xsu_used)
    }

    private func readNetwork() -> [String: NetworkCounters]? {
        var address: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&address) == 0, let first = address else { return nil }
        defer { freeifaddrs(address) }

        var interfaces: [String: NetworkCounters] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let data = current.pointee.ifa_data,
                  let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK),
                  let name = current.pointee.ifa_name else { continue }
            let interface = String(cString: name)
            guard interface != "lo0", !interface.hasPrefix("utun"), !interface.hasPrefix("awdl"), !interface.hasPrefix("llw") else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            interfaces[interface] = NetworkCounters(received: UInt64(counters.ifi_ibytes), sent: UInt64(counters.ifi_obytes))
        }
        return interfaces
    }
}

func formattedBytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
}

func formattedRate(_ value: UInt64) -> String {
    if value == 0 { return "0 B/s" }
    return "\(formattedBytes(value))/s"
}
