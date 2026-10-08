import Foundation

struct NetworkHistoryPoint: Codable, Identifiable {
    var timestamp: Date
    var bytesPerSecond: Double
    var id: Int64 { Int64(timestamp.timeIntervalSince1970 / 60) }
}

final class NetworkHistory {
    static let shared = NetworkHistory()
    private let defaultsKey = "network.history.12h"
    private let defaults = UserDefaults.standard
    private let bucketSeconds: TimeInterval = 60
    private let windowSeconds: TimeInterval = 60 * 60
    private(set) var points: [NetworkHistoryPoint]
    private var bucketStart: Date?
    private var bucketBytes = 0.0
    private var bucketSamples = 0

    private init() {
        if let data = defaults.data(forKey: defaultsKey),
           let stored = try? JSONDecoder().decode([NetworkHistoryPoint].self, from: data) {
            points = stored
        } else {
            points = []
        }
        trim(now: .now)
    }

    func record(at date: Date, downloadBytesPerSecond: UInt64, uploadBytesPerSecond: UInt64) {
        let start = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / bucketSeconds) * bucketSeconds)
        if let bucketStart, bucketStart != start {
            flushBucket()
        }
        if bucketStart != start {
            bucketStart = start
            bucketBytes = 0
            bucketSamples = 0
        }
        bucketBytes += Double(downloadBytesPerSecond) + Double(uploadBytesPerSecond)
        bucketSamples += 1
        trim(now: date)
    }

    func snapshot(now: Date = .now) -> [NetworkHistoryPoint] {
        var result = points
        if let bucketStart, bucketSamples > 0 {
            result.append(NetworkHistoryPoint(timestamp: bucketStart, bytesPerSecond: bucketBytes / Double(bucketSamples)))
        }
        let cutoff = now.addingTimeInterval(-windowSeconds)
        return result.filter { $0.timestamp >= cutoff && $0.timestamp <= now }
    }

    private func flushBucket() {
        guard let bucketStart, bucketSamples > 0 else { return }
        points.removeAll { $0.timestamp == bucketStart }
        points.append(NetworkHistoryPoint(timestamp: bucketStart, bytesPerSecond: bucketBytes / Double(bucketSamples)))
        points.sort { $0.timestamp < $1.timestamp }
        self.bucketStart = nil
        bucketBytes = 0
        bucketSamples = 0
        persist()
    }

    private func trim(now: Date) {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        let originalCount = points.count
        points.removeAll { $0.timestamp < cutoff || $0.timestamp > now }
        if points.count != originalCount { persist() }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(points) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
