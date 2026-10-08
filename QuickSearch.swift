import AppKit
import CoreServices

struct SearchResult: Identifiable {
    enum Kind: Equatable { case application, file }
    let id: String
    let title: String
    let path: String
    let kind: Kind
}

final class QuickSearch {
    private let metadataQuery = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private var debounceWork: DispatchWorkItem?
    private var generation = 0
    private var indexedFiles: [SearchResult] = []
    private var activeTerm = ""
    private var activeCompletion: (([SearchResult]) -> Void)?
    private var appCatalog: [SearchResult] = []
    private var appCatalogBuiltAt: Date?
    private let resultLimit = 100

    init() {
        metadataQuery.searchScopes = [NSMetadataQueryLocalComputerScope]
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate, object: metadataQuery, queue: .main
        ) { [weak self] _ in self?.captureMetadataResults() })
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: metadataQuery, queue: .main
        ) { [weak self] _ in self?.captureMetadataResults() })
    }

    deinit {
        debounceWork?.cancel()
        metadataQuery.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func search(_ query: String, completion: @escaping ([SearchResult]) -> Void) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        generation += 1
        let request = generation
        debounceWork?.cancel()
        metadataQuery.stop()
        indexedFiles = []

        guard !term.isEmpty else { completion([]); return }
        activeTerm = term
        activeCompletion = completion
        let apps = applicationResults(matching: term)
        completion(Array(apps.prefix(resultLimit)))

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == request else { return }
            self.metadataQuery.predicate = NSPredicate(format: "kMDItemFSName CONTAINS[cd] %@", term)
            self.metadataQuery.start()
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    func cancel() {
        generation += 1
        debounceWork?.cancel()
        debounceWork = nil
        metadataQuery.stop()
        indexedFiles = []
        activeCompletion = nil
    }

    func open(_ result: SearchResult) {
        NSWorkspace.shared.open(URL(fileURLWithPath: result.path))
    }

    private func captureMetadataResults() {
        metadataQuery.disableUpdates()
        indexedFiles = metadataQuery.results.compactMap { item in
            guard let item = item as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
            let url = URL(fileURLWithPath: path)
            return SearchResult(id: path, title: url.lastPathComponent, path: path, kind: .file)
        }
        metadataQuery.enableUpdates()
        let matchingFiles = indexedFiles.compactMap { result -> (SearchResult, Int)? in
            Self.matchScore(activeTerm, against: [result.title]).map { (result, $0 + 6) }
        }.sorted { $0.1 < $1.1 }.prefix(resultLimit).map(\.0)
        let apps = applicationResults(matching: activeTerm)
        activeCompletion?(Array((apps + matchingFiles).prefix(resultLimit)))
    }

    private func applicationResults(matching term: String) -> [SearchResult] {
        if appCatalogBuiltAt == nil || Date().timeIntervalSince(appCatalogBuiltAt!) > 60 {
            rebuildApplicationCatalog()
        }
        let running = NSWorkspace.shared.runningApplications.compactMap { app -> SearchResult? in
            guard let url = app.bundleURL else { return nil }
            return SearchResult(id: url.path, title: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                                path: url.path, kind: .application)
        }
        let candidates = Dictionary((appCatalog + running).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first }).values
        return candidates.compactMap { result -> (SearchResult, Int)? in
            let score = Self.matchScore(term, against: [result.title, URL(fileURLWithPath: result.path).deletingPathExtension().lastPathComponent])
            return score.map { (result, $0) }
        }.sorted { $0.1 == $1.1 ? $0.0.title.localizedCaseInsensitiveCompare($1.0.title) == .orderedAscending : $0.1 < $1.1 }
            .prefix(resultLimit).map(\.0)
    }

    private func rebuildApplicationCatalog() {
        let directories = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask) +
                          FileManager.default.urls(for: .applicationDirectory, in: .systemDomainMask)
        var byPath: [String: SearchResult] = [:]
        for directory in directories {
            guard let enumerator = FileManager.default.enumerator(at: directory,
                includingPropertiesForKeys: [.isApplicationKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                if url.pathExtension == "app" {
                    let title = url.deletingPathExtension().lastPathComponent
                    byPath[url.path] = SearchResult(id: url.path, title: title, path: url.path, kind: .application)
                    enumerator.skipDescendants()
                }
            }
        }
        appCatalog = Array(byPath.values)
        appCatalogBuiltAt = Date()
    }

    private static func matchScore(_ query: String, against candidates: [String]) -> Int? {
        let foldedQuery = normalize(query)
        guard !foldedQuery.isEmpty else { return nil }
        var best: Int?
        for candidate in candidates {
            let folded = normalize(candidate)
            if folded == foldedQuery { best = min(best ?? 0, 0); continue }
            if folded.hasPrefix(foldedQuery) { best = min(best ?? 1, 1); continue }
            if folded.localizedStandardContains(foldedQuery) { best = min(best ?? 2, 2); continue }

            let pinyin = candidate.applyingTransform(.toLatin, reverse: false)?
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "zh_CN")) ?? ""
            let compactPinyin = pinyin.filter { $0.isLetter || $0.isNumber }
            let initials = pinyin.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).compactMap(\.first).map(String.init).joined()
            if compactPinyin.hasPrefix(foldedQuery) { best = min(best ?? 3, 3) }
            else if compactPinyin.localizedStandardContains(foldedQuery) { best = min(best ?? 4, 4) }
            else if initials.hasPrefix(foldedQuery) { best = min(best ?? 5, 5) }
        }
        return best
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "zh_CN"))
            .filter { $0.isLetter || $0.isNumber }
    }
}
