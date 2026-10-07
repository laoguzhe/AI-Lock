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
        // Public APIs do not provide a complete socket-to-process table for an ordinary app.
        // netstat -n is used for connection metadata; PID attribution remains unavailable here.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        task.arguments = ["-anv", "-p", "tcp"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return output.components(separatedBy: .newlines).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 6, fields[0].hasPrefix("tcp") else { return nil }
            return NetworkConnection(id: line, pid: 0, process: "未归属", protocolName: fields[0],
                                     local: fields[3], remote: fields[4], state: fields[5])
        }
    }
}
