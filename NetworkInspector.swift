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
}

enum NetworkInspector {
    static func connections() -> [NetworkConnection] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-iTCP", "-FpcnT"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        var pid: Int32 = 0
        var process = "未归属"
        var local = ""
        var remote = ""
        var state = ""
        var entries: [NetworkConnection] = []
        for line in output.components(separatedBy: .newlines) {
            guard let prefix = line.first else { continue }
            let value = String(line.dropFirst())
            switch prefix {
            case "p":
                if !local.isEmpty || !remote.isEmpty {
                    appendConnection(pid: pid, process: process, local: local, remote: remote, state: state, to: &entries)
                }
                pid = Int32(value) ?? 0
                process = "未归属"
                local = ""; remote = ""; state = ""
            case "c": process = value
            case "n":
                let endpoints = value.components(separatedBy: "->")
                if endpoints.count == 2 { local = endpoints[0]; remote = endpoints[1] }
                else { local = value; remote = "*" }
            case "T":
                if value.hasPrefix("ST=") { state = String(value.dropFirst(3)) }
            default: continue
            }
        }
        appendConnection(pid: pid, process: process, local: local, remote: remote, state: state, to: &entries)
        return entries
    }

    private static func appendConnection(pid: Int32, process: String, local: String, remote: String, state: String, to entries: inout [NetworkConnection]) {
        guard !local.isEmpty else { return }
        let id = "\(pid)|\(local)|\(remote)|\(state)"
        entries.append(NetworkConnection(id: id, pid: pid, process: process, protocolName: "TCP",
                                         local: local, remote: remote, state: state))
    }
}
