import Darwin
import Foundation
import IOKit

struct NetworkConnection: Identifiable {
    let id: String
    let pid: Int32
    let process: String
    let protocolName: String
    let local: String
    let remote: String
    let state: String
    var processStartTime: Date? = nil
}

enum NetworkInspector {
    static func connections() throws -> [NetworkConnection] {
        let output = try CommandRunner.run("/usr/sbin/lsof", arguments: ["-nP", "-iTCP", "-iUDP", "-FpcfPnT"], allowEmptyExit: true)
        var entries = parse(output)
        var starts: [pid_t: Date] = [:]
        for pid in Set(entries.map(\.pid)) {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
                starts[pid] = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
            }
        }
        for index in entries.indices { entries[index].processStartTime = starts[entries[index].pid] }
        return entries
    }

    static func parse(_ output: String) -> [NetworkConnection] {
        var pid: Int32 = 0
        var process = "未归属"
        var local = ""
        var remote = ""
        var state = ""
        var descriptor = ""
        var protocolName = "TCP"
        var entries: [NetworkConnection] = []
        for line in output.components(separatedBy: .newlines) {
            guard let prefix = line.first else { continue }
            let value = String(line.dropFirst())
            switch prefix {
            case "p":
                if !local.isEmpty || !remote.isEmpty {
                    appendConnection(pid: pid, process: process, local: local, remote: remote, state: state, descriptor: descriptor, protocolName: protocolName, to: &entries)
                }
                pid = Int32(value) ?? 0
                process = "未归属"
                protocolName = "TCP"; descriptor = ""; local = ""; remote = ""; state = ""
            case "f":
                appendConnection(pid: pid, process: process, local: local, remote: remote, state: state, descriptor: descriptor, protocolName: protocolName, to: &entries)
                protocolName = "TCP"; descriptor = value; local = ""; remote = ""; state = ""
            case "c": process = value
            case "P": protocolName = value
            case "n":
                let endpoints = value.components(separatedBy: "->")
                if endpoints.count == 2 { local = endpoints[0]; remote = endpoints[1] }
                else { local = value; remote = "*" }
            case "T":
                if value.hasPrefix("ST=") { state = String(value.dropFirst(3)) }
            default: continue
            }
        }
        appendConnection(pid: pid, process: process, local: local, remote: remote, state: state, descriptor: descriptor, protocolName: protocolName, to: &entries)
        return entries
    }

    private static func appendConnection(pid: Int32, process: String, local: String, remote: String, state: String, descriptor: String, protocolName: String, to entries: inout [NetworkConnection]) {
        guard !local.isEmpty, protocolName == "TCP" || protocolName == "UDP" else { return }
        let id = "\(pid)|\(descriptor)|\(local)|\(remote)|\(protocolName)"
        entries.append(NetworkConnection(id: id, pid: pid, process: process, protocolName: protocolName,
                                         local: local, remote: remote, state: protocolName == "UDP" ? (remote == "*" ? "UNCONNECTED" : "CONNECTED") : state))
    }
}
