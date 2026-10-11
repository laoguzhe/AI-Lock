import AppKit

struct ApplicationCatalogEntry {
    let url: URL
    let title: String
    let bundleID: String
    let searchFields: [SearchFields]
}

struct SearchFields {
    let name: String
    let pinyin: String
    let initials: String
    init(_ value: String) {
        name = Self.normalize(value)
        let latin = value.applyingTransform(.toLatin, reverse: false)?
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "zh_CN")) ?? ""
        pinyin = latin.filter { $0.isLetter || $0.isNumber }
        initials = latin.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).compactMap(\.first).map(String.init).joined()
    }
    static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "zh_CN"))
            .filter { $0.isLetter || $0.isNumber }
    }
    func score(_ query: String) -> Int? {
        guard !query.isEmpty else { return nil }
        if name == query { return 0 }
        if name.hasPrefix(query) { return 1 }
        if name.contains(query) { return 2 }
        if pinyin.hasPrefix(query) { return 3 }
        if pinyin.contains(query) { return 4 }
        if initials.hasPrefix(query) { return 5 }
        return nil
    }
}

/// Published state is main-thread owned; filesystem work and transliteration run off-main.
final class ApplicationCatalog {
    static let shared = ApplicationCatalog()
    static let didUpdate = Notification.Name("AILockApplicationCatalogUpdated")
    private(set) var entries: [ApplicationCatalogEntry] = []
    private let queue = DispatchQueue(label: "com.laogu.ailock.application-catalog", qos: .utility)
    private let roots: [URL]
    private let scanner: ([URL]) -> [ApplicationCatalogEntry]
    private let watchesChanges: Bool
    private let refreshDelay: TimeInterval
    private var monitors: [DirectoryActivityMonitor] = []
    private var refreshing = false
    private var generation = UUID()
    private var dirty = false
    private var pending: DispatchWorkItem?
    private var refreshedAt = Date.distantPast
    private(set) var monitoringErrors: [String] = []

    init(roots: [URL] = ApplicationLocations.searchableRoots, watchChanges: Bool = true,
         refreshDelay: TimeInterval = 0.5, scanner: @escaping ([URL]) -> [ApplicationCatalogEntry] = ApplicationCatalog.scan) {
        self.roots = roots; self.watchesChanges = watchChanges
        self.refreshDelay = refreshDelay; self.scanner = scanner
    }

    func refreshIfNeeded(force: Bool = false) {
        if watchesChanges && monitors.isEmpty { startMonitoring() }
        if refreshing { if force { dirty = true }; return }
        guard force || dirty || Date().timeIntervalSince(refreshedAt) >= 60 else { return }
        pending?.cancel(); pending = nil
        refreshing = true; dirty = false
        let scanner = self.scanner; let roots = self.roots; let request = generation
        queue.async { [weak self] in
            let entries = scanner(roots)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == request else { return }
                self.entries = entries; self.refreshedAt = Date(); self.refreshing = false
                NotificationCenter.default.post(name: Self.didUpdate, object: self)
                if self.dirty { self.scheduleRefresh() }
            }
        }
    }

    /// Keep the first deadline so a continuous install/update cannot postpone refresh forever.
    func invalidate() {
        dirty = true; refreshedAt = .distantPast
        if !refreshing { scheduleRefresh() }
    }

    private func scheduleRefresh() {
        guard pending == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil; self.refreshIfNeeded(force: true)
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + refreshDelay, execute: item)
    }

    private func startMonitoring() {
        monitoringErrors = []
        var watched = Set<String>()
        for root in roots {
            // Watch the nearest existing ancestor, including creation of ~/Applications.
            var ancestor = root.standardizedFileURL
            while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
                ancestor.deleteLastPathComponent()
            }
            ancestor = ancestor.resolvingSymlinksInPath()
            guard watched.insert(ancestor.path).inserted else { continue }
            let monitor = DirectoryActivityMonitor()
            monitor.onEvents = { [weak self] events in
                guard let self else { return }
                let relevant = events.contains { event in
                    event.needsRescan || self.roots.contains { root in
                        let path = root.resolvingSymlinksInPath().standardizedFileURL.path
                        return event.path == path || event.path.hasPrefix(path + "/")
                    }
                }
                if events.contains(where: { $0.needsRescan }) {
                    self.monitors.forEach { $0.stop() }; self.monitors = []
                    self.startMonitoring()
                }
                if relevant { self.invalidate() }
            }
            do { try monitor.start(root: ancestor); monitors.append(monitor) }
            catch { monitoringErrors.append(ancestor.path + ": " + error.localizedDescription) }
        }
    }

    func stopMonitoring() {
        generation = UUID(); refreshing = false; dirty = false
        pending?.cancel(); pending = nil
        monitors.forEach { $0.stop() }; monitors = []
    }
    deinit { pending?.cancel(); monitors.forEach { $0.stop() } }

    static func scan(roots: [URL]) -> [ApplicationCatalogEntry] {
        var entries: [ApplicationCatalogEntry] = []
        enumerateApplications(roots: roots) { url, title, bundleID in
            let fileName = url.deletingPathExtension().lastPathComponent
            entries.append(ApplicationCatalogEntry(url: url, title: title, bundleID: bundleID,
                searchFields: [SearchFields(title), SearchFields(fileName)]))
        }
        return entries.sorted { $0.url.path < $1.url.path }
    }

    /// Deliver each application as soon as it is found, without traversing its bundle.
    static func enumerateApplications(roots: [URL], visit: (URL, String, String) -> Void) {
        var seen = Set<String>()
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { enumerator.skipDescendants(); continue }
                guard url.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
                let bundle = Bundle(url: url)
                let fileName = url.deletingPathExtension().lastPathComponent
                let title = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String ?? fileName
                visit(url, title, bundle?.bundleIdentifier ?? "")
            }
        }
    }
}
