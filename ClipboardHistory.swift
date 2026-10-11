import AppKit
import CryptoKit
import Security

struct ClipboardRecord: Codable, Identifiable {
    let id: UUID
    let capturedAt: Date
    let sourceBundleID: String
    let items: [[String: Data]]
    var isPinned: Bool
    var isFavorite: Bool
    var note: String?
    // Existing UI uses the first item for its preview. Restoring uses every item.
    var values: [String: Data] { items.first ?? [:] }
    var types: [String] { Array(Set(items.flatMap { $0.keys })).sorted() }
    var byteCount: Int { items.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } } }

    init(id: UUID = UUID(), capturedAt: Date = Date(), sourceBundleID: String, items: [[String: Data]], isPinned: Bool = false, isFavorite: Bool = false, note: String? = nil) {
        self.id = id; self.capturedAt = capturedAt; self.sourceBundleID = sourceBundleID; self.items = items
        self.isPinned = isPinned; self.isFavorite = isFavorite; self.note = note
    }

    private enum CodingKeys: String, CodingKey { case id, capturedAt, sourceBundleID, items, values, isPinned, isFavorite, note }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        sourceBundleID = try container.decode(String.self, forKey: .sourceBundleID)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        note = try container.decodeIfPresent(String.self, forKey: .note)
        if let stored = try container.decodeIfPresent([[String: Data]].self, forKey: .items) { items = stored }
        else { items = [try container.decode([String: Data].self, forKey: .values)] }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(sourceBundleID, forKey: .sourceBundleID)
        try container.encode(items, forKey: .items)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encodeIfPresent(note, forKey: .note)
    }

    var preview: String {
        if let text = values[NSPasteboard.PasteboardType.string.rawValue], let value = String(data: text, encoding: .utf8) {
            return value.replacingOccurrences(of: "\n", with: " ").prefix(180).description
        }
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) { return "文件或文件夹引用（\(items.count) 项）" }
        if types.contains(NSPasteboard.PasteboardType.tiff.rawValue) || types.contains(NSPasteboard.PasteboardType.png.rawValue) { return "图像内容" }
        return types.joined(separator: ", ")
    }

    var contentKind: String {
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) { return "file" }
        if types.contains(NSPasteboard.PasteboardType.tiff.rawValue) || types.contains(NSPasteboard.PasteboardType.png.rawValue) { return "image" }
        if types.contains(NSPasteboard.PasteboardType.string.rawValue) { return "text" }
        return "other"
    }

    var plainText: String? {
        let strings = items.compactMap { values -> String? in
            if let data = values[NSPasteboard.PasteboardType.string.rawValue], let value = String(data: data, encoding: .utf8) { return value }
            if let data = values[NSPasteboard.PasteboardType.html.rawValue],
               let value = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil) { return value.string }
            if let data = values[NSPasteboard.PasteboardType.rtf.rawValue],
               let value = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) { return value.string }
            return nil
        }
        return strings.isEmpty ? nil : strings.joined(separator: "\n")
    }
}

private struct ClipboardBackupPayload: Codable {
    let version: Int
    let createdAt: Date
    let records: [ClipboardRecord]
}

/// One production instance, with an isolated dependency-injected initializer for regression tests.
final class ClipboardHistory: NSObject {
    private static var initializedShared: ClipboardHistory?
    static let shared: ClipboardHistory = {
        let history = ClipboardHistory()
        initializedShared = history
        return history
    }()
    static var isSharedInitialized: Bool { initializedShared != nil }
    static func stopSharedIfInitialized() { initializedShared?.stop() }
    private let pasteboard: NSPasteboard
    private let settings: AppSettings
    private let fileURL: URL
    private let repository: ClipboardRepository?
    private let keyProvider: (() -> SymmetricKey?)?
    private let keyLock = NSLock()
    private var cachedKey: SymmetricKey?
    private let storageQueue = DispatchQueue(label: "com.laogu.ailock.clipboard-storage")
    private var timer: Timer?
    private var lastChangeCount = -1
    private var lastPruneAt = Date.distantPast
    private var canSave = true
    private var retryWork: DispatchWorkItem?
    private var retryAttempt = 0
    private var retriesEnabled = true
    private(set) var records: [ClipboardRecord] = []
    private var catalog: [ClipboardCatalogEntry] = []
    private var pageGeneration = UUID()
    private(set) var isLoadingPage = false
    private(set) var isLoadingHistory = false
    private var saveAfterLoading = false
    private(set) var searchQuery = ""
    private(set) var searchResults: [ClipboardRecord] = []
    private(set) var searchMatchCount = 0
    private(set) var isSearching = false
    private var searchGeneration = UUID()
    private var searchCancellation: ClipboardSearchCancellation?
    private(set) var sourceFilter = ""
    private(set) var typeFilter = ""
    var availableSourceBundleIDs: [String] { Array(Set(catalog.map(\.sourceBundleID).filter { !$0.isEmpty })).sorted() }
    var displayedRecords: [ClipboardRecord] {
        let source = searchQuery.isEmpty && sourceFilter.isEmpty && typeFilter.isEmpty ? records : searchResults
        return source.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.capturedAt > rhs.capturedAt
        }
    }
    static let pageSize = 40
    var totalRecordCount: Int { repository == nil ? records.count : catalog.count }
    var hasMoreRecords: Bool { catalog.contains { entry in !records.contains(where: { $0.id == entry.id }) } }
    private(set) var storageError: String?
    private(set) var sensitiveContentSkipped = false
    var onChange: (() -> Void)?
    private var observers: [UUID: () -> Void] = [:]
    func observe(_ callback: @escaping () -> Void) -> UUID { let id = UUID(); observers[id] = callback; return id }
    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func notify() { onChange?(); Array(observers.values).forEach { $0() } }
    static let maximumRecordBytes = 8 * 1_024 * 1_024
    static let maximumHistoryBytes = 64 * 1_024 * 1_024
    static let maximumRecords = 500

    private override convenience init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AILock", isDirectory: true)
        self.init(fileURL: directory.appendingPathComponent("clipboard-history.json"), defaults: .standard,
                  pasteboard: .general, repositoryURL: directory.appendingPathComponent("clipboard.sqlite"), loadAsynchronously: true)
    }

    init(fileURL: URL, defaults: UserDefaults, pasteboard: NSPasteboard, keyProvider: (() -> SymmetricKey?)? = nil, repositoryURL: URL? = nil, loadAsynchronously: Bool = false) {
        self.fileURL = fileURL; self.settings = AppSettings(defaults: defaults); self.pasteboard = pasteboard; self.keyProvider = keyProvider
        repository = repositoryURL.map { ClipboardRepository(url: $0) }
        super.init()
        if loadAsynchronously { reloadHistory() }
        else { applyLoadedHistory(Result { try readStoredHistory() }) }
    }

    /// Retry a failed read after Keychain access is restored, without replacing stored data.
    func reloadHistory() {
        guard !isLoadingHistory else { return }
        retryWork?.cancel(); retryWork = nil
        isLoadingHistory = true
        pageGeneration = UUID()
        isLoadingPage = false
        searchCancellation?.cancel(); searchGeneration = UUID(); isSearching = false
        let generation = pageGeneration
        notify()
        storageQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.readStoredHistory() }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pageGeneration == generation else { return }
                self.applyLoadedHistory(result)
                if !self.searchQuery.isEmpty || !self.sourceFilter.isEmpty || !self.typeFilter.isEmpty { self.search(self.searchQuery) }
                if self.timer != nil || self.saveAfterLoading { self.saveAfterLoading = false; self.save() }
                self.notify()
            }
        }
    }

    /// Back off transient read failures, and keep only one pending retry.
    private func scheduleReadRetry() {
        guard retriesEnabled, retryWork == nil else { return }
        let delay = min(30.0, pow(2.0, Double(min(retryAttempt, 5))))
        retryAttempt += 1
        let generation = pageGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.retriesEnabled, self.pageGeneration == generation else { return }
            self.retryWork = nil
            self.reloadHistory()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    var isPaused: Bool { settings.clipboardPaused }
    var skipSensitiveContent: Bool {
        get { settings.clipboardSkipSensitiveContent }
        set { settings.clipboardSkipSensitiveContent = newValue; notify() }
    }
    var retentionDays: Int {
        get { settings.clipboardRetentionDays }
        set { settings.clipboardRetentionDays = newValue; if isLoadingHistory { saveAfterLoading = true }; prune(); notify() }
    }

    func start() {
        guard timer == nil else { return }
        retriesEnabled = true
        if !canSave { scheduleReadRetry() }
        lastChangeCount = pasteboard.changeCount
        prune()
        if !records.isEmpty || FileManager.default.fileExists(atPath: fileURL.path) || repository.map({ FileManager.default.fileExists(atPath: $0.url.path) }) == true { save() }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate(); timer = nil
        retriesEnabled = false; retryWork?.cancel(); retryWork = nil
        storageQueue.sync {} // Flush queued snapshots before the application exits.
    }

    func setPaused(_ paused: Bool) {
        settings.clipboardPaused = paused
        lastChangeCount = pasteboard.changeCount
        notify()
    }

    func prepareForBackupRestore() {
        searchCancellation?.cancel(); searchGeneration = UUID(); isSearching = false
        pageGeneration = UUID(); isLoadingPage = false
        notify()
    }

    func copyBack(_ record: ClipboardRecord) { copyBack([record]) }
    func copyBack(_ records: [ClipboardRecord]) {
        guard !records.isEmpty else { return }
        let objects = records.flatMap { record in record.items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        } }
        pasteboard.clearContents()
        pasteboard.writeObjects(objects)
        lastChangeCount = pasteboard.changeCount
    }

    /// Retain the complete catalog when deleting a visible or searched record.
    func remove(_ id: UUID) {
        guard canSave, !isLoadingHistory,
              records.contains(where: { $0.id == id }) || catalog.contains(where: { $0.id == id }) else { return }
        records.removeAll { $0.id == id }
        catalog.removeAll { $0.id == id }
        searchResults.removeAll { $0.id == id }
        // Invalidate in-flight pages/searches so deleted results cannot reappear.
        pageGeneration = UUID(); isLoadingPage = false
        retryWork?.cancel(); retryWork = nil
        save()
        if !searchQuery.isEmpty || !sourceFilter.isEmpty || !typeFilter.isEmpty { search(searchQuery) }
        notify()
    }

    func clear() {
        retryWork?.cancel(); retryWork = nil; retryAttempt = 0
        records.removeAll(); catalog.removeAll(); pageGeneration = UUID(); isLoadingPage = false; isLoadingHistory = false
        searchCancellation?.cancel(); searchGeneration = UUID(); searchResults = []; searchMatchCount = 0; isSearching = false; saveAfterLoading = false
        // Explicit clear permits replacing a damaged history; incidental captures never do.
        canSave = true
        storageQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.repository?.clear()
                if FileManager.default.fileExists(atPath: self.fileURL.path) { try FileManager.default.removeItem(at: self.fileURL) }
                DispatchQueue.main.async { [weak self] in self?.storageError = nil; self?.notify() }
            } catch {
                let message = "历史文件清除失败：\(error.localizedDescription)"
                DispatchQueue.main.async { [weak self] in self?.storageError = message; self?.notify() }
            }
        }
        notify()
    }

    var excludedBundleIDs: [String] {
        settings.clipboardExcludedBundleIDs
    }

    func exclude(bundleID: String) {
        guard !bundleID.isEmpty else { return }
        settings.clipboardExcludedBundleIDs = excludedBundleIDs + [bundleID]
        notify()
    }

    func include(bundleID: String) {
        settings.clipboardExcludedBundleIDs = excludedBundleIDs.filter { $0 != bundleID }
        // Do not capture the clipboard left behind while the application was excluded.
        lastChangeCount = pasteboard.changeCount
        notify()
    }

    func setFilters(sourceBundleID: String, contentKind: String) {
        sourceFilter = sourceBundleID
        typeFilter = contentKind
        search(searchQuery)
    }

    func updateMetadata(for id: UUID, isPinned: Bool? = nil, isFavorite: Bool? = nil, note: String? = nil, replaceNote: Bool = false) {
        guard canSave, !isLoadingHistory else { return }
        let recordIndex = records.firstIndex(where: { $0.id == id })
        let resultIndex = searchResults.firstIndex(where: { $0.id == id })
        guard let original = recordIndex.map({ records[$0] }) ?? resultIndex.map({ searchResults[$0] }) else { return }
        var record = original
        if let isPinned { record.isPinned = isPinned }
        if let isFavorite { record.isFavorite = isFavorite }
        if replaceNote {
            let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            record.note = trimmed.isEmpty ? nil : Self.boundedNote(trimmed)
        }
        if let recordIndex { records[recordIndex] = record }
        if let resultIndex { searchResults[resultIndex] = record }
        if let catalogIndex = catalog.firstIndex(where: { $0.id == id }) { catalog[catalogIndex] = ClipboardCatalogEntry(record) }
        save(additionalRecords: recordIndex == nil ? [record] : [])
        if !searchQuery.isEmpty || !sourceFilter.isEmpty || !typeFilter.isEmpty { search(searchQuery) }
        notify()
    }

    func excludeCurrentApplication() {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        exclude(bundleID: bundleID)
    }

    private func poll() {
        guard !isLoadingHistory else { return }
        if Date().timeIntervalSince(lastPruneAt) >= 60 { prune(); lastPruneAt = Date() }
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard !isPaused else { return }
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        guard !excludedBundleIDs.contains(frontBundle),
              let items = pasteboard.pasteboardItems else { return }
        capture(items, sourceBundleID: frontBundle)
    }

    // Shared by polling and isolated tests. Reject oversized/sensitive copies in their entirety.
    func capture(_ sourceItems: [NSPasteboardItem], sourceBundleID: String) {
        guard canSave, !isLoadingHistory, !isPaused, !excludedBundleIDs.contains(sourceBundleID) else { return }
        let sensitiveTypes: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                                           "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"]
        guard !sourceItems.contains(where: { !$0.types.map(\.rawValue).filter(sensitiveTypes.contains).isEmpty }) else { return }
        sensitiveContentSkipped = false
        if settings.clipboardSkipSensitiveContent, Self.containsHighConfidenceSecret(sourceItems) {
            sensitiveContentSkipped = true; notify(); return
        }
        var items: [[String: Data]] = []
        var totalSize = 0
        for item in sourceItems {
            var values: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                guard data.count <= Self.maximumRecordBytes - totalSize else { return }
                totalSize += data.count
                values[type.rawValue] = data
            }
            if !values.isEmpty { items.append(values) }
        }
        guard !items.isEmpty, records.first?.items != items else { return }
        let record = ClipboardRecord(sourceBundleID: sourceBundleID, items: items)
        records.insert(record, at: 0)
        if repository != nil { catalog.insert(ClipboardCatalogEntry(record), at: 0) }
        prune(persist: false); save()
        if !searchQuery.isEmpty || !sourceFilter.isEmpty || !typeFilter.isEmpty { search(searchQuery) }
        notify()
    }

    private static func containsHighConfidenceSecret(_ items: [NSPasteboardItem]) -> Bool {
        let text = items.compactMap { item -> String? in
            guard let data = item.data(forType: .string) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n")
        guard !text.isEmpty else { return false }
        let patterns = [
            "-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----",
            "\\b(?:AKIA|ASIA)[A-Z0-9]{16}\\b",
            "\\bgithub_pat_[A-Za-z0-9_]{50,}\\b|\\bgh[pousr]_[A-Za-z0-9]{30,}\\b",
            "\\bxox[baprs]-[A-Za-z0-9-]{20,}\\b",
            "\\bAIza[0-9A-Za-z_-]{35}\\b",
            "\\bsk_live_[0-9A-Za-z]{20,}\\b",
            "\\beyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\b"
        ]
        return patterns.contains { pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
            return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    func prune(now: Date = Date(), persist: Bool = true) {
        guard !isLoadingHistory else { return }
        let count = totalRecordCount
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        if repository != nil {
            catalog.removeAll { $0.capturedAt < cutoff }
            if catalog.count > Self.maximumRecords { catalog.removeLast(catalog.count - Self.maximumRecords) }
            var bytes = 0
            catalog = catalog.filter { entry in
                guard entry.byteCount <= Self.maximumHistoryBytes - bytes else { return false }
                bytes += entry.byteCount; return true
            }
            let retained = Set(catalog.map(\.id))
            records.removeAll { !retained.contains($0.id) }
            searchResults.removeAll { !retained.contains($0.id) }
            if persist {
                save()
                if totalRecordCount != count {
                    if !searchQuery.isEmpty || !sourceFilter.isEmpty || !typeFilter.isEmpty { search(searchQuery) }
                    notify()
                }
            }
            return
        }
        records.removeAll { $0.capturedAt < cutoff }
        if records.count > Self.maximumRecords { records.removeLast(records.count - Self.maximumRecords) }
        var bytes = 0
        records = records.filter { record in
            guard record.byteCount <= Self.maximumHistoryBytes - bytes else { return false }
            bytes += record.byteCount
            return true
        }
        if persist && records.count != count { save(); notify() }
    }

    /// Search encrypted pages in bounded batches; never persist a plaintext search index.
    func search(_ query: String) {
        searchCancellation?.cancel()
        searchGeneration = UUID()
        searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchResults = []; searchMatchCount = 0; isSearching = false
        guard (!searchQuery.isEmpty || !sourceFilter.isEmpty || !typeFilter.isEmpty), !isLoadingHistory, canSave else {
            searchResults = []; searchMatchCount = 0; notify(); return
        }
        let query = searchQuery
        guard let repository else {
            let matches = records.filter { recordMatches($0, query: query) }
            searchMatchCount = matches.count; searchResults = Array(matches.prefix(100)); notify(); return
        }
        let entries = catalog.filter { entry in
            (sourceFilter.isEmpty || entry.sourceBundleID == sourceFilter)
                && (typeFilter.isEmpty || entry.contentKind == typeFilter)
        }
        let generation = searchGeneration
        let token = ClipboardSearchCancellation(); searchCancellation = token
        isSearching = true; notify()
        storageQueue.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, !token.isCancelled else { return }
            do {
                let key = try self.encryptionKey()
                var matches: [ClipboardRecord] = []; var count = 0
                for offset in stride(from: 0, to: entries.count, by: Self.pageSize) {
                    guard !token.isCancelled else { return }
                    let page = try repository.loadPage(entries: Array(entries[offset..<min(entries.count, offset + Self.pageSize)]), key: key)
                    for record in page where self.recordMatches(record, query: query) {
                        count += 1
                        if matches.count < 100 { matches.append(record) }
                    }
                }
                let results = matches; let total = count
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.searchGeneration == generation else { return }
                    let retained = Set(self.catalog.map(\.id))
                    self.searchResults = results.filter { retained.contains($0.id) }.sorted { lhs, rhs in
                        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                        return lhs.capturedAt > rhs.capturedAt
                    }
                    self.searchMatchCount = total; self.isSearching = false; self.notify()
                }
            } catch {
                let message = "剪贴板搜索读取失败，原数据已保留：\(error.localizedDescription)"
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.searchGeneration == generation else { return }
                    self.isSearching = false; self.canSave = false; self.storageError = message; self.scheduleReadRetry(); self.notify()
                }
            }
        }
    }

    private func recordMatches(_ record: ClipboardRecord, query: String) -> Bool {
        (query.isEmpty || (record.plainText?.localizedCaseInsensitiveContains(query) ?? record.preview.localizedCaseInsensitiveContains(query))
            || (record.note?.localizedCaseInsensitiveContains(query) ?? false))
            && (sourceFilter.isEmpty || record.sourceBundleID == sourceFilter)
            && (typeFilter.isEmpty || record.contentKind == typeFilter)
    }

    private static func boundedNote(_ value: String) -> String {
        var result = ""
        for character in value {
            let next = String(character)
            guard result.utf8.count + next.utf8.count <= 4096 else { break }
            result.append(contentsOf: next)
        }
        return result
    }

    /// Pages run on the same queue as persistence, so they never race a migration or clear.
    func loadMore() {
        guard let repository, canSave, !isLoadingPage, hasMoreRecords else { return }
        let loaded = Set(records.map(\.id))
        let entries = Array(catalog.filter { !loaded.contains($0.id) }.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.capturedAt > rhs.capturedAt
        }.prefix(Self.pageSize))
        let generation = pageGeneration
        isLoadingPage = true; notify()
        storageQueue.async { [weak self] in
            do {
                guard let self else { return }
                let key = try self.encryptionKey()
                let page = try repository.loadPage(entries: entries, key: key)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.pageGeneration == generation else { return }
                    let retained = Set(self.catalog.map(\.id))
                    let existing = Set(self.records.map(\.id))
                    self.records += page.filter { retained.contains($0.id) && !existing.contains($0.id) }
                    self.records.sort { $0.capturedAt == $1.capturedAt ? $0.id.uuidString > $1.id.uuidString : $0.capturedAt > $1.capturedAt }
                    self.isLoadingPage = false; self.notify()
                }
            } catch {
                let message = "剪贴板分页读取失败，原数据已保留：\(error.localizedDescription)"
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.pageGeneration == generation else { return }
                    self.isLoadingPage = false; self.canSave = false; self.storageError = message; self.scheduleReadRetry(); self.notify()
                }
            }
        }
    }

    private func readStoredHistory() throws -> (records: [ClipboardRecord], catalog: [ClipboardCatalogEntry]) {
        if let repository, FileManager.default.fileExists(atPath: repository.url.path) {
            let key = try encryptionKey()
            if let stored = try repository.loadCatalog(key: key) {
                let catalog = stored.sorted { $0.capturedAt == $1.capturedAt ? $0.id.uuidString > $1.id.uuidString : $0.capturedAt > $1.capturedAt }
                let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
                let visible = catalog.filter { $0.capturedAt >= cutoff }.sorted { lhs, rhs in
                    if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                    return lhs.capturedAt > rhs.capturedAt
                }
                let records = try repository.loadPage(entries: Array(visible.prefix(Self.pageSize)), key: key)
                return (records, catalog)
            }
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return ([], []) }
        let key = try encryptionKey()
        let encrypted = try Data(contentsOf: fileURL)
        let data = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: key)
        let records = try JSONDecoder().decode([ClipboardRecord].self, from: data)
        return (records, repository == nil ? [] : records.map(ClipboardCatalogEntry.init))
    }

    private func applyLoadedHistory(_ result: Result<(records: [ClipboardRecord], catalog: [ClipboardCatalogEntry]), Error>) {
        isLoadingHistory = false
        switch result {
        case let .success(loaded):
            canSave = true; storageError = nil; retryAttempt = 0
            retryWork?.cancel(); retryWork = nil
            records = loaded.records; catalog = loaded.catalog; prune(persist: false)
        case let .failure(error):
            canSave = false; storageError = "剪贴板历史读取失败，原数据已保留：\(error.localizedDescription)"
            scheduleReadRetry()
        }
    }

    private func save(additionalRecords: [ClipboardRecord] = []) {
        guard canSave, !isLoadingHistory else { return }
        let knownIDs = Set(records.map(\.id))
        let snapshot = records + additionalRecords.filter { !knownIDs.contains($0.id) }
        let catalogSnapshot = catalog
        storageQueue.async { [weak self] in
            guard let self else { return }
            do {
                let key = try self.encryptionKey()
                if let repository = self.repository {
                    try repository.persist(records: snapshot, catalog: catalogSnapshot, key: key)
                    // Only remove legacy data after the committed database is read and verified.
                    if FileManager.default.fileExists(atPath: self.fileURL.path) {
                        guard let verified = try repository.load(key: key), Set(verified.map(\.id)) == Set(catalogSnapshot.map(\.id)) else { throw ClipboardStorageError.verificationFailed }
                        try FileManager.default.removeItem(at: self.fileURL)
                    }
                    DispatchQueue.main.async { [weak self] in self?.storageError = nil; self?.notify() }
                    return
                }
                let data = try JSONEncoder().encode(snapshot)
                guard let encrypted = try AES.GCM.seal(data, using: key).combined else { throw ClipboardStorageError.keyUnavailable }
                try FileManager.default.createDirectory(at: self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try encrypted.write(to: self.fileURL, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.fileURL.path)
                DispatchQueue.main.async { [weak self] in self?.storageError = nil; self?.notify() }
            } catch {
                let message = "剪贴板历史保存失败：\(error.localizedDescription)"
                DispatchQueue.main.async { [weak self] in self?.storageError = message; self?.notify() }
            }
        }
    }

    func makeEncryptedBackup(passphrase: String) throws -> Data {
        guard passphrase.count >= 10, passphrase.utf8.count <= 4096 else { throw ClipboardStorageError.keyUnavailable }
        let state = Thread.isMainThread ? (catalog, records, canSave, isLoadingHistory) : DispatchQueue.main.sync { (catalog, records, canSave, isLoadingHistory) }
        guard state.2, !state.3 else { throw ClipboardStorageError.keyUnavailable }
        let allRecords = try storageQueue.sync { () throws -> [ClipboardRecord] in
            if let repository {
                let key = try encryptionKey()
                var result: [ClipboardRecord] = []
                for offset in stride(from: 0, to: state.0.count, by: Self.pageSize) {
                    result += try repository.loadPage(entries: Array(state.0[offset..<min(state.0.count, offset + Self.pageSize)]), key: key)
                }
                return result
            }
            return state.1
        }
        let payload = try JSONEncoder().encode(ClipboardBackupPayload(version: 1, createdAt: Date(), records: allRecords))
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let backupKey = Self.deriveBackupKey(passphrase: passphrase, salt: salt)
        guard let sealed = try AES.GCM.seal(payload, using: backupKey).combined else { throw ClipboardStorageError.keyUnavailable }
        var result = Data("AILOCKCBK1".utf8)
        result.append(salt); result.append(sealed)
        return result
    }

    func restoreEncryptedBackup(_ data: Data, passphrase: String) throws {
        let magic = Data("AILOCKCBK1".utf8)
        let prefixLength = magic.count + 16
        guard passphrase.count >= 10, passphrase.utf8.count <= 4096,
              data.count >= prefixLength + 28, data.count <= Self.maximumHistoryBytes * 3 + 2_000_000,
              data.prefix(magic.count) == magic else { throw ClipboardStorageError.malformedBackup }
        let salt = data.subdata(in: magic.count..<prefixLength)
        let encrypted = data.subdata(in: prefixLength..<data.count)
        let key = Self.deriveBackupKey(passphrase: passphrase, salt: salt)
        let plaintext: Data
        do { plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: key) }
        catch { throw ClipboardStorageError.invalidBackupPassphrase }
        let payload = try JSONDecoder().decode(ClipboardBackupPayload.self, from: plaintext)
        let imported = payload.records
        guard payload.version == 1, imported.count <= Self.maximumRecords,
              Set(imported.map(\.id)).count == imported.count else { throw ClipboardStorageError.malformedBackup }
        var totalBytes = 0
        for record in imported {
            guard record.capturedAt.timeIntervalSince1970.isFinite, !record.items.isEmpty, record.byteCount <= Self.maximumRecordBytes,
                  record.byteCount <= Self.maximumHistoryBytes - totalBytes,
                  (record.note?.utf8.count ?? 0) <= 4096,
                  record.sourceBundleID.utf8.count <= 1024 else { throw ClipboardStorageError.malformedBackup }
            totalBytes += record.byteCount
        }
        try storageQueue.sync {
            let key = try encryptionKey()
            if let repository {
                try repository.persist(records: imported, catalog: imported.map(ClipboardCatalogEntry.init), key: key)
            } else {
                let encoded = try JSONEncoder().encode(imported)
                guard let sealed = try AES.GCM.seal(encoded, using: key).combined else { throw ClipboardStorageError.keyUnavailable }
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try sealed.write(to: fileURL, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let sorted = imported.sorted { $0.capturedAt > $1.capturedAt }
            self.catalog = sorted.map(ClipboardCatalogEntry.init)
            self.records = Array(sorted.sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.capturedAt > rhs.capturedAt
            }.prefix(Self.pageSize))
            self.searchResults = []; self.searchQuery = ""; self.searchMatchCount = 0
            self.sourceFilter = ""; self.typeFilter = ""
            self.searchCancellation?.cancel(); self.searchGeneration = UUID(); self.isSearching = false
            self.pageGeneration = UUID(); self.isLoadingHistory = false; self.isLoadingPage = false; self.saveAfterLoading = false
            self.storageError = nil; self.canSave = true
            self.prune()
            self.notify()
        }
    }

    private static func deriveBackupKey(passphrase: String, salt: Data) -> SymmetricKey {
        let passwordKey = SymmetricKey(data: Data(passphrase.utf8))
        var block = salt
        var index = UInt32(1).bigEndian
        block.append(Data(bytes: &index, count: MemoryLayout<UInt32>.size))
        var u = Data(HMAC<SHA256>.authenticationCode(for: block, using: passwordKey))
        var derived = u
        for _ in 1..<180_000 {
            u = Data(HMAC<SHA256>.authenticationCode(for: u, using: passwordKey))
            for i in derived.indices { derived[i] ^= u[i] }
        }
        return SymmetricKey(data: derived)
    }

    private func encryptionKey() throws -> SymmetricKey {
        keyLock.lock(); defer { keyLock.unlock() }
        if let cachedKey { return cachedKey }
        if let keyProvider {
            guard let key = keyProvider() else { throw ClipboardStorageError.keyUnavailable }
            cachedKey = key; return key
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: "com.laogu.ailock.clipboard",
                                  kSecAttrAccount as String: "history-key",
                                  kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { let key = SymmetricKey(data: data); cachedKey = key; return key }
        guard status == errSecItemNotFound else { throw ClipboardStorageError.keychain(status) }
        // A new key cannot decrypt existing history. Never silently replace a missing key.
        guard !FileManager.default.fileExists(atPath: fileURL.path),
              repository.map({ FileManager.default.fileExists(atPath: $0.url.path) }) != true else {
            throw ClipboardStorageError.keyMissing
        }
        let key = SymmetricKey(size: .bits256)
        var add = query
        add.removeValue(forKey: kSecReturnData as String); add.removeValue(forKey: kSecMatchLimit as String)
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw ClipboardStorageError.keychain(addStatus) }
        cachedKey = key
        return key
    }
}

private enum ClipboardStorageError: LocalizedError {
    case keyUnavailable, keyMissing, verificationFailed, keychain(OSStatus), malformedBackup, invalidBackupPassphrase
    var errorDescription: String? {
        switch self {
        case .keyUnavailable: return "无法取得历史加密密钥，恢复钥匙串访问后将自动重试。"
        case .keyMissing: return "钥匙串中找不到原历史加密密钥，无法解密已有历史。"
        case .verificationFailed: return "历史迁移校验失败，原历史文件已保留。"
        case .malformedBackup: return "备份文件无效，或内容超出剪贴板历史限制。"
        case .invalidBackupPassphrase: return "备份口令错误，或备份文件已损坏。"
        case let .keychain(status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "未知钥匙串错误"
            return "钥匙串访问失败（\(status)）：\(detail)。恢复访问后将自动重试。"
        }
    }
}

private final class ClipboardSearchCancellation {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
