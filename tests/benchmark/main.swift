import AppKit
import CryptoKit

let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ailock-benchmark-" + UUID().uuidString)
let suite = "com.laogu.ailock.benchmark." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
let key = SymmetricKey(size: .bits256)
defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
func elapsed(_ block: () throws -> Void) rethrows -> Double {
    let start = ProcessInfo.processInfo.systemUptime
    try block(); return (ProcessInfo.processInfo.systemUptime - start) * 1000
}
print("Synthetic fixtures only; milliseconds, no real clipboard or Keychain access.")
print("records,payload_bytes_each,catalog_ms,first_40_ms,incremental_save_ms,full_search_ms")
for (count, size) in [(20, 4096), (500, 4096), (500, 128 * 1024)] {
    let url = root.appendingPathComponent("case-\(count)-\(size).sqlite")
    let records = (0..<count).map { index in
        ClipboardRecord(capturedAt: Date().addingTimeInterval(-Double(index)), sourceBundleID: "benchmark.fixture", items: [["public.utf8-plain-text": Data(repeating: 65, count: size)]])
    }
    let repository = ClipboardRepository(url: url)
    try repository.replace(with: records, key: key)
    var catalog: [ClipboardCatalogEntry] = []
    let catalogMS = try elapsed { catalog = try repository.loadCatalog(key: key)! }
    var page: [ClipboardRecord] = []
    let pageMS = try elapsed { page = try repository.loadPage(entries: Array(catalog.prefix(40)), key: key) }
    let new = ClipboardRecord(sourceBundleID: "benchmark.fixture", items: [["public.utf8-plain-text": Data("new".utf8)]])
    catalog.insert(ClipboardCatalogEntry(new), at: 0)
    if catalog.count > ClipboardHistory.maximumRecords { catalog.removeLast() }
    let retained = Set(catalog.map(\.id))
    let saveMS = try elapsed { try repository.persist(records: [new] + page.filter { retained.contains($0.id) }, catalog: catalog, key: key) }
    let history = ClipboardHistory(fileURL: root.appendingPathComponent("absent.bin"), defaults: defaults, pasteboard: NSPasteboard.withUniqueName(), keyProvider: { key }, repositoryURL: url)
    let start = ProcessInfo.processInfo.systemUptime
    history.search("unmatched-fixture-query")
    let deadline = Date().addingTimeInterval(30)
    while history.isSearching && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    precondition(!history.isSearching && history.storageError == nil, "Search benchmark did not complete")
    let searchMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
    history.stop()
    print(String(format: "%d,%d,%.2f,%.2f,%.2f,%.2f", count, size, catalogMS, pageMS, saveMS, searchMS))
}
