import Foundation

final class FileActivityService {
    enum State {
        case idle
        case scanning(root: URL, scannedFiles: Int)
        case ready(FileScanSnapshot)
        case cancelled
        case failed(String)
    }
    typealias Scanner = (URL, ScanCancellation, @escaping (Int) -> Void) -> FileScanSnapshot
    private let scanner: Scanner
    private var cancellation: ScanCancellation?
    private var request = UUID()
    private(set) var state: State = .idle
    var onChange: (() -> Void)?
    init(scanner: @escaping Scanner = { root, cancellation, progress in
        FileScanService.scan(root: root, cancellation: cancellation, progress: progress)
    }) { self.scanner = scanner }

    func start(root: URL, scanner override: Scanner? = nil) {
        cancellation?.cancel()
        let token = ScanCancellation(); cancellation = token
        let current = UUID(); request = current
        state = .scanning(root: root, scannedFiles: 0); onChange?()
        let scanner = override ?? self.scanner
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = scanner(root, token) { count in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.request == current else { return }
                    self.state = .scanning(root: root, scannedFiles: count); self.onChange?()
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.request == current else { return }
                self.cancellation = nil
                if snapshot.cancelled { self.state = .cancelled }
                else if let error = snapshot.error { self.state = .failed(error) }
                else { self.state = .ready(snapshot) }
                self.onChange?()
            }
        }
    }
    func cancel() {
        let running = cancellation != nil
        cancellation?.cancel(); cancellation = nil; request = UUID()
        if running { state = .cancelled; onChange?() }
    }
    deinit { cancellation?.cancel() }
}

/// Serializes coalesced directory refreshes without starving a scan under heavy writes.
final class DirectoryAnalysisController {
    let activity: FileActivityService
    private(set) var root: URL?
    private var pending: DispatchWorkItem?
    private var dirty = false
    private var generation = UUID()
    private let delay: TimeInterval
    private let index: DirectoryIndex
    private let usesIndex: Bool
    private var pendingEvents: [DirectoryActivityEvent] = []
    var onChange: (() -> Void)?

    init(activity: FileActivityService? = nil, delay: TimeInterval = 0.6, index: DirectoryIndex = DirectoryIndex()) {
        self.activity = activity ?? FileActivityService(); self.delay = delay; self.index = index; self.usesIndex = activity == nil
        self.activity.onChange = { [weak self] in
            guard let self else { return }
            self.onChange?()
            switch self.activity.state {
            case .ready, .failed, .cancelled:
                if self.dirty { self.schedule() }
            default: break
            }
        }
    }

    func resumeCursor(root: URL) -> UInt64? { usesIndex ? index.resumeCursor(root: root) : nil }

    func start(root: URL, resume: Bool = false) {
        stop()
        self.root = FilesystemPath.canonical(root); dirty = false
        scan(root: self.root!, events: resume ? [] : nil)
    }
    private func scan(root: URL, events: [DirectoryActivityEvent]?) {
        if usesIndex {
            let index = self.index
            activity.start(root: root, scanner: { root, token, progress in index.update(root: root, events: events, cancellation: token, progress: progress) })
        } else { activity.start(root: root) }
    }

    func receive(_ events: [DirectoryActivityEvent]) {
        guard let root, !events.isEmpty else { return }
        let events = events.map { DirectoryActivityEvent(id: $0.id, date: $0.date, path: FilesystemPath.eventLocation(URL(fileURLWithPath: $0.path)).path, kind: $0.kind, needsRescan: $0.needsRescan, isHistoryDone: $0.isHistoryDone) }
        let prefix = root.path
        let descendantPrefix = prefix.hasSuffix("/") ? prefix : prefix + "/"
        guard events.contains(where: { $0.needsRescan || $0.path == prefix || $0.path.hasPrefix(descendantPrefix) }) else { return }
        let relevant = events.filter { !index.excludes($0.path) && ($0.needsRescan || $0.path == prefix || $0.path.hasPrefix(descendantPrefix)) }
        guard !relevant.isEmpty else { return }
        pendingEvents += relevant
        if pendingEvents.count > 4096 {
            pendingEvents = [DirectoryActivityEvent(id: relevant.last!.id, date: Date(), path: root.path, kind: "事件积压，完整重建", needsRescan: true)]
        }
        dirty = true
        if case .scanning = activity.state { return }
        schedule()
    }

    private func schedule() {
        // Keep the first deadline: continuous changes must not postpone refresh forever.
        guard pending == nil, root != nil else { return }
        let request = generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == request, let root = self.root else { return }
            self.pending = nil
            guard self.dirty else { return }
            if case .scanning = self.activity.state { return }
            self.dirty = false
            let events = self.pendingEvents; self.pendingEvents = []
            self.scan(root: root, events: events)
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func stop() {
        generation = UUID(); root = nil; dirty = false; pendingEvents = []
        pending?.cancel(); pending = nil
        activity.cancel()
    }
    deinit { pending?.cancel() }
}
