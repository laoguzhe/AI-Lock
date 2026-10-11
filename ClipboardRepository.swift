import AppKit
import Foundation
import CryptoKit
import SQLite3

/// Each record is authenticated separately; no clipboard plaintext enters SQLite or its journal.
struct ClipboardCatalogEntry: Codable {
    let id: UUID
    let capturedAt: Date
    let byteCount: Int
    var sourceBundleID: String
    var types: [String]
    var isPinned: Bool
    var isFavorite: Bool
    var note: String?
    var contentKind: String {
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) { return "file" }
        if types.contains(NSPasteboard.PasteboardType.tiff.rawValue) || types.contains(NSPasteboard.PasteboardType.png.rawValue) { return "image" }
        if types.contains(NSPasteboard.PasteboardType.string.rawValue) { return "text" }
        return "other"
    }

    init(_ record: ClipboardRecord) {
        id = record.id; capturedAt = record.capturedAt; byteCount = record.byteCount
        sourceBundleID = record.sourceBundleID; types = record.types
        isPinned = record.isPinned; isFavorite = record.isFavorite; note = record.note
    }

    private enum CodingKeys: String, CodingKey { case id, capturedAt, byteCount, sourceBundleID, types, isPinned, isFavorite, note }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        capturedAt = try values.decode(Date.self, forKey: .capturedAt)
        byteCount = try values.decode(Int.self, forKey: .byteCount)
        sourceBundleID = try values.decodeIfPresent(String.self, forKey: .sourceBundleID) ?? ""
        types = try values.decodeIfPresent([String].self, forKey: .types) ?? []
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isFavorite = try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        note = try values.decodeIfPresent(String.self, forKey: .note)
    }
}

final class ClipboardRepository {
    let url: URL
    init(url: URL) { self.url = url }
    private enum Failure: LocalizedError {
        case database(String), malformedRecord
        var errorDescription: String? {
            switch self {
            case let .database(message): return "剪贴板数据库错误：\(message)"
            case .malformedRecord: return "剪贴板历史记录校验失败，数据可能损坏或格式不兼容。"
            }
        }
    }
    // JSON stores binary values as Base64 (4/3 expansion), and the default encoder
    // escapes '/' characters, potentially doubling that representation again.
    // Allow that expansion plus bounded record metadata and the AES-GCM envelope.
    static let maximumEncryptedRecordBytes = ClipboardHistory.maximumRecordBytes * 3 + 64 * 1024
    private static let maximumEncryptedHistoryBytes = ClipboardHistory.maximumHistoryBytes * 3
        + ClipboardHistory.maximumRecords * 64 * 1024
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func database<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db = connection else {
            if let connection { sqlite3_close(connection) }
            throw Failure.database("无法打开剪贴板数据库")
        }
        defer { sqlite3_close(db) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        sqlite3_busy_timeout(db, 3000)
        // Single writer, no long-lived readers: rollback journal keeps the deployment simple.
        try execute(db, "PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS records(id TEXT PRIMARY KEY, payload BLOB NOT NULL); CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS catalog(id INTEGER PRIMARY KEY, payload BLOB NOT NULL);")
        return try body(db)
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.database(String(cString: sqlite3_errmsg(db))) }
    }
    private func statement(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &value, nil) == SQLITE_OK, let value else {
            throw Failure.database(String(cString: sqlite3_errmsg(db)))
        }
        return value
    }

    /// nil means no completed migration: the caller must still read the legacy file.
    func load(key: SymmetricKey) throws -> [ClipboardRecord]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try database { db in
            let marker = try statement(db, "SELECT value FROM metadata WHERE key='initialized'")
            defer { sqlite3_finalize(marker) }
            let markerStatus = sqlite3_step(marker)
            guard markerStatus == SQLITE_ROW else {
                guard markerStatus == SQLITE_DONE else { throw Failure.database(String(cString: sqlite3_errmsg(db))) }
                return nil
            }
            let bounds = try statement(db, "SELECT count(*),coalesce(sum(length(payload)),0) FROM records")
            defer { sqlite3_finalize(bounds) }
            guard sqlite3_step(bounds) == SQLITE_ROW,
                  sqlite3_column_int64(bounds, 0) <= ClipboardHistory.maximumRecords,
                  sqlite3_column_int64(bounds, 1) <= Self.maximumEncryptedHistoryBytes else { throw Failure.malformedRecord }
            let query = try statement(db, "SELECT id,payload FROM records")
            defer { sqlite3_finalize(query) }
            var records: [ClipboardRecord] = []
            var status = sqlite3_step(query)
            while status == SQLITE_ROW {
                guard let rawID = sqlite3_column_text(query, 0), let raw = sqlite3_column_blob(query, 1) else { throw Failure.malformedRecord }
                let id = String(cString: rawID)
                let length = Int(sqlite3_column_bytes(query, 1))
                guard length > 0, length <= Self.maximumEncryptedRecordBytes else { throw Failure.malformedRecord }
                let encrypted = Data(bytes: raw, count: length)
                let data = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: key, authenticating: Data(id.utf8))
                let record = try JSONDecoder().decode(ClipboardRecord.self, from: data)
                guard record.id.uuidString == id, record.byteCount <= ClipboardHistory.maximumRecordBytes else { throw Failure.malformedRecord }
                records.append(record)
                status = sqlite3_step(query)
            }
            guard status == SQLITE_DONE else { throw Failure.database(String(cString: sqlite3_errmsg(db))) }
            try validate(records.map(ClipboardCatalogEntry.init))
            records.sort { $0.capturedAt > $1.capturedAt }
            return records
        }
    }

    /// Encrypt changed records and retain the complete encrypted catalog for paging and pruning.
    func replace(with records: [ClipboardRecord], key: SymmetricKey) throws {
        try persist(records: records, catalog: records.map(ClipboardCatalogEntry.init), key: key)
    }

    /// The complete encrypted catalog, rather than a visible page, determines retention.
    func persist(records: [ClipboardRecord], catalog: [ClipboardCatalogEntry], key: SymmetricKey) throws {
        try validate(catalog)
        let ids = Set(catalog.map(\.id))
        let metadata = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        guard records.allSatisfy({ record in
            guard let entry = metadata[record.id] else { return false }
            return entry.capturedAt == record.capturedAt && entry.byteCount == record.byteCount
                && (entry.sourceBundleID.isEmpty || entry.sourceBundleID == record.sourceBundleID)
                && (entry.types.isEmpty || entry.types == record.types)
                && entry.isPinned == record.isPinned && entry.isFavorite == record.isFavorite && entry.note == record.note
        }) else { throw Failure.malformedRecord }
        try database { db in
            try execute(db, "BEGIN IMMEDIATE")
            do {
                let insert = try statement(db, "INSERT OR REPLACE INTO records(id,payload) VALUES(?,?)")
                defer { sqlite3_finalize(insert) }
                for record in records {
                    let id = record.id.uuidString
                    let data = try JSONEncoder().encode(record)
                    guard let encrypted = try AES.GCM.seal(data, using: key, authenticating: Data(id.utf8)).combined,
                          encrypted.count <= Self.maximumEncryptedRecordBytes else { throw Failure.malformedRecord }
                    sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                    guard sqlite3_bind_text(insert, 1, id, -1, transient) == SQLITE_OK else { throw Failure.database("记录 ID 绑定失败") }
                    let bind = encrypted.withUnsafeBytes { sqlite3_bind_blob(insert, 2, $0.baseAddress, Int32($0.count), transient) }
                    guard bind == SQLITE_OK, sqlite3_step(insert) == SQLITE_DONE else { throw Failure.database(String(cString: sqlite3_errmsg(db))) }
                }
                // Also removes leftovers from an interrupted, uninitialized migration.
                let query = try statement(db, "SELECT id FROM records")
                var removed: [String] = []
                var queryStatus = sqlite3_step(query)
                while queryStatus == SQLITE_ROW {
                    if let raw = sqlite3_column_text(query, 0) {
                        let id = String(cString: raw)
                        if UUID(uuidString: id).map({ !ids.contains($0) }) ?? true { removed.append(id) }
                    }
                    queryStatus = sqlite3_step(query)
                }
                sqlite3_finalize(query)
                guard queryStatus == SQLITE_DONE else { throw Failure.database(String(cString: sqlite3_errmsg(db))) }
                let deletion = try statement(db, "DELETE FROM records WHERE id=?")
                defer { sqlite3_finalize(deletion) }
                for id in removed {
                    sqlite3_reset(deletion); sqlite3_clear_bindings(deletion)
                    guard sqlite3_bind_text(deletion, 1, id, -1, transient) == SQLITE_OK,
                          sqlite3_step(deletion) == SQLITE_DONE else { throw Failure.database(String(cString: sqlite3_errmsg(db))) }
                }
                let catalogData = try JSONEncoder().encode(catalog)
                guard let sealed = try AES.GCM.seal(catalogData, using: key, authenticating: Data("catalog-v1".utf8)).combined else { throw Failure.malformedRecord }
                let catalogInsert = try statement(db, "INSERT OR REPLACE INTO catalog(id,payload) VALUES(1,?)")
                defer { sqlite3_finalize(catalogInsert) }
                let binding = sealed.withUnsafeBytes { sqlite3_bind_blob(catalogInsert, 1, $0.baseAddress, Int32($0.count), transient) }
                guard binding == SQLITE_OK, sqlite3_step(catalogInsert) == SQLITE_DONE else { throw Failure.malformedRecord }
                let count = try statement(db, "SELECT count(*) FROM records")
                defer { sqlite3_finalize(count) }
                guard sqlite3_step(count) == SQLITE_ROW, sqlite3_column_int(count, 0) == ids.count else { throw Failure.malformedRecord }
                try execute(db, "INSERT OR REPLACE INTO metadata VALUES('initialized',1); COMMIT")
            } catch { try? execute(db, "ROLLBACK"); throw error }
        }
    }

    private func validate(_ catalog: [ClipboardCatalogEntry]) throws {
        guard catalog.count <= ClipboardHistory.maximumRecords,
              Set(catalog.map(\.id)).count == catalog.count else { throw Failure.malformedRecord }
        var bytes = 0
        for entry in catalog {
            guard entry.capturedAt.timeIntervalSince1970.isFinite, entry.byteCount >= 0,
                  entry.byteCount <= ClipboardHistory.maximumRecordBytes,
                  entry.byteCount <= ClipboardHistory.maximumHistoryBytes - bytes else { throw Failure.malformedRecord }
            bytes += entry.byteCount
        }
    }

    /// Old databases are upgraded once; subsequent opens decrypt only small catalog metadata.
    func loadCatalog(key: SymmetricKey) throws -> [ClipboardCatalogEntry]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let stored: [ClipboardCatalogEntry]? = try database { db in
            let query = try statement(db, "SELECT payload FROM catalog WHERE id=1")
            defer { sqlite3_finalize(query) }
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW, let raw = sqlite3_column_blob(query, 0) else { throw Failure.malformedRecord }
            let length = Int(sqlite3_column_bytes(query, 0))
            guard length > 0, length < 256 * 1024 else { throw Failure.malformedRecord }
            let data = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(bytes: raw, count: length)), using: key, authenticating: Data("catalog-v1".utf8))
            let entries = try JSONDecoder().decode([ClipboardCatalogEntry].self, from: data)
            try validate(entries)
            let count = try statement(db, "SELECT count(*) FROM records")
            defer { sqlite3_finalize(count) }
            guard sqlite3_step(count) == SQLITE_ROW, sqlite3_column_int(count, 0) == entries.count else { throw Failure.malformedRecord }
            return entries
        }
        if let stored {
            guard stored.contains(where: { $0.sourceBundleID.isEmpty || $0.types.isEmpty }) else { return stored }
            var upgradedRecords: [ClipboardRecord] = []
            for offset in stride(from: 0, to: stored.count, by: ClipboardHistory.pageSize) {
                upgradedRecords += try loadPage(entries: Array(stored[offset..<min(stored.count, offset + ClipboardHistory.pageSize)]), key: key)
            }
            let upgraded = upgradedRecords.map(ClipboardCatalogEntry.init)
            try persist(records: upgradedRecords, catalog: upgraded, key: key)
            return upgraded
        }
        guard let legacy = try load(key: key) else { return nil }
        let entries = legacy.map(ClipboardCatalogEntry.init)
        try persist(records: legacy, catalog: entries, key: key)
        return entries
    }

    func loadPage(entries: [ClipboardCatalogEntry], key: SymmetricKey) throws -> [ClipboardRecord] {
        try database { db in
            let query = try statement(db, "SELECT payload FROM records WHERE id=?")
            defer { sqlite3_finalize(query) }
            return try entries.map { entry in
                sqlite3_reset(query); sqlite3_clear_bindings(query)
                guard sqlite3_bind_text(query, 1, entry.id.uuidString, -1, transient) == SQLITE_OK,
                      sqlite3_step(query) == SQLITE_ROW, let raw = sqlite3_column_blob(query, 0) else { throw Failure.malformedRecord }
                let length = Int(sqlite3_column_bytes(query, 0))
                guard length > 0, length <= Self.maximumEncryptedRecordBytes else { throw Failure.malformedRecord }
                let data = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(bytes: raw, count: length)), using: key, authenticating: Data(entry.id.uuidString.utf8))
                let record = try JSONDecoder().decode(ClipboardRecord.self, from: data)
                guard record.id == entry.id, record.capturedAt == entry.capturedAt, record.byteCount == entry.byteCount,
                      (entry.sourceBundleID.isEmpty || entry.sourceBundleID == record.sourceBundleID),
                      (entry.types.isEmpty || entry.types == record.types),
                      entry.isPinned == record.isPinned, entry.isFavorite == record.isFavorite, entry.note == record.note else { throw Failure.malformedRecord }
                return record
            }
        }
    }

    func clear() throws {
        // Explicit user clearing also recovers a corrupt database without requiring its key.
        for path in [url, URL(fileURLWithPath: url.path + "-journal"), URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")] {
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        }
    }
}
