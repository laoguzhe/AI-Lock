import Foundation
import Darwin

struct FileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt16
    init?(_ url: URL) {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return nil }
        device = UInt64(value.st_dev); inode = value.st_ino; mode = value.st_mode
    }
    var isSymlink: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFLNK) }
}

struct FileActionResult {
    let url: URL
    let destination: URL?
    let error: String?
    var succeeded: Bool { error == nil }
}

struct FileOperationPlan {
    struct Item {
        let url: URL
        let root: URL
        let identities: [(URL, FileIdentity)]
    }
    let items: [Item]
    let rejected: [FileActionResult]

    static func prepare(urls: [URL], roots: [URL]) -> FileOperationPlan {
        var items: [Item] = []
        var rejected: [FileActionResult] = []
        for url in urls {
            guard let root = roots.first(where: { ApplicationLocations.contains(url, in: $0) }),
                  let identity = FileIdentity(url), !identity.isSymlink else {
                rejected.append(FileActionResult(url: url, destination: nil, error: "路径越界、不可访问或为符号链接")); continue
            }
            var ancestors: [(URL, FileIdentity)] = [(url, identity)]
            var current = url.standardizedFileURL.deletingLastPathComponent()
            let canonicalRoot = root.standardizedFileURL
            var valid = true
            while true {
                guard let value = FileIdentity(current), !value.isSymlink else { valid = false; break }
                ancestors.append((current, value))
                if current.path == canonicalRoot.path { break }
                let parent = current.deletingLastPathComponent()
                if parent == current { valid = false; break }
                current = parent
            }
            if valid { items.append(Item(url: url, root: root, identities: ancestors)) }
            else { rejected.append(FileActionResult(url: url, destination: nil, error: "目录链包含符号链接或无法验证")) }
        }
        return FileOperationPlan(items: items, rejected: rejected)
    }

    func execute(move: (URL) throws -> URL? = { url in
        var destination: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
        return destination as URL?
    }) -> [FileActionResult] {
        var results = rejected
        for item in items {
            guard ApplicationLocations.contains(item.url, in: item.root),
                  item.identities.allSatisfy({ FileIdentity($0.0) == $0.1 }) else {
                results.append(FileActionResult(url: item.url, destination: nil, error: "确认后文件或目录身份已改变")); continue
            }
            do { results.append(FileActionResult(url: item.url, destination: try move(item.url), error: nil)) }
            catch { results.append(FileActionResult(url: item.url, destination: nil, error: error.localizedDescription)) }
        }
        return results
    }

    static func summary(_ results: [FileActionResult]) -> String {
        let succeeded = results.filter(\.succeeded).count
        return "已移入废纸篓 \(succeeded) 项，未完成 \(results.count - succeeded) 项。"
            + "\n" + results.map { "\($0.succeeded ? "成功" : "失败")：\($0.url.path)" + ($0.error.map { " — \($0)" } ?? "") }.joined(separator: "\n")
    }
}
