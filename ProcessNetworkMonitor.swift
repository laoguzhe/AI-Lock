import Foundation

// 通过 nettop 持续采样每个进程的累计收发字节，换算成每秒速率（字节/秒）。
final class ProcessNetworkMonitor {
    struct Sample { var bytesIn: UInt64; var bytesOut: UInt64 }
    typealias Rate = (down: Double, up: Double)

    private let queue = DispatchQueue(label: "com.laogu.ailock.process-network")
    private var task: Process?
    private var pending = ""
    private var lastSample: [pid_t: Sample] = [:]
    private var lastDate: Date?
    private var currentSample: [pid_t: Sample] = [:]
    private var currentDate: Date?
    private var rates: [pid_t: Rate] = [:]
    private let regex = try! NSRegularExpression(pattern: #"^\S+\s+(.*?)\.(\d+)\s+(.*)$"#)

    func start() {
        guard task == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-x", "-l", "0"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.queue.async { self?.ingest(text) }
        }
        do { try process.run() } catch { return }
        task = process
    }

    func stop() {
        guard let process = task else { return }
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process.terminate()
        task = nil
    }

    func currentRates() -> [pid_t: Rate] { queue.sync { rates } }

    private func ingest(_ text: String) {
        pending += text
        while let index = pending.firstIndex(of: "\n") {
            let line = String(pending[pending.startIndex..<index])
            pending = String(pending[pending.index(after: index)...])
            processLine(line)
        }
    }

    private func processLine(_ line: String) {
        guard !line.isEmpty else { return }
        if line.hasPrefix("time") {
            finishSample()
            currentSample = [:]
            currentDate = Date()
            return
        }
        let ns = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              let pid = pid_t(ns.substring(with: match.range(at: 2))) else { return }
        var numbers: [UInt64] = []
        for token in ns.substring(with: match.range(at: 3)).split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            if let value = UInt64(token) {
                numbers.append(value)
                if numbers.count == 2 { break }
            }
        }
        guard numbers.count == 2 else { return }
        currentSample[pid] = Sample(bytesIn: numbers[0], bytesOut: numbers[1])
    }

    private func finishSample() {
        defer {
            lastSample = currentSample
            lastDate = currentDate
        }
        guard let currentDate, let lastDate else { return }
        let interval = max(currentDate.timeIntervalSince(lastDate), 0.1)
        var updated: [pid_t: Rate] = [:]
        for (pid, sample) in currentSample {
            guard let previous = lastSample[pid] else { continue }
            let down = Double(sample.bytesIn >= previous.bytesIn ? sample.bytesIn - previous.bytesIn : 0) / interval
            let up = Double(sample.bytesOut >= previous.bytesOut ? sample.bytesOut - previous.bytesOut : 0) / interval
            updated[pid] = (down, up)
        }
        rates = updated
    }
}
