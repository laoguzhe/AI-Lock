import AppKit
import Darwin
import Foundation

struct MonitoredProcess: Identifiable {
    let pid: pid_t
    let name: String
    let executablePath: String
    let cpuPercent: Double
    let memoryBytes: UInt64
    let startTime: Date?
    let isProtected: Bool

    var id: Int32 { pid }
}

enum ProcessSort: String, CaseIterable {
    case cpu = "CPU"
    case memory = "内存"
    case name = "名称"
}

final class ProcessMonitor {
    private var previousCPUTicks: [pid_t: UInt64] = [:]
    private var previousSampleTime = Date()

    func sample() -> [MonitoredProcess] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let bytes = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard bytes > 0 else { return [] }
        let now = Date()
        let elapsed = max(now.timeIntervalSince(previousSampleTime), 0.1)
        var currentTicks: [pid_t: UInt64] = [:]
        var result: [MonitoredProcess] = []

        for pid in pids.prefix(Int(bytes)) where pid > 0 {
            var info = proc_taskallinfo()
            let size = Int32(MemoryLayout<proc_taskallinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, size) == size else { continue }
            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let path = pathLength > 0 ? String(cString: pathBuffer) : ""
            var command = info.pbsd.pbi_comm
            let name = withUnsafeBytes(of: &command) { bytes in
                let chars = bytes.bindMemory(to: CChar.self)
                return String(cString: chars.baseAddress!)
            }
            let ticks = UInt64(info.ptinfo.pti_total_user) &+ UInt64(info.ptinfo.pti_total_system)
            currentTicks[pid] = ticks
            let previous = previousCPUTicks[pid] ?? ticks
            let cpu = min(max(Double(ticks >= previous ? ticks - previous : 0) / 1_000_000_000 / elapsed * 100, 0), 100 * Double(ProcessInfo.processInfo.processorCount))
            let processStart = Date(timeIntervalSince1970: TimeInterval(info.pbsd.pbi_start_tvsec) + TimeInterval(info.pbsd.pbi_start_tvusec) / 1_000_000)
            result.append(MonitoredProcess(pid: pid, name: name, executablePath: path,
                                           cpuPercent: cpu, memoryBytes: UInt64(info.ptinfo.pti_resident_size),
                                           startTime: processStart, isProtected: Self.isProtected(pid: pid, path: path)))
        }
        previousCPUTicks = currentTicks
        previousSampleTime = now
        return result
    }

    private static func isProtected(pid: pid_t, path: String) -> Bool {
        if pid <= 1 || pid == getpid() { return true }
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/") { return true }
        let protectedNames: Set<String> = ["launchd", "kernel_task", "WindowServer", "loginwindow", "Dock", "Finder", "runningboardd", "notifyd", "opendirectoryd", "AILock"]
        let name = path.isEmpty ? (ProcessInfo.processInfo.processName) : URL(fileURLWithPath: path).lastPathComponent
        return protectedNames.contains(name)
    }
}
