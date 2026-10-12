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

    static func scanBatches(isSystem: Bool = false, batchSize: Int = 8, onBatch: ([CacheEntry], Bool) -> Void) {
        let manager = FileManager.default
        let root: URL
        if isSystem {
            root = URL(fileURLWithPath: "/Library/Caches", isDirectory: true)
        } else if let userRoot = manager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            root = userRoot
        } else {
            onBatch([], true)
            return
        }
        guard let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            onBatch([], true)
            return
        }
        let children = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        var batch: [CacheEntry] = []
        for child in children {
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            batch.append(CacheEntry(id: child, name: child.lastPathComponent, size: directorySize(child), isSystem: isSystem, url: child))
            if batch.count >= batchSize {
                onBatch(batch.sorted { $0.size > $1.size }, false)
                batch.removeAll(keepingCapacity: true)
            }
        }
        onBatch(batch.sorted { $0.size > $1.size }, true)
    }

    static func prepare(_ entries: [CacheEntry]) -> FileOperationPlan {
        let userRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches", isDirectory: true)
        let systemRoot = URL(fileURLWithPath: "/Library/Caches", isDirectory: true)
        var urls: [URL] = []
        var rejected: [FileActionResult] = []
        for entry in entries {
            let root = entry.isSystem ? systemRoot : userRoot
            guard ApplicationLocations.contains(entry.url, in: root),
                  let identity = FileIdentity(entry.url), !identity.isSymlink else {
                rejected.append(FileActionResult(url: entry.url, destination: nil, error: "缓存目录不在允许范围内或为符号链接")); continue
            }
            do { urls += try FileManager.default.contentsOfDirectory(at: entry.url, includingPropertiesForKeys: nil) }
            catch { rejected.append(FileActionResult(url: entry.url, destination: nil, error: error.localizedDescription)) }
        }
        let plan = FileOperationPlan.prepare(urls: urls, roots: [userRoot, systemRoot])
        return FileOperationPlan(items: plan.items, rejected: plan.rejected + rejected)
    }

    @discardableResult
    static func clean(_ entry: CacheEntry) -> Bool { prepare([entry]).execute().allSatisfy(\.succeeded) }

    static func cleanAll(_ entries: [CacheEntry]) -> (cleaned: Int, failed: Int) {
        let results = prepare(entries).execute()
        return (results.filter(\.succeeded).count, results.filter { !$0.succeeded }.count)
    }

    static func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else { return 0 }
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
