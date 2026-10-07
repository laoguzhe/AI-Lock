import Foundation
import OSLog

enum SystemLogLevel: String, CaseIterable {
    case all = "全部级别"
    case debug = "调试"
    case info = "信息"
    case notice = "通知"
    case error = "错误"
    case fault = "严重错误"
}

struct SystemLogEntry: Identifiable {
    let id: String
    let date: Date
    let level: SystemLogLevel
    let process: String
    let subsystem: String
    let category: String
    let message: String

    var formattedTime: String {
        Self.timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}

final class SystemLogStore {
    private let queue = DispatchQueue(label: "com.laogu.ailock.system-logs", qos: .utility)
    private let maximumEntries = 2_000

    func fetch(since interval: TimeInterval = 30 * 60,
               completion: @escaping (Result<[SystemLogEntry], Error>) -> Void) {
        queue.async {
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                let start = Date().addingTimeInterval(-interval)
                let position = store.position(date: start)
                let entries = try store.getEntries(at: position, matching: NSPredicate(format: "eventType == 1024 OR eventType == 2"))

                var result: [SystemLogEntry] = []
                for entry in entries {
                    guard let log = entry as? OSLogEntryLog else { continue }
                    result.append(SystemLogEntry(
                        id: "\(log.date.timeIntervalSince1970)-\(log.processIdentifier)-\(result.count)",
                        date: log.date,
                        level: Self.level(for: log.level),
                        process: log.process,
                        subsystem: log.subsystem,
                        category: log.category,
                        message: log.composedMessage
                    ))
                    if result.count >= self.maximumEntries { break }
                }
                completion(.success(result.reversed()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private static func level(for level: OSLogEntryLog.Level) -> SystemLogLevel {
        switch level {
        case .debug: return .debug
        case .info: return .info
        case .notice: return .notice
        case .error: return .error
        case .fault: return .fault
        default: return .info
        }
    }
}
