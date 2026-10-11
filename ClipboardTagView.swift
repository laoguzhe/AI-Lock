import AppKit

final class ClipboardTagView: NSView {
    var records: [ClipboardRecord]
    var filter = ""
    var onCopy: ((ClipboardRecord) -> Void)?
    var onDelete: ((ClipboardRecord) -> Void)?
    var onTogglePin: ((ClipboardRecord) -> Void)?
    var onToggleFavorite: ((ClipboardRecord) -> Void)?
    var onEditNote: ((ClipboardRecord) -> Void)?
    var onCopyPlainText: ((ClipboardRecord) -> Void)?
    var onOpenLink: ((ClipboardRecord) -> Void)?
    var onRevealFile: ((ClipboardRecord) -> Void)?
    private(set) var selectedRecords: [ClipboardRecord] = []
    private var buttons: [(NSButton, ClipboardRecord)] = []
    weak var scrollView: NSScrollView?
    private var previousWidth: CGFloat = 0
    private var tagsNeedLayout = true
    private var drawingTags = false

    override var isFlipped: Bool { true }

    init(records: [ClipboardRecord] = []) {
        self.records = records
        super.init(frame: .zero)
        NotificationCenter.default.addObserver(self, selector: #selector(languageChanged), name: L10n.changed, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func languageChanged() { reloadTags() }

    static func displayTitle(for record: ClipboardRecord) -> String {
        let preview = record.preview
        let body = preview.isEmpty ? L10n.text("空白内容") : preview
        let markers = [record.isPinned ? "📌" : nil, record.isFavorite ? "★" : nil].compactMap { $0 }.joined(separator: " ")
        if !markers.isEmpty { return markers + "  " + body }
        if preview.isEmpty { return body }
        // Pasted text is user content, even when it happens to equal an app label.
        if let data = record.values[NSPasteboard.PasteboardType.string.rawValue], String(data: data, encoding: .utf8) != nil { return preview }
        return L10n.text(preview)
    }

    func reloadTags() {
        tagsNeedLayout = true
        layoutTags()
    }

    func layoutTags() {
        guard !drawingTags else { return }
        let width = (scrollView?.contentView.bounds.width ?? bounds.width)
        guard width > 0 else { return }
        guard tagsNeedLayout || abs(width - previousWidth) > 1 else { return }
        drawingTags = true
        defer { drawingTags = false }
        tagsNeedLayout = false
        previousWidth = width
        let selectedIDs = Set(selectedRecords.map(\.id))
        subviews.forEach { $0.removeFromSuperview() }
        buttons.removeAll()
        imageViews.removeAll()
        let matching = records.filter { filter.isEmpty || $0.preview.localizedCaseInsensitiveContains(filter) }
        var x: CGFloat = 8, y: CGFloat = 8
        let maxWidth = max(200, width - 24)
        for record in matching {
            let imageData = record.values[NSPasteboard.PasteboardType.tiff.rawValue] ?? record.values[NSPasteboard.PasteboardType.png.rawValue]
            if let imageData, let image = NSImage(data: imageData) {
                if x > 8 { y += 38 }
                let imageWidth = min(300, max(1, width - 24))
                let imageView = ClipboardRecordImageView(frame: NSRect(x: 8, y: y, width: imageWidth, height: 1))
                imageView.recordMenu = contextMenu(for: record)
                imageView.image = image
                imageView.imageScaling = .scaleProportionallyUpOrDown
                imageView.wantsLayer = true
                imageView.layer?.cornerRadius = 6
                imageView.layer?.borderWidth = 1
                imageView.layer?.borderColor = NSColor.separatorColor.cgColor
                imageView.layer?.masksToBounds = true
                imageView.toolTip = record.note.map { L10n.format("点击图片复制 · 备注：%{0}", arguments: [String(describing: $0)]) } ?? L10n.text("点击图片复制")
                imageView.setAccessibilityElement(true)
                imageView.setAccessibilityRole(.button)
                imageView.setAccessibilityLabel(L10n.text("剪贴板图片"))
                imageView.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(imageClicked(_:))))
                let imageHeight = min(240, max(1, imageWidth * image.size.height / max(image.size.width, 1)))
                imageView.frame.size.height = imageHeight
                let itemView = ClipboardHistoryItemView(content: imageView, contextMenu: contextMenu(for: record)) { [weak self] in self?.onDelete?(record) }
                addSubview(itemView)
                imageViews[imageView] = record
                y += imageHeight + 10
                x = 8
                continue
            }
            let title = Self.displayTitle(for: record)
            let button = ClipboardRecordButton(title: title, target: self, action: #selector(tagClicked(_:)))
            button.recordMenu = contextMenu(for: record)
            button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 12); button.setButtonType(.toggle)
            button.toolTip = record.note.map { title + "\n" + L10n.format("备注：%{0}", arguments: [String(describing: $0)]) } ?? title
            button.lineBreakMode = .byTruncatingTail
            button.sizeToFit()
            let width = min(maxWidth, max(70, button.fittingSize.width + 40))
            if x + width > maxWidth + 8 { x = 8; y += 38 }
            button.frame = NSRect(x: x, y: y, width: width, height: 30)
            button.state = selectedIDs.contains(record.id) ? .on : .off
            let itemView = ClipboardHistoryItemView(content: button, contextMenu: contextMenu(for: record)) { [weak self] in self?.onDelete?(record) }
            addSubview(itemView); buttons.append((button, record))
            x += width + 8
        }
        if matching.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: L10n.text(filter.isEmpty ? L10n.text("暂无剪贴板记录") : L10n.text("没有匹配的记录")))
            empty.textColor = .secondaryLabelColor; empty.font = .systemFont(ofSize: 13); empty.frame = NSRect(x: 8, y: 12, width: maxWidth - 16, height: 28)
            addSubview(empty)
        }
        let height = max(60, max(y, 8) + 34)
        let documentWidth = max(width, maxWidth)
        frame = NSRect(x: 0, y: 0, width: documentWidth, height: height)
        invalidateIntrinsicContentSize()
        updateSelection()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(60, frame.height))
    }

    override func layout() {
        super.layout()
        layoutTags()
    }

    @objc private func tagClicked(_ sender: NSButton) {
        guard let pair = buttons.first(where: { $0.0 === sender }) else { return }
        if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
            updateSelection()
        } else {
            sender.state = .off
            onCopy?(pair.1)
        }
    }

    private var imageViews: [NSImageView: ClipboardRecord] = [:]

    @objc private func imageClicked(_ recognizer: NSClickGestureRecognizer) {
        guard let imageView = recognizer.view as? NSImageView, let record = imageViews[imageView] else { return }
        onCopy?(record)
    }

    private func updateSelection() {
        selectedRecords = buttons.compactMap { $0.0.state == .on ? $0.1 : nil }
    }

    private func contextMenu(for record: ClipboardRecord) -> NSMenu {
        let menu = NSMenu()
        addMenuItem(record.isPinned ? "取消置顶" : "置顶", action: "pin", record: record, to: menu)
        addMenuItem(record.isFavorite ? "取消收藏" : "收藏", action: "favorite", record: record, to: menu)
        addMenuItem(record.note == nil ? "添加备注…" : "编辑备注…", action: "note", record: record, to: menu)
        if record.types.contains(NSPasteboard.PasteboardType.string.rawValue)
            || record.types.contains(NSPasteboard.PasteboardType.html.rawValue)
            || record.types.contains(NSPasteboard.PasteboardType.rtf.rawValue) {
            addMenuItem("复制为纯文本", action: "plain", record: record, to: menu)
            if let text = record.values[NSPasteboard.PasteboardType.string.rawValue].flatMap({ String(data: $0, encoding: .utf8) }),
               let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                addMenuItem("打开链接", action: "open", record: record, to: menu)
            }
        }
        if record.values[NSPasteboard.PasteboardType.fileURL.rawValue] != nil {
            addMenuItem("在访达中显示", action: "reveal", record: record, to: menu)
        }
        menu.addItem(.separator())
        addMenuItem("删除", action: "delete", record: record, to: menu)
        return menu
    }

    private func addMenuItem(_ title: String, action: String, record: ClipboardRecord, to menu: NSMenu) {
        let item = NSMenuItem(title: L10n.text(title), action: #selector(contextAction(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = ClipboardContextAction(kind: action, id: record.id)
        menu.addItem(item)
    }

    @objc private func contextAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? ClipboardContextAction,
              let record = records.first(where: { $0.id == action.id }) else { return }
        switch action.kind {
        case "pin": onTogglePin?(record)
        case "favorite": onToggleFavorite?(record)
        case "note": onEditNote?(record)
        case "plain": onCopyPlainText?(record)
        case "open": onOpenLink?(record)
        case "reveal": onRevealFile?(record)
        case "delete": onDelete?(record)
        default: break
        }
    }
}

private final class ClipboardContextAction: NSObject {
    let kind: String
    let id: UUID
    init(kind: String, id: UUID) { self.kind = kind; self.id = id }
}

private final class ClipboardRecordButton: NSButton {
    var recordMenu: NSMenu?
    override func menu(for event: NSEvent) -> NSMenu? { recordMenu }
}

private final class ClipboardRecordImageView: NSImageView {
    var recordMenu: NSMenu?
    override func menu(for event: NSEvent) -> NSMenu? { recordMenu }
}


/// The close control belongs to the same hover region as the content, so moving
/// onto it keeps it visible and its click never invokes the copy action.
final class ClipboardHistoryItemView: NSView {
    private let content: NSView
    let deleteButton: NSButton
    private let onDelete: () -> Void
    private let contextMenu: NSMenu?
    private var hoverTracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    init(content: NSView, contextMenu: NSMenu? = nil, onDelete: @escaping () -> Void) {
        self.content = content; self.contextMenu = contextMenu; self.onDelete = onDelete
        deleteButton = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L10n.text("删除这条历史"))!, target: nil, action: nil)
        super.init(frame: content.frame)
        deleteButton.target = self; deleteButton.action = #selector(deleteItem(_:))
        deleteButton.isBordered = false; deleteButton.contentTintColor = .secondaryLabelColor
        deleteButton.imageScaling = .scaleProportionallyUpOrDown
        deleteButton.toolTip = L10n.text("删除这条剪贴板历史")
        deleteButton.setAccessibilityLabel(L10n.text("删除这条剪贴板历史"))
        deleteButton.isHidden = true
        addSubview(content); addSubview(deleteButton)
        layout()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func layout() {
        super.layout()
        content.frame = bounds
        deleteButton.frame = NSRect(x: max(0, bounds.width - 23), y: 5, width: 18, height: 18)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking); hoverTracking = tracking
        if let window {
            let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            deleteButton.isHidden = !visibleRect.contains(pointer)
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu }
    override func mouseEntered(with event: NSEvent) { deleteButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { deleteButton.isHidden = true }
    @objc private func deleteItem(_ sender: NSButton) { onDelete() }
}
