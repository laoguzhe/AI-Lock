import Foundation
import CryptoKit
import SQLite3
import Darwin

/// Metadata only. One transaction binds file rows and the replay cursor; cancellation rolls back.
final class DirectoryIndex {
    let directory: URL
    private let lock = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private struct Failure: LocalizedError { let errorDescription: String? }
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AILock/DirectoryIndexes", isDirectory: true)) { self.directory = directory }

    func excludes(_ path: String) -> Bool {
        let base = FilesystemPath.canonical(directory).path
        return path == base || path.hasPrefix(base + "/")
    }
    private func location(_ root: URL) -> URL {
        let hash = SHA256.hash(data: Data(root.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".sqlite")
    }
    private func identity(_ root: URL) throws -> String {
        var value = stat()
        guard lstat(root.path, &value) == 0, (value.st_mode & S_IFMT) == S_IFDIR else {
            throw Failure(errorDescription: "目录不可访问或已被替换")
        }
        return "\(value.st_dev):\(value.st_ino)"
    }
    private func database<T>(root: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = location(root)
        var pointer: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let db = pointer else {
            if let pointer { sqlite3_close(pointer) }; throw Failure(errorDescription: "目录索引无法打开")
        }
        defer { sqlite3_close(db) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        sqlite3_busy_timeout(db, 3000)
        try execute(db, "PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY,size INTEGER NOT NULL,category TEXT NOT NULL); CREATE TABLE IF NOT EXISTS issues(path TEXT PRIMARY KEY); CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL); CREATE INDEX IF NOT EXISTS files_size ON files(size DESC,path);")
        return try body(db)
    }
    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure(errorDescription: String(cString: sqlite3_errmsg(db))) }
    }
    private func statement(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &value, nil) == SQLITE_OK, let value else {
            throw Failure(errorDescription: String(cString: sqlite3_errmsg(db)))
        }
        return value
    }
    private func text(_ db: OpaquePointer, _ sql: String, arguments: [String]) throws -> String? {
        let query = try statement(db, sql); defer { sqlite3_finalize(query) }
        for (index, value) in arguments.enumerated() { sqlite3_bind_text(query, Int32(index + 1), value, -1, transient) }
        let status = sqlite3_step(query)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let value = sqlite3_column_text(query, 0) else { throw Failure(errorDescription: "索引读取失败") }
        return String(cString: value)
    }
    private func put(_ db: OpaquePointer, key: String, value: String) throws {
        let insert = try statement(db, "INSERT OR REPLACE INTO metadata VALUES(?,?)"); defer { sqlite3_finalize(insert) }
        sqlite3_bind_text(insert, 1, key, -1, transient); sqlite3_bind_text(insert, 2, value, -1, transient)
        guard sqlite3_step(insert) == SQLITE_DONE else { throw Failure(errorDescription: "索引状态写入失败") }
    }
    func resumeCursor(root input: URL) -> UInt64? {
        let root = FilesystemPath.canonical(input)
        guard FileManager.default.fileExists(atPath: location(root).path) else { return nil }
        return try? database(root: root) { db in
            guard try text(db, "SELECT value FROM metadata WHERE key='identity'", arguments: []) == identity(root),
                  let value = try text(db, "SELECT value FROM metadata WHERE key='cursor'", arguments: []),
                  let cursor = UInt64(value), cursor > 0 else { return nil }
            return cursor
        }
    }

    func update(root input: URL, events: [DirectoryActivityEvent]?, cancellation: ScanCancellation = ScanCancellation(),
                progress: ((Int) -> Void)? = nil, threshold: Int64 = 100 * 1024 * 1024, limit: Int = 500) -> FileScanSnapshot {
        let root = FilesystemPath.canonical(input)
        do {
            return try database(root: root) { db in
                let rootIdentity = try identity(root)
                let previousIdentity = try text(db, "SELECT value FROM metadata WHERE key='identity'", arguments: [])
                let rebuild = events == nil || previousIdentity != rootIdentity || events?.contains(where: { $0.needsRescan }) == true
                try execute(db, "BEGIN IMMEDIATE")
                do {
                    var visited = 0
                    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isHiddenKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
                    let insert = try statement(db, "INSERT OR REPLACE INTO files VALUES(?,?,?)"); defer { sqlite3_finalize(insert) }
                    let issue = try statement(db, "INSERT OR REPLACE INTO issues VALUES(?)"); defer { sqlite3_finalize(issue) }
                    func markIssue(_ url: URL) throws {
                        sqlite3_reset(issue); sqlite3_clear_bindings(issue); sqlite3_bind_text(issue, 1, url.path, -1, transient)
                        guard sqlite3_step(issue) == SQLITE_DONE else { throw Failure(errorDescription: "索引诊断写入失败") }
                    }
                    func eligible(_ url: URL) -> Bool {
                        guard !excludes(url.path) else { return false }
                        var ancestor = url
                        while ancestor.path != root.path && ancestor.path != "/" {
                            if ancestor.lastPathComponent.hasPrefix(".") { return false }
                            let value = try? ancestor.resourceValues(forKeys: [.isSymbolicLinkKey, .isPackageKey])
                            if value?.isSymbolicLink == true || value?.isPackage == true { return false }
                            ancestor.deleteLastPathComponent()
                        }
                        return ancestor.path == root.path
                    }
                    func collect(_ url: URL) throws {
                        guard !cancellation.isCancelled else { throw CancellationError() }
                        guard eligible(url) else { return }
                        let values: URLResourceValues
                        do { values = try url.resourceValues(forKeys: keys) }
                        catch { try markIssue(url); return }
                        guard values.isSymbolicLink != true, values.isRegularFile == true else { return }
                        let size = max(0, Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0))
                        sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                        sqlite3_bind_text(insert, 1, url.path, -1, transient); sqlite3_bind_int64(insert, 2, size)
                        sqlite3_bind_text(insert, 3, FileScanService.category(url.pathExtension.lowercased()), -1, transient)
                        guard sqlite3_step(insert) == SQLITE_DONE else { throw Failure(errorDescription: "索引文件写入失败") }
                        visited += 1; if visited % 256 == 0 { progress?(visited) }
                    }
                    var scopes: [URL] = []
                    if rebuild { try execute(db, "DELETE FROM files; DELETE FROM issues"); scopes = [root] }
                    else {
                        let prefix = root.path == "/" ? "/" : root.path + "/"
                        let paths = Set((events ?? []).filter { !$0.isHistoryDone && !excludes($0.path) }.map { FilesystemPath.eventLocation(URL(fileURLWithPath: $0.path)).path })
                            .filter { $0 == root.path || $0.hasPrefix(prefix) }.sorted { $0.count < $1.count }
                        for path in paths where !scopes.contains(where: { path == $0.path || path.hasPrefix($0.path == "/" ? "/" : $0.path + "/") }) {
                            scopes.append(URL(fileURLWithPath: path))
                        }
                        for scope in scopes {
                            // substr avoids SQL LIKE wildcard interpretation in filenames.
                            let prefix = scope.path == "/" ? "/" : scope.path + "/"
                            for table in ["files", "issues"] {
                                let deletion = try statement(db, "DELETE FROM \(table) WHERE path=? OR substr(path,1,length(?))=?")
                                sqlite3_bind_text(deletion, 1, scope.path, -1, transient); sqlite3_bind_text(deletion, 2, prefix, -1, transient); sqlite3_bind_text(deletion, 3, prefix, -1, transient)
                                let status = sqlite3_step(deletion); sqlite3_finalize(deletion)
                                guard status == SQLITE_DONE else { throw Failure(errorDescription: "旧索引裁剪失败") }
                            }
                        }
                    }
                    for scope in scopes {
                        guard !cancellation.isCancelled else { throw CancellationError() }
                        guard scope.path == root.path || eligible(scope) else { continue }
                        var isDirectory: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: scope.path, isDirectory: &isDirectory) else {
                            // Missing means deletion; an inaccessible ancestor requires a safe rebuild.
                            if access(scope.deletingLastPathComponent().path, R_OK | X_OK) != 0 { throw Failure(errorDescription: "补扫目录不可访问；旧索引已保留") }
                            continue
                        }
                        if !isDirectory.boolValue { try collect(scope); continue }
                        var enumerationError: Error?
                        guard let enumerator = FileManager.default.enumerator(at: scope, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
                            do { try markIssue(url) } catch { enumerationError = error }
                            return !cancellation.isCancelled && enumerationError == nil
                        }) else { throw Failure(errorDescription: "索引目录无法遍历") }
                        for case let url as URL in enumerator {
                            if excludes(url.path) { enumerator.skipDescendants(); continue }
                            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { enumerator.skipDescendants(); continue }
                            try collect(url)
                        }
                        if let enumerationError { throw enumerationError }
                    }
                    guard !cancellation.isCancelled else { throw CancellationError() }
                    guard try identity(root) == rootIdentity else { throw Failure(errorDescription: "扫描期间根目录被替换；旧索引已保留") }
                    try put(db, key: "identity", value: rootIdentity)
                    let oldCursor = UInt64(try text(db, "SELECT value FROM metadata WHERE key='cursor'", arguments: []) ?? "0") ?? 0
                    let cursor = events?.map(\.id).max() ?? 0
                    try put(db, key: "cursor", value: String(rebuild ? cursor : max(oldCursor, cursor)))
                    if rebuild || !scopes.isEmpty { try put(db, key: "updatedAt", value: String(Date().timeIntervalSince1970)) }
                    try execute(db, "COMMIT")
                } catch { try? execute(db, "ROLLBACK"); throw error }
                var result = FileScanSnapshot(); result.indexWasRebuilt = rebuild
                result.indexUpdatedAt = (try text(db, "SELECT value FROM metadata WHERE key='updatedAt'", arguments: [])).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
                let counts = try statement(db, "SELECT count(*),coalesce(sum(CASE WHEN size>=? THEN 1 ELSE 0 END),0) FROM files"); defer { sqlite3_finalize(counts) }
                sqlite3_bind_int64(counts, 1, threshold)
                guard sqlite3_step(counts) == SQLITE_ROW else { throw Failure(errorDescription: "索引统计失败") }
                result.scannedFiles = Int(sqlite3_column_int64(counts, 0)); result.matchingFiles = Int(sqlite3_column_int64(counts, 1))
                result.skippedItems = Int(try text(db, "SELECT count(*) FROM issues", arguments: []) ?? "0") ?? 0
                let files = try statement(db, "SELECT path,size FROM files WHERE size>=? ORDER BY size DESC,path LIMIT ?"); defer { sqlite3_finalize(files) }
                sqlite3_bind_int64(files, 1, threshold); sqlite3_bind_int(files, 2, Int32(clamping: max(0, limit)))
                var fileStatus = sqlite3_step(files)
                while fileStatus == SQLITE_ROW {
                    defer { fileStatus = sqlite3_step(files) }
                    guard let path = sqlite3_column_text(files, 0) else { continue }
                    result.largestFiles.append(AnalyzedFile(url: URL(fileURLWithPath: String(cString: path)), size: sqlite3_column_int64(files, 1)))
                }
                guard fileStatus == SQLITE_DONE else { throw Failure(errorDescription: "索引文件读取失败") }
                let groups = try statement(db, "SELECT category,sum(size),count(*) FROM files GROUP BY category ORDER BY sum(size) DESC,category"); defer { sqlite3_finalize(groups) }
                var groupStatus = sqlite3_step(groups)
                while groupStatus == SQLITE_ROW {
                    defer { groupStatus = sqlite3_step(groups) }
                    guard let name = sqlite3_column_text(groups, 0) else { continue }
                    result.categories.append(StorageCategory(name: String(cString: name), size: sqlite3_column_int64(groups, 1), count: Int(sqlite3_column_int64(groups, 2))))
                }
                guard groupStatus == SQLITE_DONE else { throw Failure(errorDescription: "索引分类读取失败") }
                return result
            }
        } catch is CancellationError { var result = FileScanSnapshot(); result.cancelled = true; return result }
        catch { var result = FileScanSnapshot(); result.error = error.localizedDescription; return result }
    }
}
