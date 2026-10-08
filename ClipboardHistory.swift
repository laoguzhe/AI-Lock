import AppKit
import CryptoKit
import Security
import CoreFoundation

struct ClipboardRecord: Codable, Identifiable {
    let id: UUID
    let capturedAt: Date
    let sourceBundleID: String
    let types: [String]
    let values: [String: Data]

    var preview: String {
        if let text = values[NSPasteboard.PasteboardType.string.rawValue], let value = String(data: text, encoding: .utf8) {
            return value.replacingOccurrences(of: "\n", with: " ").prefix(180).description
        }
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) { return "文件或文件夹引用" }
        if types.contains(NSPasteboard.PasteboardType.tiff.rawValue) || types.contains(NSPasteboard.PasteboardType.png.rawValue) { return "图像内容" }
        return types.joined(separator: ", ")
    }
}

final class ClipboardHistory: NSObject {
    private let pasteboard = NSPasteboard.general
    private let defaults = UserDefaults.standard
    private let fileURL: URL
    private var timer: Timer?
    private var lastChangeCount = -1
    private(set) var records: [ClipboardRecord] = []
    var onChange: (() -> Void)?

    override init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AILock", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("clipboard-history.json")
        super.init()
        load()
    }

    var isPaused: Bool { defaults.bool(forKey: "clipboard.paused") }
    var retentionDays: Int {
        get { max(1, defaults.object(forKey: "clipboard.retentionDays") as? Int ?? 3) }
        set { defaults.set(max(1, newValue), forKey: "clipboard.retentionDays"); prune() }
    }

    func start() {
        timer?.invalidate()
        lastChangeCount = pasteboard.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    }

    func setPaused(_ paused: Bool) {
        defaults.set(paused, forKey: "clipboard.paused")
        lastChangeCount = pasteboard.changeCount
        onChange?()
    }

    func copyBack(_ record: ClipboardRecord) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        for (type, data) in record.values { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
        pasteboard.writeObjects([item])
        lastChangeCount = pasteboard.changeCount
    }

    func copyBack(_ records: [ClipboardRecord]) {
        guard !records.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(records.map { record in
            let item = NSPasteboardItem()
            for (type, data) in record.values { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        })
        lastChangeCount = pasteboard.changeCount
    }

    func clear() {
        records.removeAll()
        save()
        onChange?()
    }

    func excludeCurrentApplication() {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        var excluded = defaults.stringArray(forKey: "clipboard.excludedBundleIDs") ?? []
        if !excluded.contains(bundleID) { excluded.append(bundleID) }
        defaults.set(excluded, forKey: "clipboard.excludedBundleIDs")
    }

    private func poll() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard !isPaused else { return }
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let excluded = defaults.stringArray(forKey: "clipboard.excludedBundleIDs") ?? []
        guard !excluded.contains(frontBundle) else { return }
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return }
        var values: [String: Data] = [:]
        var types: [String] = []
        var totalSize = 0
        for item in items {
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                totalSize += data.count
                guard totalSize <= 8 * 1_024 * 1_024 else { break }
                values[type.rawValue] = data
                types.append(type.rawValue)
            }
        }
        guard !values.isEmpty else { return }
        // Avoid duplicate records when apps publish several equivalent pasteboard changes.
        if let newest = records.first, newest.values == values { return }
        if values.values.reduce(0, { $0 + $1.count }) > 8 * 1_024 * 1_024 { return }
        records.insert(ClipboardRecord(id: UUID(), capturedAt: Date(), sourceBundleID: frontBundle,
                                       types: Array(Set(types)).sorted(), values: values), at: 0)
        prune()
        save()
        onChange?()
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        records.removeAll { $0.capturedAt < cutoff }
        save()
    }

    private func load() {
        guard let encrypted = try? Data(contentsOf: fileURL), let key = encryptionKey(),
              let box = try? AES.GCM.SealedBox(combined: encrypted),
              let data = try? AES.GCM.open(box, using: key),
              let decoded = try? JSONDecoder().decode([ClipboardRecord].self, from: data) else { return }
        records = decoded
        prune()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records), let key = encryptionKey(),
              let box = try? AES.GCM.seal(data, using: key), let encrypted = box.combined else { return }
        try? encrypted.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func encryptionKey() -> SymmetricKey? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "com.laogu.ailock.clipboard",
                                    kSecAttrAccount as String: "history-key",
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: "com.laogu.ailock.clipboard",
                                  kSecAttrAccount as String: "history-key",
                                  kSecValueData as String: data]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        return key
    }
}
