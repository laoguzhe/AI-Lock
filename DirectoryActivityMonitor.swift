import Foundation
import CoreServices

struct DirectoryActivityEvent {
    let id: UInt64
    let date: Date
    let path: String
    let kind: String
    let needsRescan: Bool
    let isHistoryDone: Bool
    init(id: UInt64, date: Date, path: String, kind: String, needsRescan: Bool, isHistoryDone: Bool = false) {
        self.id = id; self.date = date; self.path = path; self.kind = kind; self.needsRescan = needsRescan; self.isHistoryDone = isHistoryDone
    }
}

private final class DirectoryStreamContext {
    let root: String
    let deliver: ([DirectoryActivityEvent]) -> Void
    init(root: String, deliver: @escaping ([DirectoryActivityEvent]) -> Void) { self.root = root; self.deliver = deliver }
}

/// FSEvents reports coalescible changes, not process identities or content reads.
final class DirectoryActivityMonitor {
    private let queue = DispatchQueue(label: "com.laogu.ailock.directory-events", qos: .utility)
    private var stream: FSEventStreamRef?
    private var context: DirectoryStreamContext?
    private var generation = 0
    private(set) var events: [DirectoryActivityEvent] = []
    private(set) var root: URL?
    var onChange: (() -> Void)?
    var onEvents: (([DirectoryActivityEvent]) -> Void)?

    static func classify(_ flags: FSEventStreamEventFlags) -> (kind: String, needsRescan: Bool) {
        let dropped = flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged) != 0
        if dropped { return ("事件合并、丢失或目录变化；需重新扫描", true) }
        var kinds: [String] = []
        if flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 { kinds.append("创建") }
        if flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 { kinds.append("删除") }
        if flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 { kinds.append("重命名") }
        if flags & UInt32(kFSEventStreamEventFlagItemModified) != 0 { kinds.append("修改") }
        return (kinds.isEmpty ? "元数据或目录变化" : kinds.joined(separator: "、"), false)
    }

    func start(root: URL, since cursor: UInt64? = nil) throws {
        stop()
        let root = FilesystemPath.canonical(root)
        guard let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { throw NSError(domain: "AILockDirectoryMonitor", code: 1, userInfo: [NSLocalizedDescriptionKey: "请选择可访问的普通目录"]) }
        let request = generation
        let context = DirectoryStreamContext(root: root.path) { [weak self] batch in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == request, self.root != nil else { return }
                self.events.insert(contentsOf: batch.reversed(), at: 0)
                self.events = Array(self.events.prefix(500))
                self.onEvents?(batch)
                self.onChange?()
            }
        }
        var config = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(context).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let context = Unmanaged<DirectoryStreamContext>.fromOpaque(info).takeUnretainedValue()
            let values = unsafeBitCast(paths, to: NSArray.self)
            var events: [DirectoryActivityEvent] = []
            let start = count > 500 ? count - 499 : 0
            for index in start..<count {
                guard let path = values[index] as? String else { continue }
                let kind = DirectoryActivityMonitor.classify(flags[index])
                events.append(DirectoryActivityEvent(id: ids[index], date: Date(), path: path, kind: kind.kind, needsRescan: kind.needsRescan, isHistoryDone: flags[index] & UInt32(kFSEventStreamEventFlagHistoryDone) != 0))
            }
            if count > 500 {
                events.append(DirectoryActivityEvent(id: ids[count - 1], date: Date(), path: context.root,
                    kind: "事件批次超出显示容量；需重新扫描", needsRescan: true))
            }
            context.deliver(events)
        }
        guard let stream = FSEventStreamCreate(nil, callback, &config, [root.path] as CFArray,
            cursor ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)) else {
            throw NSError(domain: "AILockDirectoryMonitor", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法创建目录事件流"])
        }
        self.context = context; self.stream = stream; self.root = root; events = []
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            stop(); throw NSError(domain: "AILockDirectoryMonitor", code: 3, userInfo: [NSLocalizedDescriptionKey: "目录事件流启动失败"])
        }
        onChange?()
    }

    func stop() {
        generation += 1
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream)
            queue.sync {}
            FSEventStreamRelease(stream)
        }
        stream = nil; context = nil; root = nil
    }
    deinit { stop() }
}
