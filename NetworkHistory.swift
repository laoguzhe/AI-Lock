import Foundation

struct NetworkHistoryPoint: Codable, Identifiable {
    var timestamp: Date
    var bytesPerSecond: Double
    var observedSeconds: TimeInterval? = nil
    var lastObservedAt: Date? = nil
    var id: Int64 { Int64(timestamp.timeIntervalSince1970 / 60) }
}

final class NetworkHistory {
    static let shared = NetworkHistory()
    private let defaultsKey = "network.history.1h.v2"
    private let defaults: UserDefaults
    private let bucketSeconds: TimeInterval = 60
    private let windowSeconds: TimeInterval = 60 * 60
    private(set) var points: [NetworkHistoryPoint]
    private var bucketStart: Date?
    private var bucketBytes = 0.0
    private var bucketDuration: TimeInterval = 0
    private var lastDate: Date?
    private var bucketEnd: Date?

    init(defaults: UserDefaults = .standard, now: Date = .now) {
        self.defaults = defaults
        let data = defaults.data(forKey: defaultsKey) ?? defaults.data(forKey: "network.history.12h")
        points = data.flatMap { try? JSONDecoder().decode([NetworkHistoryPoint].self, from: $0) } ?? []
        points.removeAll {
            !$0.timestamp.timeIntervalSince1970.isFinite || !$0.bytesPerSecond.isFinite || $0.bytesPerSecond < 0
                || ($0.observedSeconds.map { !$0.isFinite || $0 <= 0 || $0 > 60 } ?? false)
                || ($0.lastObservedAt.map { !$0.timeIntervalSince1970.isFinite } ?? false)
        }
        trim(now: now)
        lastDate = points.compactMap(\.lastObservedAt).max()
    }

    func record(at date: Date, downloadBytesPerSecond: UInt64, uploadBytesPerSecond: UInt64, duration: TimeInterval = 1) {
        guard date.timeIntervalSince1970.isFinite else { return }
        // Invalid/long intervals represent a gap (for example waking from sleep), not zero traffic.
        guard duration.isFinite, duration > 0, duration <= 30 else { lastDate = date; trim(now: date); return }
        if let lastDate, date < lastDate {
            flush()
            points.removeAll { ($0.lastObservedAt ?? $0.timestamp.addingTimeInterval(60)) > date }
            persist(); trim(now: date)
        }
        var start = date.addingTimeInterval(-duration)
        if let lastDate, lastDate <= date { start = max(start, lastDate) }
        lastDate = date
        let rate = Double(downloadBytesPerSecond) + Double(uploadBytesPerSecond)
        while start < date {
            let minute = Date(timeIntervalSince1970: floor(start.timeIntervalSince1970 / bucketSeconds) * bucketSeconds)
            let end = min(date, minute.addingTimeInterval(bucketSeconds))
            if bucketStart != minute {
                flush()
                bucketStart = minute
                if let index = points.firstIndex(where: { $0.timestamp == minute }) {
                    let existing = points.remove(at: index)
                    bucketDuration = existing.observedSeconds ?? 60
                    bucketBytes = existing.bytesPerSecond * bucketDuration
                }
            }
            let elapsed = end.timeIntervalSince(start)
            bucketBytes += rate * elapsed; bucketDuration += elapsed; bucketEnd = end
            start = end
        }
        trim(now: date)
    }

    func snapshot(now: Date = .now) -> [NetworkHistoryPoint] {
        var result = points
        if let bucketStart, bucketDuration > 0 {
            result.append(NetworkHistoryPoint(timestamp: bucketStart, bytesPerSecond: bucketBytes / bucketDuration, observedSeconds: bucketDuration, lastObservedAt: bucketEnd))
        }
        let cutoff = now.addingTimeInterval(-windowSeconds)
        return result.filter { $0.timestamp >= cutoff && $0.timestamp <= now }.sorted { $0.timestamp < $1.timestamp }
    }

    func flush() {
        guard let bucketStart, bucketDuration > 0 else { return }
        points.removeAll { $0.timestamp == bucketStart }
        points.append(NetworkHistoryPoint(timestamp: bucketStart, bytesPerSecond: bucketBytes / bucketDuration, observedSeconds: bucketDuration, lastObservedAt: bucketEnd))
        points.sort { $0.timestamp < $1.timestamp }
        self.bucketStart = nil; bucketBytes = 0; bucketDuration = 0; bucketEnd = nil
        persist()
    }

    private func trim(now: Date) {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        let count = points.count
        points.removeAll { $0.timestamp < cutoff || $0.timestamp > now || ($0.lastObservedAt.map { $0 > now } ?? false) }
        if let bucketStart, bucketStart < cutoff || bucketStart > now {
            self.bucketStart = nil; bucketBytes = 0; bucketDuration = 0; bucketEnd = nil
        }
        if points.count != count { persist() }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(points) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
