import AppKit
import Foundation

struct CacheEntry: Identifiable {
    let id: URL
    let name: String
    let size: Int64
    let isSystem: Bool
    let url: URL
}

enum CacheCleaner {
    static func scan() -> [CacheEntry] {
        var entries: [CacheEntry] = []
        scanBatches { batch, _ in entries.append(contentsOf: batch) }
        return entries.sorted { $0.size > $1.size }
    }

    static func scanBatches(batchSize: Int = 8, onBatch: ([CacheEntry], Bool) -> Void) {
        let manager = FileManager.default
        guard let root = manager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            onBatch([], true)
            return
        }
        let children = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        var batch: [CacheEntry] = []
        for child in children {
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            batch.append(CacheEntry(id: child, name: child.lastPathComponent, size: directorySize(child), isSystem: false, url: child))
            if batch.count >= batchSize {
                onBatch(batch.sorted { $0.size > $1.size }, false)
                batch.removeAll(keepingCapacity: true)
            }
        }
        onBatch(batch.sorted { $0.size > $1.size }, true)
    }

    @discardableResult
    static func clean(_ entry: CacheEntry) -> Bool {
        let path = entry.url.standardizedFileURL.path
        let allowed = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches", isDirectory: true).standardizedFileURL.path
        guard !entry.isSystem, path.hasPrefix(allowed + "/"),
              let values = try? entry.url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return false }
        do {
            let children = try FileManager.default.contentsOfDirectory(at: entry.url, includingPropertiesForKeys: nil)
            for child in children { try FileManager.default.removeItem(at: child) }
            return true
        } catch {
            return false
        }
    }

    static func cleanAll(_ entries: [CacheEntry]) -> (cleaned: Int, failed: Int) {
        var cleaned = 0
        let userEntries = entries.filter { !$0.isSystem }
        for entry in userEntries where clean(entry) { cleaned += 1 }
        return (cleaned, userEntries.count - cleaned)
    }

    static func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if (try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
