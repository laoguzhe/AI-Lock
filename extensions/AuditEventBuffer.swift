import Foundation

/// A bounded, volatile delivery window. Cursor gaps are visible; it is not durable audit storage.
final class AuditEventBuffer {
    private let lock = NSLock()
    private let capacity: Int
    private var sequence: UInt64 = 0
    private var entries: [(UInt64, [String: Any])] = []
    init(capacity: Int = 500) { self.capacity = min(500, max(1, capacity)) }
    func append(_ event: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        if sequence == .max { entries = []; sequence = 0 }
        sequence += 1; entries.append((sequence, event))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }
    func snapshot(after cursor: UInt64, limit: Int = 100) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let reset = cursor > sequence
        let effective = reset ? 0 : cursor
        let oldest = entries.first?.0 ?? (sequence == .max ? .max : sequence + 1)
        let lost = oldest > effective && oldest - effective > 1 ? oldest - effective - 1 : 0
        let selected = entries.filter { $0.0 > effective }.prefix(min(100, max(1, limit)))
        let next = selected.last?.0 ?? effective
        return try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "cursor": String(next), "reset": reset,
            "deliveryGap": String(lost), "events": selected.map { id, event in var value = event; value["deliveryID"] = String(id); return value }])
    }
    func clear() { lock.lock(); entries = []; sequence = 0; lock.unlock() }
}
