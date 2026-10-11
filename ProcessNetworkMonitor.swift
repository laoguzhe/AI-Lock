import Foundation

struct NetTopParser {
    struct Sample { var bytesIn: UInt64; var bytesOut: UInt64 }
    typealias Rate = (down: Double, up: Double)
    private var pending = ""
    private var lastSample: [pid_t: Sample] = [:]
    private var lastTime: TimeInterval?
    private var currentSample: [pid_t: Sample] = [:]
    private var currentTime: TimeInterval?
    private(set) var rates: [pid_t: Rate] = [:]
    private static let regex = try! NSRegularExpression(pattern: #"^\S+\s+(.*?)\.(\d+)\s+(.*)$"#)

    mutating func ingest(_ text: String, timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        pending += text
        // A malformed stream without line endings must not grow indefinitely.
        if pending.utf8.count > 1_048_576 { self = NetTopParser(); return }
        while let index = pending.firstIndex(of: "\n") {
            let line = String(pending[..<index])
            pending = String(pending[pending.index(after: index)...])
            if line.hasPrefix("time") {
                finishSample()
                currentSample = [:]; currentTime = nil
                continue
            }
            let ns = line as NSString
            guard let match = Self.regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let pid = pid_t(ns.substring(with: match.range(at: 2))) else { continue }
            let numbers = ns.substring(with: match.range(at: 3)).split(whereSeparator: { $0 == " " || $0 == "\t" }).prefix(2).compactMap { UInt64($0) }
            guard numbers.count == 2 else { continue }
            if currentTime == nil {
                // Pipe reads may contain several frames; receive time is not the sample time.
                currentTime = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.flatMap { Self.sampleTime(String($0)) } ?? timestamp
            }
            currentSample[pid] = Sample(bytesIn: numbers[0], bytesOut: numbers[1])
        }
    }

    private static func sampleTime(_ token: String) -> TimeInterval? {
        let parts = token.split(separator: ":")
        guard parts.count == 3, let hour = Double(parts[0]), let minute = Double(parts[1]),
              let second = Double(parts[2]), (0..<24).contains(hour), (0..<60).contains(minute), (0..<60).contains(second) else { return nil }
        return hour * 3600 + minute * 60 + second
    }

    private mutating func finishSample() {
        defer { lastSample = currentSample; lastTime = currentTime }
        guard let currentTime, let lastTime, currentTime > lastTime else { rates = [:]; return }
        let interval = currentTime - lastTime
        var updated: [pid_t: Rate] = [:]
        for (pid, sample) in currentSample {
            guard let previous = lastSample[pid] else { continue }
            updated[pid] = (Double(sample.bytesIn >= previous.bytesIn ? sample.bytesIn - previous.bytesIn : 0) / interval,
                            Double(sample.bytesOut >= previous.bytesOut ? sample.bytesOut - previous.bytesOut : 0) / interval)
        }
        rates = updated
    }
}

final class ProcessNetworkMonitor {
    typealias Rate = NetTopParser.Rate
    private let queue = DispatchQueue(label: "com.laogu.ailock.process-network")
    private var task: Process?
    private var parser = NetTopParser()
    private var wantsRunning = false
    private var generation = 0
    private var lastDataAt: TimeInterval?

    func start() {
        queue.sync {
            guard !wantsRunning else { return }
            wantsRunning = true
            generation += 1
            launch(generation)
        }
    }

    func stop() {
        queue.sync {
            wantsRunning = false; generation += 1
            let process = task
            task = nil; parser = NetTopParser(); lastDataAt = nil
            (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if process?.isRunning == true { process?.terminate() }
        }
    }

    func currentRates() -> [pid_t: Rate] {
        queue.sync {
            guard let lastDataAt, ProcessInfo.processInfo.systemUptime - lastDataAt < 5 else { return [:] }
            return parser.rates
        }
    }

    private func launch(_ request: Int) {
        guard wantsRunning, generation == request, task == nil else { return }
        parser = NetTopParser(); lastDataAt = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-x", "-l", "0", "-s", "1"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { [weak self] in
                guard let self, self.generation == request, self.wantsRunning else { return }
                self.lastDataAt = ProcessInfo.processInfo.systemUptime
                self.parser.ingest(text)
            }
        }
        process.terminationHandler = { [weak self, weak process] _ in
            self?.queue.async { [weak self, weak process] in
                guard let self, self.generation == request, self.task === process else { return }
                (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
                self.task = nil; self.parser = NetTopParser(); self.lastDataAt = nil
                self.retry(request)
            }
        }
        task = process
        do { try process.run() }
        catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            task = nil
            retry(request)
        }
    }

    private func retry(_ request: Int) {
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.launch(request) }
    }

    deinit {
        (task?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if task?.isRunning == true { task?.terminate() }
    }
}
