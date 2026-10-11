import Foundation

final class ScanCancellation {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

struct FileScanSnapshot {
    var largestFiles: [AnalyzedFile] = []
    var categories: [StorageCategory] = []
    var scannedFiles = 0
    var skippedItems = 0
    var matchingFiles = 0
    var cancelled = false
    var error: String?
    var indexUpdatedAt: Date?
    var indexWasRebuilt = false
}

/// One pass, bounded result storage, and explicit cancellation/error reporting.
enum FileScanService {
    static func scan(root: URL, threshold: Int64 = 100 * 1_024 * 1_024, limit: Int = 500,
                     cancellation: ScanCancellation = ScanCancellation(),
                     progress: ((Int) -> Void)? = nil) -> FileScanSnapshot {
        var result = FileScanSnapshot()
        guard !cancellation.isCancelled else { result.cancelled = true; return result }
        guard let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            result.error = "所选目录不存在、不可访问或是符号链接"; return result
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        var skipped = 0
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in skipped += 1; return !cancellation.isCancelled }) else {
            result.error = "无法读取所选目录"; return result
        }
        var groups: [String: (size: Int64, count: Int)] = [:]
        // Min-heap: retaining only the largest K avoids sorting all files.
        var heap: [AnalyzedFile] = []
        let capacity = max(0, limit)
        func less(_ a: AnalyzedFile, _ b: AnalyzedFile) -> Bool {
            a.size == b.size ? a.url.path > b.url.path : a.size < b.size
        }
        func retain(_ file: AnalyzedFile) {
            guard capacity > 0 else { return }
            if heap.count < capacity {
                heap.append(file)
                var child = heap.count - 1
                while child > 0 {
                    let parent = (child - 1) / 2
                    guard less(heap[child], heap[parent]) else { break }
                    heap.swapAt(child, parent); child = parent
                }
            } else if less(heap[0], file) {
                heap[0] = file
                var parent = 0
                while parent * 2 + 1 < heap.count {
                    var child = parent * 2 + 1
                    if child + 1 < heap.count, less(heap[child + 1], heap[child]) { child += 1 }
                    guard less(heap[child], heap[parent]) else { break }
                    heap.swapAt(parent, child); parent = child
                }
            }
        }
        for case let url as URL in enumerator {
            if cancellation.isCancelled { result.cancelled = true; break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { skipped += 1; continue }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            result.scannedFiles += 1
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            let name = category(url.pathExtension.lowercased())
            let old = groups[name] ?? (0, 0)
            let addition = old.size.addingReportingOverflow(size)
            groups[name] = (addition.overflow ? Int64.max : addition.partialValue, old.count + 1)
            if size >= threshold { result.matchingFiles += 1; retain(AnalyzedFile(url: url, size: size)) }
            if result.scannedFiles % 256 == 0 { progress?(result.scannedFiles) }
        }
        result.cancelled = result.cancelled || cancellation.isCancelled
        result.skippedItems = skipped
        result.largestFiles = heap.sorted { $0.size == $1.size ? $0.url.path < $1.url.path : $0.size > $1.size }
        result.categories = groups.map { StorageCategory(name: $0.key, size: $0.value.size, count: $0.value.count) }
            .sorted { $0.size == $1.size ? $0.name < $1.name : $0.size > $1.size }
        return result
    }

    static func category(_ ext: String) -> String {
        if ["dmg", "pkg", "zip", "7z", "rar"].contains(ext) { return "安装包与压缩文件" }
        if ["mov", "mp4", "mkv", "avi"].contains(ext) { return "视频" }
        if ["jpg", "jpeg", "png", "heic", "tif", "raw"].contains(ext) { return "图片" }
        if ["aif", "aiff", "wav", "mp3", "m4a", "flac"].contains(ext) { return "音频" }
        if ["pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx"].contains(ext) { return "文档" }
        return "其他文件"
    }
}
