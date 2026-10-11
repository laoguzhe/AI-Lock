import AppKit
import CoreServices
import Darwin

enum SearchDiskAccess {
    /// Probe an existing FDA-protected file without reading its contents. Full
    /// Disk Access is granted in System Settings, rather than folder prompts.
    static func isGranted() -> Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        Darwin.close(descriptor)
        return true
    }
    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct SearchResult: Identifiable {
    enum Kind: Equatable { case application, file, directory }
    let id: String
    let title: String
    let path: String
    let kind: Kind

    var typeLabel: String { kind == .application ? "应用" : kind == .directory ? "文件夹" : "文件" }
    var icon: NSImage {
        let workspace = NSWorkspace.shared
        if kind == .directory { return workspace.icon(for: .folder) }
        if kind == .file, let application = workspace.urlForApplication(toOpen: URL(fileURLWithPath: path)) {
            return workspace.icon(forFile: application.path)
        }
        return workspace.icon(forFile: path)
    }

    static func item(at url: URL) -> SearchResult {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        let kind: Kind = url.pathExtension.lowercased() == "app" ? .application : values?.isDirectory == true ? .directory : .file
        return SearchResult(id: url.path, title: kind == .application ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent, path: url.path, kind: kind)
    }

    static func ordered(_ results: [SearchResult], matching term: String, recentPaths: [String] = []) -> [SearchResult] {
        let query = SearchFields.normalize(term)
        let recentRanks = Dictionary(recentPaths.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        func category(_ result: SearchResult) -> Int {
            switch result.kind {
            case .application: return 0
            case .directory: return 1
            case .file: return 2
            }
        }
        func depth(_ result: SearchResult) -> Int {
            URL(fileURLWithPath: result.path).standardizedFileURL.pathComponents.count
        }
        func relevance(_ result: SearchResult) -> Int {
            SearchFields(result.title).score(query) ?? Int.max
        }

        return results.sorted { left, right in
            let leftCategory = category(left), rightCategory = category(right)
            if leftCategory != rightCategory { return leftCategory < rightCategory }
            if left.kind == .directory, right.kind == .directory, depth(left) != depth(right) {
                return depth(left) < depth(right)
            }
            let leftScore = relevance(left), rightScore = relevance(right)
            if leftScore != rightScore { return leftScore < rightScore }
            let leftRecent = recentRanks[left.path] ?? Int.max
            let rightRecent = recentRanks[right.path] ?? Int.max
            if leftRecent != rightRecent { return leftRecent < rightRecent }
            let titleOrder = left.title.localizedCaseInsensitiveCompare(right.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return left.path < right.path
        }
    }

    func makeIconView(size: CGFloat) -> NSImageView {
        let view = NSImageView()
        view.image = icon
        view.imageScaling = .scaleProportionallyDown
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: size).isActive = true
        view.heightAnchor.constraint(equalToConstant: size).isActive = true
        return view
    }
}

final class QuickSearch {
    static let shared = QuickSearch()

    private let metadataQuery = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private var debounceWork: DispatchWorkItem?
    private var generation = 0
    private var metadataCapture = 0
    private var metadataGathering = false
    var isSearching: Bool { activeCompletion != nil && (metadataGathering || (usesNameCatalog && SearchNameCatalog.shared.building)) }
    private var indexedFiles: [SearchResult] = []
    private var directoryResults: [SearchResult] = []
    private let directoryQueue = DispatchQueue(label: "com.laogu.ailock.search.directories", qos: .utility)
    private var directoryCancellation = SearchDirectoryCancellation()
    private var activeTerm = ""
    private var activeCompletion: (([SearchResult]) -> Void)?
    private let catalog = ApplicationCatalog.shared
    private let resultLimit = 100
    private let directoryRoots: [URL]
    private let diskAccessCheck: () -> Bool
    private let usesNameCatalog: Bool
    private var directoryCapture = 0
    private(set) var requiresFullDiskAccess = false

    init(directoryRoots: [URL]? = nil, diskAccessCheck: @escaping () -> Bool = SearchDiskAccess.isGranted) {
        self.diskAccessCheck = diskAccessCheck
        usesNameCatalog = directoryRoots == nil
        let home = FileManager.default.homeDirectoryForCurrentUser
        // These four nearby roots are the only direct-scan supplement. Spotlight
        // handles the rest of the local computer without walking it on each query.
        self.directoryRoots = directoryRoots ?? ["Documents/项目", "Documents", "Desktop", "Downloads"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
        observers.append(NotificationCenter.default.addObserver(forName: SearchNameCatalog.didUpdate, object: SearchNameCatalog.shared, queue: .main) { [weak self] _ in
            guard let self, self.usesNameCatalog, self.activeCompletion != nil, !self.requiresFullDiskAccess else { return }
            self.searchCachedNames(self.activeTerm, request: self.generation)
        })
        observers.append(NotificationCenter.default.addObserver(forName: ApplicationCatalog.didUpdate, object: catalog, queue: .main) { [weak self] _ in
            guard let self, self.activeCompletion != nil else { return }
            self.publishResults()
        })
        catalog.refreshIfNeeded()
        metadataQuery.searchScopes = [NSMetadataQueryLocalComputerScope]
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate, object: metadataQuery, queue: .main
        ) { [weak self] _ in self?.captureMetadataResults() })
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: metadataQuery, queue: .main
        ) { [weak self] _ in self?.metadataGathering = false; self?.captureMetadataResults() })
    }

    deinit {
        debounceWork?.cancel()
        directoryCancellation.cancel()
        metadataQuery.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func warmUp() {
        guard usesNameCatalog, diskAccessCheck() else { return }
        SearchNameCatalog.shared.refreshIfNeeded(roots: directoryRoots)
    }

    func search(_ query: String, completion: @escaping ([SearchResult]) -> Void) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        generation += 1
        let request = generation
        debounceWork?.cancel()
        directoryCancellation.cancel()
        metadataQuery.stop()
        indexedFiles = []
        directoryResults = []
        activeTerm = term
        activeCompletion = nil
        requiresFullDiskAccess = false
        metadataGathering = false

        guard !term.isEmpty else { completion([]); return }
        activeCompletion = completion
        requiresFullDiskAccess = !diskAccessCheck()
        metadataGathering = !requiresFullDiskAccess
        let apps = applicationResults(matching: term)
        completion(Array(apps.prefix(resultLimit)))

        guard !requiresFullDiskAccess else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == request else { return }
            self.metadataQuery.predicate = NSPredicate(format: "kMDItemFSName CONTAINS[cd] %@", term)
            self.metadataGathering = self.metadataQuery.start()
            if self.usesNameCatalog {
                SearchNameCatalog.shared.refreshIfNeeded(roots: self.directoryRoots)
                self.searchCachedNames(term, request: request)
            } else { self.searchDirectories(term, request: request) }
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    func cancel() {
        generation += 1
        debounceWork?.cancel()
        debounceWork = nil
        directoryCancellation.cancel()
        metadataQuery.stop()
        indexedFiles = []
        activeCompletion = nil
        metadataGathering = false
    }

    func open(_ result: SearchResult) {
        NSWorkspace.shared.open(URL(fileURLWithPath: result.path))
    }

    private func captureMetadataResults() {
        guard !activeTerm.isEmpty, activeCompletion != nil else { return }
        metadataCapture += 1
        let capture = metadataCapture
        let request = generation
        let term = activeTerm
        var ranked: [SearchResult] = []
        var offset = 0
        func consume() {
            guard generation == request, metadataCapture == capture, activeCompletion != nil else { return }
            metadataQuery.disableUpdates()
            let end = min(offset + 128, metadataQuery.resultCount)
            if offset < end {
                for index in offset..<end {
                    guard let item = metadataQuery.result(at: index) as? NSMetadataItem,
                          let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                    let url = URL(fileURLWithPath: path)
                    guard Self.matchScore(term, against: [url.lastPathComponent]) != nil else { continue }
                    ranked.append(SearchResult.item(at: url))
                }
            }
            let count = metadataQuery.resultCount
            metadataQuery.enableUpdates()
            ranked = Array(SearchResult.ordered(ranked, matching: term).prefix(resultLimit))
            indexedFiles = ranked
            publishResults()
            offset = end
            if end < count { DispatchQueue.main.async { consume() } }
        }
        consume()
    }

    private func publishResults() {
        var seen = Set<String>()
        let files = (indexedFiles + directoryResults).filter { seen.insert($0.path).inserted }
        let results = SearchResult.ordered(applicationResults(matching: activeTerm) + files, matching: activeTerm)
        var unique = Set<String>()
        activeCompletion?(Array(results.filter { unique.insert($0.path).inserted }.prefix(resultLimit)))
    }

    private func searchCachedNames(_ term: String, request: Int) {
        directoryCapture += 1
        let capture = directoryCapture
        let records = SearchNameCatalog.shared.records
        let query = SearchFields.normalize(term)
        directoryQueue.async { [weak self] in
            let matches = records.compactMap { record -> SearchResult? in
                guard !query.isEmpty, record.normalized.contains(query) else { return nil }
                return record.item
            }
            let results = Array(SearchResult.ordered(matches, matching: term).prefix(100))
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == request, self.directoryCapture == capture, self.activeCompletion != nil else { return }
                self.directoryResults = results
                self.publishResults()
            }
        }
    }

    private func searchDirectories(_ term: String, request: Int) {
        let cancellation = SearchDirectoryCancellation()
        directoryCancellation = cancellation
        let roots = directoryRoots
        directoryQueue.async { [weak self] in
            var matches: [(SearchResult, Int)] = []
            var visited = Set<String>()
            var matchedPaths = Set<String>()
            var count = 0
            func publish() {
                let scores = Dictionary(matches.map { ($0.0.path, $0.1) }, uniquingKeysWith: min)
                let ordered = SearchResult.ordered(matches.map(\.0), matching: term)
                matches = ordered.prefix(100).compactMap { result in scores[result.path].map { (result, $0) } }
                let results = matches.map(\.0)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == request, !cancellation.isCancelled else { return }
                    self.directoryResults = results
                    self.publishResults()
                }
            }
            // Breadth-first traversal finds nearby folders before descending into
            // large caches or dependency trees. Common user folders lead the queue.
            var pending = roots
            var next = 0
            while next < pending.count {
                guard !cancellation.isCancelled else { return }
                let root = pending[next]; next += 1
                guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                guard visited.insert(root.standardizedFileURL.path).inserted else { continue }
                if let score = Self.matchScore(term, against: [root.lastPathComponent]), matchedPaths.insert(root.path).inserted {
                    matches.append((SearchResult.item(at: root), score)); publish()
                }
                guard let children = try? FileManager.default.contentsOfDirectory(at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey], options: [.skipsHiddenFiles]) else { continue }
                for url in children {
                    guard !cancellation.isCancelled else { return }
                    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]) else { continue }
                    if let score = Self.matchScore(term, against: [url.lastPathComponent]), matchedPaths.insert(url.path).inserted {
                        let kind: SearchResult.Kind = url.pathExtension.lowercased() == "app" ? .application : values.isDirectory == true ? .directory : .file
                        matches.append((SearchResult(id: url.path, title: url.lastPathComponent, path: url.path, kind: kind), score))
                        publish()
                    }
                    if values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true {
                        pending.append(url)
                    }
                    count += 1
                    if count % 256 == 0 { publish() }
                }
            }
            publish()
        }
    }

    private func applicationResults(matching term: String) -> [SearchResult] {
        catalog.refreshIfNeeded()
        let query = SearchFields.normalize(term)
        var candidates = Dictionary(uniqueKeysWithValues: catalog.entries.map { ($0.url.path, $0) })
        for app in NSWorkspace.shared.runningApplications {
            guard let url = app.bundleURL, candidates[url.path] == nil else { continue }
            let title = app.localizedName ?? url.deletingPathExtension().lastPathComponent
            candidates[url.path] = ApplicationCatalogEntry(url: url, title: L10n.text(title), bundleID: app.bundleIdentifier ?? "", searchFields: [SearchFields(title)])
        }
        return candidates.values.compactMap { entry -> (SearchResult, Int)? in
            guard let score = entry.searchFields.compactMap({ $0.score(query) }).min() else { return nil }
            return (SearchResult(id: entry.url.path, title: entry.title, path: entry.url.path, kind: .application), score)
        }.sorted { $0.1 == $1.1 ? $0.0.title.localizedCaseInsensitiveCompare($1.0.title) == .orderedAscending : $0.1 < $1.1 }
            .prefix(resultLimit).map(\.0)
    }

    private static func matchScore(_ query: String, against candidates: [String]) -> Int? {
        candidates.compactMap { SearchFields($0).score(SearchFields.normalize(query)) }.min()
    }
}

private final class SearchDirectoryCancellation {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// Input classification has no side effects; typing a command never executes it.
enum LauncherInput: Equatable {
    case empty, search(String), website(URL), command(String)

    /// Bare, hyphenated executable names are offered as terminal commands only
    /// when normal search has no result. Arguments remain explicit via `>`.
    static func inferredCommand(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("-"),
              text.range(of: "^[A-Za-z_][A-Za-z0-9_.+-]*$", options: .regularExpression) != nil else { return nil }
        return text
    }

    static func parse(_ input: String) -> LauncherInput {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        if text.hasPrefix(">") {
            let command = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            return command.isEmpty ? .empty : .command(command)
        }
        if !text.contains(where: { $0.isWhitespace || $0.isNewline }) {
            let explicit = text.lowercased().hasPrefix("https://") || text.lowercased().hasPrefix("http://")
            let candidate = explicit ? text : "https://" + text
            if let parts = URLComponents(string: candidate), let host = parts.host, !host.isEmpty,
               parts.user == nil, parts.password == nil, ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
               parts.port.map({ (1...65535).contains($0) }) ?? true,
               let url = parts.url {
                let suffix = host.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
                let common = ["com", "net", "org", "cn", "io", "ai", "dev", "app", "edu", "gov", "co", "me", "xyz", "info", "cc", "tv", "tech"]
                if explicit || host == "localhost" || (host.contains(".") && (common.contains(suffix) || host.allSatisfy({ $0.isNumber || $0 == "." }))) {
                    return .website(url)
                }
            }
        }
        return .search(text)
    }
}

enum LauncherTerminal {
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    /// A private, self-removing command file runs visibly in Terminal, never inside AI Lock.
    static func writeCommand(_ command: String, directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = directory.appendingPathComponent("ailock-" + UUID().uuidString + ".command")
        let script = "#!/bin/zsh -il\n/bin/rm -f -- " + shellQuote(url.path) + "\ncd -- " + shellQuote(FileManager.default.homeDirectoryForCurrentUser.path) + "\n" + command + "\nexec /bin/zsh -il\n"
        guard FileManager.default.createFile(atPath: url.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o700]) else {
            throw NSError(domain: "AILockTerminal", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建终端命令文件"])
        }
        return url
    }
    static func open(_ command: String, completion: @escaping (Error?) -> Void) {
        do {
            let url = try writeCommand(command)
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                try? FileManager.default.removeItem(at: url)
                throw NSError(domain: "AILockTerminal", code: 2, userInfo: [NSLocalizedDescriptionKey: "找不到 Terminal"])
            }
            NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if error != nil { try? FileManager.default.removeItem(at: url) }
                DispatchQueue.main.async { completion(error) }
            }
        } catch { completion(error) }
    }
}

/// A bounded cache of common folders supplements Spotlight without walking the disk per keystroke.
private final class SearchNameCatalog {
    struct Record { let item: SearchResult; let normalized: String }
    static let didUpdate = Notification.Name("AILockSearchNamesUpdated")
    static let shared = SearchNameCatalog()
    private(set) var records: [Record] = [] // main-thread owned
    private let queue = DispatchQueue(label: "com.laogu.ailock.search.name-index", qos: .utility)
    private(set) var building = false
    private var dirty = true
    private var refreshed = Date.distantPast
    private var monitors: [DirectoryActivityMonitor] = []
    private var pending: DispatchWorkItem?
    func refreshIfNeeded(roots: [URL]) {
        if monitors.isEmpty {
            for root in roots.filter({ ["Documents", "Desktop", "Downloads"].contains($0.lastPathComponent) }) {
                let monitor = DirectoryActivityMonitor()
                monitor.onEvents = { [weak self] events in
                    guard events.contains(where: { $0.needsRescan || $0.kind.contains("创建") || $0.kind.contains("删除") || $0.kind.contains("重命名") }), let self else { return }
                    self.dirty = true
                    guard self.pending == nil else { return }
                    let work = DispatchWorkItem { [weak self] in
                        self?.pending = nil
                        self?.refreshIfNeeded(roots: roots)
                    }
                    self.pending = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
                }
                if (try? monitor.start(root: root)) != nil { monitors.append(monitor) }
            }
        }
        guard !building, dirty || Date().timeIntervalSince(refreshed) > 60 else { return }
        building = true; dirty = false
        queue.async { [weak self] in
            var records: [Record] = []
            var visited = Set<String>()
            var items = Set<String>()
            var pending = roots.map { ($0, 0) }; var next = 0
            let skipped: Set<String> = ["node_modules", "vendor", "Pods", "DerivedData", "Caches", ".build", "Library"]
            var lastPublish = Date()
            func add(_ url: URL, directory: Bool) {
                guard items.insert(url.path).inserted else { return }
                let kind: SearchResult.Kind = url.pathExtension.lowercased() == "app" ? .application : directory ? .directory : .file
                let item = SearchResult(id: url.path, title: url.lastPathComponent, path: url.path, kind: kind)
                records.append(Record(item: item, normalized: SearchFields.normalize(item.title)))
            }
            func publish(finished: Bool) {
                let snapshot = records
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.records = snapshot
                    if finished { self.building = false; self.refreshed = Date() }
                    NotificationCenter.default.post(name: Self.didUpdate, object: self)
                }
                lastPublish = Date()
            }
            while next < pending.count, records.count < 40_000 {
                let (root, depth) = pending[next]; next += 1
                guard visited.insert(root.standardizedFileURL.path).inserted else { continue }
                guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                add(root, directory: true)
                guard depth < 4, !skipped.contains(root.lastPathComponent),
                      let children = try? FileManager.default.contentsOfDirectory(at: root,
                        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey], options: [.skipsHiddenFiles]) else { continue }
                for child in children {
                    guard records.count < 40_000 else { break }
                    guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]) else { continue }
                    add(child, directory: values.isDirectory == true)
                    if values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true, !skipped.contains(child.lastPathComponent) {
                        pending.append((child, depth + 1))
                    }
                }
                if next <= 2 || Date().timeIntervalSince(lastPublish) > 0.3 { publish(finished: false) }
            }
            publish(finished: true)
        }
    }
}
