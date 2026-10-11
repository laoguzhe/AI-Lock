import Foundation

/// ES sequence numbers are per client AND event type; observe before root filtering.
final class AuditSequenceTracker {
    private let lock = NSLock()
    private var previous: [UInt32: UInt64] = [:]
    func observe(type: UInt32, sequence: UInt64) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        defer { previous[type] = sequence }
        guard let last = previous[type], sequence > last else { return 0 }
        return sequence - last - 1
    }
}

/// Only one drain task is scheduled; slow output never creates an unbounded task queue.
final class BoundedAuditWriter {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.laogu.ailock.audit-output", qos: .utility)
    private let capacity: Int
    private let write: (Data) throws -> Void
    private var pending: [Data] = []
    private var draining = false
    private var stopped = false
    private var dropped: UInt64 = 0
    private var failed = false
    var outputFailed: Bool { lock.lock(); defer { lock.unlock() }; return failed }

    init(capacity: Int = 500, write: @escaping (Data) throws -> Void) {
        self.capacity = max(1, capacity); self.write = write
    }
    func submit(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return }
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        if pending.count < capacity { pending.append(data) }
        else if dropped < UInt64.max { dropped += 1 }
        let schedule = !draining; draining = true
        lock.unlock()
        if schedule { queue.async { [weak self] in self?.drain() } }
    }
    private func drain() {
        while true {
            lock.lock()
            let data: Data
            if dropped > 0 {
                let count = dropped; dropped = 0
                data = (try? JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "kind": "output-events-dropped", "count": count])) ?? Data()
            } else if !pending.isEmpty { data = pending.removeFirst() }
            else { draining = false; lock.unlock(); return }
            lock.unlock()
            do { var line = data; line.append(10); try write(line) }
            catch {
                lock.lock(); stopped = true; failed = true; pending = []; dropped = 0; draining = false; lock.unlock()
                return
            }
        }
    }
    func flush() { queue.sync {} }
}
