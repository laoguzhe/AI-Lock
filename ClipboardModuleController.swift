import AppKit
import UniformTypeIdentifiers

final class ClipboardModuleController: ModuleViewController {
    private let clipboardHistory: ClipboardHistory
    private var observer: UUID?
    private var widthObserver: NSObjectProtocol?
    private var scrollObserver: NSObjectProtocol?
    private weak var clipboardTags: ClipboardTagView?
    private weak var clipboardSearchField: NSSearchField?
    private weak var clipboardStatus: NSTextField?
    private weak var sourceFilterPopup: NSPopUpButton?
    private weak var typeFilterPopup: NSPopUpButton?
    init(history: ClipboardHistory) {
        clipboardHistory = history
        super.init(nibName: nil, bundle: nil)
        history.setPaused(false)
        observer = history.observe { [weak self] in self?.refresh() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    deinit {
        if let observer { clipboardHistory.removeObserver(observer) }
        if let widthObserver { NotificationCenter.default.removeObserver(widthObserver) }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }
    override func loadView() {
        let page = NSView(); page.translatesAutoresizingMaskIntoConstraints = false
        let clear = toolbarButton("清空历史", symbol: "trash", action: #selector(clearClipboard(_:)))
        let exclusions = toolbarButton("排除应用", symbol: "app.badge", action: #selector(showClipboardExclusions(_:)))
        let backup = toolbarButton("备份", symbol: "externaldrive", action: #selector(showBackupMenu(_:)))
        let search = NSSearchField(); search.translatesAutoresizingMaskIntoConstraints = false; search.placeholderString = L10n.text("搜索全部历史")
        search.target = self; search.action = #selector(filterClipboard(_:))
        let sourceFilter = NSPopUpButton(frame: .zero, pullsDown: false); sourceFilter.translatesAutoresizingMaskIntoConstraints = false
        sourceFilter.target = self; sourceFilter.action = #selector(clipboardFilterChanged(_:))
        let typeFilter = NSPopUpButton(frame: .zero, pullsDown: false); typeFilter.translatesAutoresizingMaskIntoConstraints = false
        typeFilter.addItems(withTitles: ["全部类型", "文本", "图片", "文件", "其他"])
        ["", "text", "image", "file", "other"].enumerated().forEach { typeFilter.item(at: $0.offset)?.representedObject = $0.element }
        typeFilter.target = self; typeFilter.action = #selector(clipboardFilterChanged(_:))
        let tags = ClipboardTagView()
        tags.onCopy = { [weak self] record in self?.clipboardHistory.copyBack(record); self?.clipboardStatus?.stringValue = L10n.text("已复制到系统剪贴板")}
        tags.onDelete = { [weak self] record in self?.clipboardHistory.remove(record.id) }
        tags.onTogglePin = { [weak self] record in self?.clipboardHistory.updateMetadata(for: record.id, isPinned: !record.isPinned) }
        tags.onToggleFavorite = { [weak self] record in self?.clipboardHistory.updateMetadata(for: record.id, isFavorite: !record.isFavorite) }
        tags.onEditNote = { [weak self] record in self?.editNote(for: record) }
        tags.onCopyPlainText = { record in
            guard let text = record.plainText else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        }
        tags.onOpenLink = { record in
            guard let data = record.values[NSPasteboard.PasteboardType.string.rawValue], let text = String(data: data, encoding: .utf8),
                  let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            NSWorkspace.shared.open(url)
        }
        tags.onRevealFile = { record in
            let urls = record.items.compactMap { values -> URL? in
                guard let data = values[NSPasteboard.PasteboardType.fileURL.rawValue], let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { return nil }
                return url
            }
            guard !urls.isEmpty else { return }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        let scroll = NSScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        tags.frame = NSRect(x: 0, y: 0, width: 700, height: 60)
        scroll.documentView = tags
        tags.scrollView = scroll
        scroll.postsFrameChangedNotifications = true
        widthObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak self, weak tags] _ in
            tags?.layoutTags(); self?.loadMoreIfNeeded()
        }
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            self?.loadMoreIfNeeded()
        }
        let status = label("点击标签复制。", size: 11, color: muted)
        [clear, exclusions, backup, search, sourceFilter, typeFilter, scroll, status].forEach(page.addSubview)
        NSLayoutConstraint.activate([
            page.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            clear.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), clear.topAnchor.constraint(equalTo: page.topAnchor, constant: 8),
            exclusions.trailingAnchor.constraint(equalTo: clear.leadingAnchor, constant: -12), exclusions.centerYAnchor.constraint(equalTo: clear.centerYAnchor),
            backup.trailingAnchor.constraint(equalTo: exclusions.leadingAnchor, constant: -12), backup.centerYAnchor.constraint(equalTo: clear.centerYAnchor),
            search.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 10), search.trailingAnchor.constraint(equalTo: clear.trailingAnchor), search.topAnchor.constraint(equalTo: clear.bottomAnchor, constant: 8),
            sourceFilter.leadingAnchor.constraint(equalTo: search.leadingAnchor), sourceFilter.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6), sourceFilter.widthAnchor.constraint(equalToConstant: 190),
            typeFilter.leadingAnchor.constraint(equalTo: sourceFilter.trailingAnchor, constant: 8), typeFilter.centerYAnchor.constraint(equalTo: sourceFilter.centerYAnchor), typeFilter.widthAnchor.constraint(equalToConstant: 120),
            scroll.leadingAnchor.constraint(equalTo: search.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: search.trailingAnchor), scroll.topAnchor.constraint(equalTo: sourceFilter.bottomAnchor, constant: 8), scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            status.leadingAnchor.constraint(equalTo: search.leadingAnchor), status.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -8),
            status.trailingAnchor.constraint(equalTo: search.trailingAnchor)
        ])
        clipboardTags = tags; clipboardSearchField = search; clipboardStatus = status
        sourceFilterPopup = sourceFilter; typeFilterPopup = typeFilter
        view = page
        clipboardHistory.start()
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    @objc private func showClipboardExclusions(_ sender: NSButton) {
        let menu = NSMenu()
        let add = NSMenuItem(title: L10n.text("选择要排除的应用…"), action: #selector(addClipboardExclusion(_:)), keyEquivalent: "")
        add.target = self; menu.addItem(add)
        menu.addItem(.separator())
        if clipboardHistory.excludedBundleIDs.isEmpty {
            let empty = NSMenuItem(title: L10n.text("尚未排除任何应用"), action: nil, keyEquivalent: "")
            empty.isEnabled = false; menu.addItem(empty)
        }
        for bundleID in clipboardHistory.excludedBundleIDs {
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.deletingPathExtension().lastPathComponent ?? bundleID
            let item = NSMenuItem(title: L10n.format("恢复采集：%{0}", arguments: [String(describing: name)]), action: #selector(removeClipboardExclusion(_:)), keyEquivalent: "")
            item.representedObject = bundleID; item.target = self; item.toolTip = L10n.text(bundleID)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func addClipboardExclusion(_ sender: Any?) {
        guard let targetWindow = view.window else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择要排除的应用")
        panel.message = L10n.text("该应用处于前台时暂停采集新内容；已有历史仍会保留。来源按前台应用推断，不能保证识别后台写入。")
        panel.prompt = L10n.text("排除应用"); panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = true; panel.allowedContentTypes = [.applicationBundle]
        panel.beginSheetModal(for: targetWindow) { [weak self] result in
            guard result == .OK, let self else { return }
            var rejected = false
            for url in panel.urls {
                guard let bundleID = Bundle(url: url)?.bundleIdentifier, !bundleID.isEmpty else { rejected = true; continue }
                self.clipboardHistory.exclude(bundleID: bundleID)
            }
            if rejected { self.clipboardStatus?.stringValue = L10n.text("部分应用没有有效标识，未加入排除列表")}
        }
    }

    @objc private func removeClipboardExclusion(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        clipboardHistory.include(bundleID: bundleID)
    }

    func refresh() {
        clipboardStatus?.toolTip = clipboardHistory.storageError.map { L10n.text($0) }
        clipboardTags?.records = clipboardHistory.displayedRecords
        clipboardTags?.filter = ""
        clipboardTags?.reloadTags()
        refreshFilterOptions()
        refreshStatusText()
        DispatchQueue.main.async { [weak self] in self?.loadMoreIfNeeded() }
    }
    func refreshStatusText() {
        clipboardStatus?.stringValue = L10n.text(clipboardHistory.isLoadingHistory ? L10n.text("正在读取加密历史…") : clipboardHistory.storageError.map { $0 + L10n.text(" · 稍后自动重试") } ?? L10n.format("已加载 %{0} / %{1} 条记录%{2} · 点击标签复制", arguments: [String(describing: clipboardHistory.records.count), String(describing: clipboardHistory.totalRecordCount), String(describing: clipboardHistory.isLoadingPage ? L10n.text(" · 正在加载…") : "")]))
        if !clipboardHistory.isLoadingHistory, (!clipboardHistory.searchQuery.isEmpty || !clipboardHistory.sourceFilter.isEmpty || !clipboardHistory.typeFilter.isEmpty), clipboardHistory.storageError == nil {
            clipboardStatus?.stringValue = L10n.text(clipboardHistory.isSearching ? L10n.text("正在搜索全部加密历史…") : L10n.format("匹配 %{0} 条 · 显示 %{1} 条（最多 100 条）", arguments: [String(describing: clipboardHistory.searchMatchCount), String(describing: clipboardHistory.searchResults.count)]))
        }
        if clipboardHistory.sensitiveContentSkipped { clipboardStatus?.stringValue = L10n.text("检测到高置信密钥，本条内容已跳过") }
    }
    private func loadMoreIfNeeded() {
        guard clipboardHistory.searchQuery.isEmpty, clipboardHistory.sourceFilter.isEmpty, clipboardHistory.typeFilter.isEmpty, clipboardHistory.storageError == nil,
              !clipboardHistory.isLoadingHistory, !clipboardHistory.isLoadingPage,
              clipboardHistory.hasMoreRecords, let tags = clipboardTags, let scroll = tags.scrollView,
              scroll.contentView.bounds.height > 0 else { return }
        if scroll.contentView.bounds.maxY >= tags.bounds.height - 100 {
            clipboardHistory.loadMore()
        }
    }
    @objc private func filterClipboard(_ sender: NSSearchField) { clipboardHistory.search(sender.stringValue); refresh() }
    @objc private func clipboardFilterChanged(_ sender: NSPopUpButton) {
        let source = (sourceFilterPopup?.selectedItem?.representedObject as? String) ?? ""
        let kind = (typeFilterPopup?.selectedItem?.representedObject as? String) ?? ""
        clipboardHistory.setFilters(sourceBundleID: source, contentKind: kind)
    }

    private func refreshFilterOptions() {
        guard let popup = sourceFilterPopup else { return }
        let selected = (popup.selectedItem?.representedObject as? String) ?? clipboardHistory.sourceFilter
        popup.removeAllItems(); popup.addItem(withTitle: L10n.text("全部来源")); popup.item(at: 0)?.representedObject = ""
        for bundleID in clipboardHistory.availableSourceBundleIDs {
            let appName = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.deletingPathExtension().lastPathComponent ?? bundleID
            popup.addItem(withTitle: appName); popup.lastItem?.representedObject = bundleID; popup.lastItem?.toolTip = bundleID
        }
        popup.select(popup.itemArray.first(where: { ($0.representedObject as? String) == selected }))
        if let typeFilterPopup, let item = typeFilterPopup.itemArray.first(where: { ($0.representedObject as? String) == clipboardHistory.typeFilter }) { typeFilterPopup.select(item) }
    }

    @objc private func showBackupMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let export = NSMenuItem(title: L10n.text("导出加密备份…"), action: #selector(exportClipboardBackup(_:)), keyEquivalent: "")
        export.target = self; menu.addItem(export)
        let restore = NSMenuItem(title: L10n.text("从备份恢复…"), action: #selector(importClipboardBackup(_:)), keyEquivalent: "")
        restore.target = self; menu.addItem(restore)
        menu.addItem(.separator())
        let sensitive = NSMenuItem(title: L10n.text("检测并跳过高置信密钥"), action: #selector(toggleSensitiveFiltering(_:)), keyEquivalent: "")
        sensitive.target = self; sensitive.state = clipboardHistory.skipSensitiveContent ? .on : .off
        menu.addItem(sensitive)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func toggleSensitiveFiltering(_ sender: NSMenuItem) {
        clipboardHistory.skipSensitiveContent.toggle()
        clipboardStatus?.stringValue = L10n.text(clipboardHistory.skipSensitiveContent ? "已开启高置信密钥跳过" : "已关闭高置信密钥跳过")
    }

    private func editNote(for record: ClipboardRecord) {
        let alert = NSAlert(); alert.messageText = L10n.text(record.note == nil ? "添加剪贴板备注" : "编辑剪贴板备注")
        alert.informativeText = L10n.text("备注会随剪贴板历史一起加密保存。")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); field.stringValue = record.note ?? ""
        field.placeholderString = L10n.text("输入备注")
        alert.accessoryView = field; alert.addButton(withTitle: L10n.text("保存")); alert.addButton(withTitle: L10n.text("取消"))
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.clipboardHistory.updateMetadata(for: record.id, note: field.stringValue, replaceNote: true)
        }
    }

    @objc private func exportClipboardBackup(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSSavePanel(); panel.title = L10n.text("导出加密剪贴板备份")
        panel.nameFieldStringValue = "AI-Lock-Clipboard.aiclip"; panel.allowedContentTypes = [.data]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url,
                  let passphrase = self.requestBackupPassphrase(confirm: true) else { return }
            self.clipboardStatus?.stringValue = L10n.text("正在生成加密备份…")
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result {
                    let data = try self.clipboardHistory.makeEncryptedBackup(passphrase: passphrase)
                    try data.write(to: url, options: [.atomic])
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
                DispatchQueue.main.async {
                    switch result {
                    case .success: self.clipboardStatus?.stringValue = L10n.text("加密备份已导出")
                    case let .failure(error): self.clipboardStatus?.stringValue = L10n.format("备份导出失败：%{0}", arguments: [String(describing: error.localizedDescription)])
                    }
                }
            }
        }
    }

    @objc private func importClipboardBackup(_ sender: Any?) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel(); panel.title = L10n.text("选择加密剪贴板备份")
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowedContentTypes = [.data]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url,
                  let passphrase = self.requestBackupPassphrase(confirm: false) else { return }
            let confirm = NSAlert(); confirm.messageText = L10n.text("替换当前剪贴板历史？")
            confirm.informativeText = L10n.text("导入会用备份中的记录替换本机当前历史。")
            confirm.addButton(withTitle: L10n.text("替换历史")); confirm.addButton(withTitle: L10n.text("取消"))
            confirm.beginSheetModal(for: window) { [weak self] answer in
                guard answer == .alertFirstButtonReturn, let self else { return }
                let wasPaused = self.clipboardHistory.isPaused
                self.clipboardHistory.prepareForBackupRestore()
                self.clipboardHistory.setPaused(true)
                self.clipboardStatus?.stringValue = L10n.text("正在解密并恢复备份…")
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result {
                        let data = try Data(contentsOf: url)
                        try self.clipboardHistory.restoreEncryptedBackup(data, passphrase: passphrase)
                    }
                    DispatchQueue.main.async {
                        self.clipboardHistory.setPaused(wasPaused)
                        switch result {
                        case .success: self.clipboardStatus?.stringValue = L10n.text("剪贴板历史已从备份恢复")
                        case let .failure(error): self.clipboardStatus?.stringValue = L10n.format("备份恢复失败：%{0}", arguments: [String(describing: error.localizedDescription)])
                        }
                    }
                }
            }
        }
    }

    private func requestBackupPassphrase(confirm: Bool) -> String? {
        let alert = NSAlert(); alert.messageText = L10n.text(confirm ? "设置备份口令" : "输入备份口令")
        alert.informativeText = L10n.text(confirm ? "请设置至少 10 个字符的口令，并妥善保存。AI Lock 无法找回遗失的口令。" : "输入创建此备份时设置的口令。")
        let first = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); first.placeholderString = L10n.text("备份口令")
        let second = NSSecureTextField(frame: first.frame); second.placeholderString = L10n.text("再次输入口令")
        if confirm {
            let stack = NSStackView(views: [first, second]); stack.orientation = .vertical; stack.spacing = 8; stack.frame = NSRect(x: 0, y: 0, width: 300, height: 56)
            alert.accessoryView = stack
        } else { alert.accessoryView = first }
        alert.addButton(withTitle: L10n.text("继续")); alert.addButton(withTitle: L10n.text("取消"))
        guard alert.runModal() == .alertFirstButtonReturn, first.stringValue.count >= 10,
              !confirm || first.stringValue == second.stringValue else {
            clipboardStatus?.stringValue = L10n.text("口令至少需要 10 个字符，且两次输入必须一致")
            return nil
        }
        return first.stringValue
    }

    @objc private func clearClipboard(_ sender: Any?) {
        let alert = NSAlert(); alert.messageText = L10n.text("清空剪贴板历史？"); alert.informativeText = L10n.text("本机保存的所有记录将被删除，此操作不可撤销。")
        alert.addButton(withTitle: L10n.text("取消")); alert.addButton(withTitle: L10n.text("清空"))
        guard let targetWindow = view.window else { return }
        alert.beginSheetModal(for: targetWindow) { [weak self] response in if response == .alertSecondButtonReturn { self?.clipboardHistory.clear() } }
    }

}
