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
    let userID: uid_t
    var ports: [Int] = []
    var networkDown: Double = 0
    var networkUp: Double = 0

    var id: Int32 { pid }
}

enum ProcessPortScanner {
    static func listeningPorts() throws -> [pid_t: [Int]] {
        let output = try CommandRunner.run("/usr/sbin/lsof", arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"], allowEmptyExit: true)
        var result: [pid_t: [Int]] = [:]
        var pid: pid_t = 0
        for line in output.components(separatedBy: .newlines) {
            guard let prefix = line.first else { continue }
            let value = String(line.dropFirst())
            switch prefix {
            case "p": pid = pid_t(value) ?? 0
            case "n":
                guard pid > 0, let portToken = value.split(separator: ":").last, let port = Int(portToken), (1...65535).contains(port) else { continue }
                if !(result[pid]?.contains(port) ?? false) { result[pid, default: []].append(port) }
            default: continue
            }
        }
        return result
    }
}

enum ProcessSort: String, CaseIterable {
    case cpu = "CPU"
    case memory = "内存"
    case name = "名称"
}

final class ProcessMonitor {
    private var previousCPUTicks: [pid_t: UInt64] = [:]
    private var previousSampleTime = ProcessInfo.processInfo.systemUptime
    private var previousStartTimes: [pid_t: Date] = [:]

    func sample() -> [MonitoredProcess] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let bytes = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard bytes > 0 else { return [] }
        let uptime = ProcessInfo.processInfo.systemUptime
        let elapsed = max(uptime - previousSampleTime, 0.1)
        var currentStartTimes: [pid_t: Date] = [:]
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
            let processStart = Date(timeIntervalSince1970: TimeInterval(info.pbsd.pbi_start_tvsec) + TimeInterval(info.pbsd.pbi_start_tvusec) / 1_000_000)
            currentStartTimes[pid] = processStart
            let previous = previousStartTimes[pid] == processStart ? (previousCPUTicks[pid] ?? ticks) : ticks
            let cpu = min(max(Double(ticks >= previous ? ticks - previous : 0) / 1_000_000_000 / elapsed * 100, 0), 100 * Double(ProcessInfo.processInfo.processorCount))
            result.append(MonitoredProcess(pid: pid, name: name, executablePath: path,
                                           cpuPercent: cpu, memoryBytes: UInt64(info.ptinfo.pti_resident_size),
                                           startTime: processStart, isProtected: Self.isProtected(pid: pid, path: path) || info.pbsd.pbi_uid != getuid(),
                                           userID: info.pbsd.pbi_uid))
        }
        previousCPUTicks = currentTicks
        previousStartTimes = currentStartTimes
        previousSampleTime = uptime
        return result
    }

    static func canSignal(_ process: MonitoredProcess) -> Bool {
        guard !process.isProtected, process.userID == getuid(), let expectedStart = process.startTime,
              !isProtected(pid: process.pid, path: process.executablePath) else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(process.pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == getuid() else { return false }
        let start = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(process.pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { return false }
        let path = String(cString: pathBuffer)
        return start == expectedStart && path == process.executablePath && !isProtected(pid: process.pid, path: path)
    }

    // nil means identity could not be checked; never treat that as a successful exit.
    static func isSameProcess(_ process: MonitoredProcess) -> Bool? {
        guard let expectedStart = process.startTime else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(process.pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return errno == ESRCH ? false : nil
        }
        if info.pbi_status == UInt32(SZOMB) { return false }
        let start = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
        return start == expectedStart && info.pbi_uid == process.userID
    }

    private static func isProtected(pid: pid_t, path: String) -> Bool {
        if path.isEmpty || pid <= 1 || pid == getpid() { return true }
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/lib/") || path.hasPrefix("/usr/sbin/") || path.hasPrefix("/sbin/") { return true }
        let protectedNames: Set<String> = ["launchd", "kernel_task", "WindowServer", "loginwindow", "Dock", "Finder", "runningboardd", "notifyd", "opendirectoryd", "AILock"]
        let name = path.isEmpty ? (ProcessInfo.processInfo.processName) : URL(fileURLWithPath: path).lastPathComponent
        return protectedNames.contains(name)
    }
}

enum ProcessBulkCloser {
    struct Result {
        let process: MonitoredProcess
        let message: String
        let exited: Bool
    }

    static func targets(in entries: [MonitoredProcess]) -> [MonitoredProcess] {
        entries.filter { ProcessMonitor.canSignal($0) }.sorted {
            if $0.name == $1.name { return $0.pid < $1.pid }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // Only the confirmed snapshot is used. New processes are never added during execution.
    // Run off the main thread so the grace period cannot freeze the interface.
    static func close(_ targets: [MonitoredProcess], gracePeriod: TimeInterval = 3, verificationPeriod: TimeInterval = 1) -> [Result] {
        var pending: [MonitoredProcess] = []
        var results: [Result] = []
        var errors: [pid_t: String] = [:]
        for process in targets {
            guard ProcessMonitor.canSignal(process) else {
                let ended = ProcessMonitor.isSameProcess(process) == false
                results.append(Result(process: process, message: ended ? "已结束" : "已跳过：身份变化或受到保护", exited: ended))
                continue
            }
            if kill(process.pid, SIGTERM) != 0 { errors[process.pid] = String(cString: strerror(errno)) }
            pending.append(process)
        }
        waitForExit(pending, timeout: gracePeriod)
        for process in pending where ProcessMonitor.isSameProcess(process) == true {
            guard ProcessMonitor.canSignal(process) else {
                errors[process.pid] = "身份校验失败或受到保护"
                continue
            }
            if kill(process.pid, SIGKILL) != 0 { errors[process.pid] = String(cString: strerror(errno)) }
        }
        waitForExit(pending, timeout: verificationPeriod)
        for process in pending {
            let identity = ProcessMonitor.isSameProcess(process)
            let ended = identity == false
            let message = ended ? "已结束" : errors[process.pid].map { "关闭失败：\($0)" } ?? (identity == nil ? "无法核实退出结果" : "仍在运行")
            results.append(Result(process: process, message: message, exited: ended))
        }
        return results.sorted { $0.process.pid < $1.process.pid }
    }

    private static func waitForExit(_ targets: [MonitoredProcess], timeout: TimeInterval) {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while ProcessInfo.processInfo.systemUptime < deadline {
            if targets.allSatisfy({ ProcessMonitor.isSameProcess($0) == false }) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
