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
    func search(_ query: String, completion: @escaping ([SearchResult]) -> Void) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { completion([]); return }
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [SearchResult] = []
            for application in NSWorkspace.shared.runningApplications {
                guard let url = application.bundleURL,
                      url.lastPathComponent.localizedCaseInsensitiveContains(term) else { continue }
                results.append(SearchResult(id: url.path, title: application.localizedName ?? url.deletingPathExtension().lastPathComponent,
                                            path: url.path, kind: .application))
            }
            let appURLs = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask) +
                          FileManager.default.urls(for: .applicationDirectory, in: .systemDomainMask)
            for directory in appURLs {
                guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isApplicationKey], options: [.skipsHiddenFiles]) else { continue }
                for url in urls where url.pathExtension == "app" && url.lastPathComponent.localizedCaseInsensitiveContains(term) {
                    if !results.contains(where: { $0.path == url.path }) {
                        results.append(SearchResult(id: url.path, title: url.deletingPathExtension().lastPathComponent, path: url.path, kind: .application))
                    }
                }
            }
            let queryString = "kMDItemFSName CONTAINS[cd] %@"
            let metadataQuery = NSMetadataQuery()
            metadataQuery.predicate = NSPredicate(format: queryString, term)
                metadataQuery.searchScopes = [NSMetadataQueryLocalComputerScope]
                let finished = DispatchSemaphore(value: 0)
                let observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: metadataQuery, queue: nil) { _ in finished.signal() }
                metadataQuery.start()
                if finished.wait(timeout: .now() + 2) == .success {
                    metadataQuery.disableUpdates()
                    for item in metadataQuery.results.prefix(max(0, 100 - results.count)) {
                        guard let item = item as? NSMetadataItem,
                              let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                        let url = URL(fileURLWithPath: path)
                        results.append(SearchResult(id: path, title: url.lastPathComponent, path: path, kind: .file))
                    }
                    metadataQuery.stop()
                }
                NotificationCenter.default.removeObserver(observer)
            DispatchQueue.main.async { completion(Array(results.prefix(100))) }
        }
    }

    func open(_ result: SearchResult) {
        NSWorkspace.shared.open(URL(fileURLWithPath: result.path))
    }
}
