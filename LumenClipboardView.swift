import AppKit
import SwiftUI

// ============================================================================
//  剪贴板历史
//  加密存储、分页、搜索、排除应用、备份恢复的调用方式保持不变；
//  标签流改为卡片网格 —— 同样的信息密度，但扫读更快、预览可辨。
// ============================================================================

@MainActor
final class ClipboardPageModel: ObservableObject {
    @Published var search = ""
    @Published var sourceFilter = ""
    @Published var typeFilter = ""
    @Published var status = "点击卡片复制。"
    @Published var noteEditing: ClipboardRecord?
    @Published var noteText = ""
    @Published var showClearConfirm = false
    @Published var showBackupSheet = false
    @Published var clipboardAccessNotice: String?
    @Published var passphrase = ""
    @Published var passphraseConfirm = ""
    @Published var backupMode: BackupMode = .export
    @Published var exclusionList: [String] = []

    enum BackupMode { case export, restore }

    let history: ClipboardHistory
    private var observer: UUID?

    init(history: ClipboardHistory = .shared) {
        self.history = history
    }

    func start() {
        history.start()
        if observer == nil {
            observer = history.observe { [weak self] in
                Task { @MainActor in self?.refresh() }
            }
        }
        refresh()
    }

    func stop() {
        if let observer { history.removeObserver(observer) }
        observer = nil
    }

    func refresh() {
        if let error = history.storageError {
            status = error + " · 稍后自动重试"
        } else if history.isLoadingHistory {
            status = "正在读取加密历史…"
        } else if !search.isEmpty || !sourceFilter.isEmpty || !typeFilter.isEmpty {
            status = history.isSearching
                ? "正在搜索全部加密历史…"
                : "匹配 \(history.searchMatchCount) 条 · 显示 \(history.searchResults.count) 条（最多 100 条）"
        } else {
            status = "已加载 \(history.records.count) / \(history.totalRecordCount) 条记录"
                + (history.isLoadingPage ? " · 正在加载…" : "")
        }
        if history.sensitiveContentSkipped { status = "检测到高置信密钥，本条内容已跳过" }
        if history.oversizedContentSkipped { status = "本条剪贴板内容超过 50 MB，未保存到历史记录（包含所有格式的总大小）。" }
        exclusionList = history.excludedBundleIDs
    }

    func loadMoreIfNeeded() {
        guard search.isEmpty, sourceFilter.isEmpty, typeFilter.isEmpty,
              history.storageError == nil,
              !history.isLoadingHistory, !history.isLoadingPage,
              history.hasMoreRecords else { return }
        history.loadMore()
    }

    var records: [ClipboardRecord] { history.displayedRecords }

    var sourceOptions: [(String, String)] {
        [("全部来源", "")] + history.availableSourceBundleIDs.map { (displayName($0), $0) }
    }

    func displayName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?
            .deletingPathExtension().lastPathComponent ?? bundleID
    }

    func applyFilters() {
        history.setFilters(sourceBundleID: sourceFilter, contentKind: typeFilter)
        refresh()
    }

    func copy(_ record: ClipboardRecord) {
        history.copyBack(record)
        status = "已复制到系统剪贴板"
    }

    func checkClipboardAccess() {
        if history.pasteboardAccessDenied {
            let notice = "剪贴板访问当前被系统拒绝。请在系统设置「隐私与安全性」中找到剪贴板访问，并允许 AI Lock。"
            clipboardAccessNotice = notice
            status = notice
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") { NSWorkspace.shared.open(url) }
        } else if history.isPaused {
            let notice = "剪贴板采集已暂停。点击「继续采集」后，再检查剪贴板访问。"
            clipboardAccessNotice = notice
            status = notice
        } else if history.isLoadingHistory {
            let notice = "剪贴板历史仍在加载，请稍后再检查访问。"
            clipboardAccessNotice = notice
            status = notice
        } else if let error = history.storageError {
            let notice = "剪贴板历史暂时不可用，无法保存检查到的内容：\(error)"
            clipboardAccessNotice = notice
            status = notice
        } else {
            let read = history.readCurrentClipboard()
            refresh()
            if history.oversizedContentSkipped {
                clipboardAccessNotice = "剪贴板内容超过 50 MB，未保存到历史记录。"
            } else if read {
                clipboardAccessNotice = "已成功读取当前剪贴板；若内容符合过滤规则，会显示在历史列表中。"
            } else {
                clipboardAccessNotice = "未读取到剪贴板内容。请先复制内容；如果系统弹出访问请求，请选择允许。"
            }
            status = clipboardAccessNotice ?? status
        }
    }

    func remove(_ record: ClipboardRecord) {
        history.remove(record.id)
        refresh()
    }

    func togglePin(_ record: ClipboardRecord) {
        history.updateMetadata(for: record.id, isPinned: !record.isPinned)
    }

    func toggleFavorite(_ record: ClipboardRecord) {
        history.updateMetadata(for: record.id, isFavorite: !record.isFavorite)
    }

    func copyPlainText(_ record: ClipboardRecord) {
        guard let text = record.plainText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "已复制纯文本"
    }

    func openLink(_ record: ClipboardRecord) {
        guard let data = record.values[NSPasteboard.PasteboardType.string.rawValue],
              let text = String(data: data, encoding: .utf8),
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    func revealFile(_ record: ClipboardRecord) {
        let urls = record.items.compactMap { values -> URL? in
            guard let data = values[NSPasteboard.PasteboardType.fileURL.rawValue],
                  let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { return nil }
            return url
        }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func beginNote(_ record: ClipboardRecord) {
        noteEditing = record
        noteText = record.note ?? ""
    }

    func saveNote() {
        guard let record = noteEditing else { return }
        history.updateMetadata(for: record.id, note: noteText, replaceNote: true)
        noteEditing = nil
        status = noteText.isEmpty ? "已清除备注" : "已保存备注"
    }

    func addExclusion() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择要排除的应用")
        panel.message = L10n.text("该应用处于前台时暂停采集新内容；已有历史仍会保留。来源按前台应用推断，不能保证识别后台写入。")
        panel.prompt = L10n.text("排除应用")
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK else { return }
        var rejected = false
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier, !bundleID.isEmpty else {
                rejected = true
                continue
            }
            history.exclude(bundleID: bundleID)
        }
        status = rejected ? "部分应用没有有效标识，未加入排除列表" : "已更新排除列表"
        refresh()
    }

    func removeExclusion(_ bundleID: String) {
        history.include(bundleID: bundleID)
        refresh()
    }

    func clearAll() {
        history.clear()
        refresh()
        status = "已清空本地剪贴板历史"
    }

    func toggleSensitiveFiltering() {
        history.skipSensitiveContent.toggle()
        status = history.skipSensitiveContent ? "已开启高置信密钥跳过" : "已关闭高置信密钥跳过"
    }

    func exportBackup() {
        guard let passphrase = validatedPassphrase() else { return }
        let panel = NSSavePanel()
        panel.title = L10n.text("导出加密剪贴板备份")
        panel.nameFieldStringValue = "AI-Lock-Clipboard.aiclip"
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        status = "正在生成加密备份…"
        showBackupSheet = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                let data = try ClipboardHistory.shared.makeEncryptedBackup(passphrase: passphrase)
                try data.write(to: url, options: [.atomic])
                // 备份包含全部剪贴板内容，权限收紧到仅所有者可读。
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            DispatchQueue.main.async {
                switch result {
                case .success: self?.status = "加密备份已导出"
                case .failure(let error): self?.status = "备份导出失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func importBackup() {
        guard let passphrase = validatedPassphrase() else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择加密剪贴板备份")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        showBackupSheet = false

        // 恢复会替换本机历史，先让用户明确确认。
        let confirm = NSAlert()
        confirm.messageText = L10n.text("替换当前剪贴板历史？")
        confirm.informativeText = L10n.text("导入会用备份中的记录替换本机当前历史。")
        confirm.addButton(withTitle: L10n.text("替换历史"))
        confirm.addButton(withTitle: L10n.text("取消"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let wasPaused = history.isPaused
        history.prepareForBackupRestore()
        history.setPaused(true)
        status = "正在解密并恢复备份…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                let data = try Data(contentsOf: url)
                try ClipboardHistory.shared.restoreEncryptedBackup(data, passphrase: passphrase)
            }
            DispatchQueue.main.async {
                self?.history.setPaused(wasPaused)
                switch result {
                case .success:
                    self?.status = "剪贴板历史已从备份恢复"
                    self?.refresh()
                case .failure(let error):
                    self?.status = "备份恢复失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func validatedPassphrase() -> String? {
        guard !passphrase.isEmpty else {
            status = "备份口令不能为空"
            return nil
        }
        if backupMode == .export, passphrase != passphraseConfirm {
            status = "两次输入的口令不一致"
            return nil
        }
        return passphrase
    }
}

// ============================================================================
// MARK: - 视图
// ============================================================================

struct LumenClipboardView: View {
    @ObservedObject private var localizationState = LumenLanguageState.shared
    @StateObject private var model: ClipboardPageModel

    init(history: ClipboardHistory = .shared) {
        _model = StateObject(wrappedValue: ClipboardPageModel(history: history))
    }

    private static let typeOptions: [(String, String)] = [
        ("全部类型", ""), ("文本", "text"), ("图片", "image"), ("文件", "file"), ("其他", "other")
    ]

    var body: some View {
        let _ = localizationState.revision
        ModulePage(
            module: .clipboard,
            subtitle: subtitle,
            trailing: { actions },
            footer: { footer },
            content: { content }
        )
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        // The page stays mounted when the sidebar switches away, so onDisappear never fires for it.
        .moduleActivity(module: .clipboard,
                        onResume: { model.start() },
                        onSuspend: { model.stop() })
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
        .alert(L10n.text("清空本地剪贴板历史？"), isPresented: $model.showClearConfirm) {
            Button(L10n.text("取消"), role: .cancel) {}
            Button(L10n.text("清空历史"), role: .destructive) { model.clearAll() }
        } message: {
            Text(L10n.text("删除本机保存的全部剪贴板记录与备注。此操作不可撤销，已导出的备份不会删除。"))
        }
        .sheet(item: $model.noteEditing) { record in
            noteSheet(record)
        }
        .sheet(isPresented: $model.showBackupSheet) {
            backupSheet
        }
    }

    private var subtitle: String {
        UnitFormat.joined([model.status, model.history.isPaused ? "采集已暂停" : "正在采集"])
    }

    @ViewBuilder
    private var actions: some View {
        Button(L10n.text("检查剪贴板访问")) { model.checkClipboardAccess() }
            .lumenButton(.secondary, icon: "lock.doc")
        Button(L10n.text(model.history.isPaused ? "继续采集" : "暂停采集")) {
            model.history.setPaused(!model.history.isPaused)
            model.refresh()
        }
        .lumenButton(.secondary, icon: model.history.isPaused ? "play" : "pause")

        Menu {
            Button(L10n.text("清空历史…")) { model.showClearConfirm = true }
                .disabled(model.history.records.isEmpty)
            Button(L10n.text("排除应用…")) { model.addExclusion() }
            Divider()
            Button(L10n.text("导出加密备份…")) {
                model.backupMode = .export
                model.passphrase = ""
                model.passphraseConfirm = ""
                model.showBackupSheet = true
            }
            Button(L10n.text("从备份恢复…")) {
                model.backupMode = .restore
                model.passphrase = ""
                model.passphraseConfirm = ""
                model.showBackupSheet = true
            }
            Divider()
            Button(L10n.text(model.history.skipSensitiveContent ? "关闭高置信密钥跳过" : "开启高置信密钥跳过")) {
                model.toggleSensitiveFiltering()
            }
            if !model.exclusionList.isEmpty {
                Divider()
                Menu(L10n.text("恢复采集的应用")) {
                    ForEach(model.exclusionList, id: \.self) { bundleID in
                        Button(model.displayName(bundleID)) { model.removeExclusion(bundleID) }
                    }
                }
            }
        } label: {
            Text(L10n.text("更多操作"))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .buttonStyle(LumenButtonStyle(kind: .secondary))
    }

    // ---------------------------------------------------------------- 内容

    private var content: some View {
        VStack(spacing: 0) {
            toolbar
            if let notice = model.clipboardAccessNotice {
                NoticeBar(level: model.history.pasteboardAccessDenied ? .caution : .info, text: notice)
                    .padding(.horizontal, Lumen.Metrics.pageInset)
            }
            if model.history.pasteboardAccessDenied && model.clipboardAccessNotice == nil {
                NoticeBar(level: .caution, text: "系统已拒绝剪贴板访问，请点击「检查剪贴板访问」前往设置。")
                    .padding(.horizontal, Lumen.Metrics.pageInset)
            }
            if model.records.isEmpty {
                EmptyState(symbol: "doc.on.clipboard",
                           title: emptyTitle,
                           detail: model.search.isEmpty && model.sourceFilter.isEmpty && model.typeFilter.isEmpty
                               ? "复制内容后会在这里出现。没有内容时，可点击「检查剪贴板访问」重试，并允许系统的剪贴板访问请求。"
                               : "调整搜索或筛选条件。")
                .frame(maxHeight: .infinity)
            } else {
                gallery
            }
        }
    }

    private var emptyTitle: String {
        model.history.isLoadingHistory ? "正在读取加密历史…" : "暂无剪贴板记录"
    }

    private var toolbar: some View {
        ModuleToolbar {
            SearchBox(placeholder: "搜索全部历史", text: Binding(
                get: { model.search },
                set: { newValue in
                    model.search = newValue
                    model.history.search(newValue)
                    model.refresh()
                }
            ), width: 230)

            Picker("", selection: Binding(
                get: { model.sourceFilter },
                set: { model.sourceFilter = $0; model.applyFilters() }
            )) {
                ForEach(Array(model.sourceOptions.enumerated()), id: \.offset) { index, option in
                    Text(L10n.text(option.0)).tag(option.1)
                }
            }
            .labelsHidden()
            .frame(width: 170)

            Picker("", selection: Binding(
                get: { model.typeFilter },
                set: { model.typeFilter = $0; model.applyFilters() }
            )) {
                ForEach(Array(Self.typeOptions.enumerated()), id: \.offset) { index, option in
                    Text(L10n.text(option.0)).tag(option.1)
                }
            }
            .labelsHidden()
            .frame(width: 120)

            Spacer(minLength: 8)

            Text(L10n.format("已加载 %{0} / %{1}",
                             arguments: [String(model.history.records.count), String(model.history.totalRecordCount)]))
                .font(Lumen.Typo.caption())
                .foregroundStyle(Lumen.Palette.textFaint)

            IconAction(symbol: "arrow.clockwise", help: "重新读取历史") {
                model.history.reloadHistory()
                model.refresh()
            }
        }
    }

    private var gallery: some View {
        ScrollView(.vertical, showsIndicators: true) {
            AdaptiveGrid(minimum: 268, spacing: 10) {
                ForEach(model.records) { record in
                    ClipboardCard(
                        record: record,
                        sourceName: model.displayName(record.sourceBundleID),
                        onCopy: { model.copy(record) },
                        onPin: { model.togglePin(record) },
                        onFavorite: { model.toggleFavorite(record) },
                        onNote: { model.beginNote(record) },
                        onDelete: { model.remove(record) },
                        onCopyPlain: { model.copyPlainText(record) },
                        onOpenLink: { model.openLink(record) },
                        onReveal: { model.revealFile(record) }
                    )
                    .onAppear {
                        if record.id == model.records.last?.id { model.loadMoreIfNeeded() }
                    }
                }
            }
            .padding(.horizontal, Lumen.Metrics.pageInset)
            .padding(.bottom, Lumen.Metrics.s5)
        }
        .scrollContentBackground(.hidden)
        .background(Lumen.Palette.canvas)
    }

    private var footer: some View {
        PageFooter(
            leading: model.status,
            tone: model.history.isPaused ? .caution : .active,
            trailing: [
                "\(model.records.count) 条",
                "保留 \(model.history.retentionDays) 天",
                model.history.isPaused ? "已暂停" : "采集中"
            ]
        )
    }

    // ---------------------------------------------------------------- 弹窗

    private func noteSheet(_ record: ClipboardRecord) -> some View {
        VStack(alignment: .leading, spacing: Lumen.Metrics.s4) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("剪贴板备注"))
                    .font(Lumen.Typo.title())
                Text(L10n.text(record.note == nil ? "为这条记录添加备注，便于以后检索。" : "修改或清空这条记录的备注。"))
                    .font(Lumen.Typo.caption())
                    .foregroundStyle(Lumen.Palette.textFaint)
            }
            TextEditor(text: $model.noteText)
                .font(Lumen.Typo.dense())
                .frame(height: 90)
                .padding(6)
                .lumenPanel(radius: 6)
            HStack {
                Spacer()
                Button(L10n.text("取消")) { model.noteEditing = nil }
                    .lumenButton(.secondary)
                Button(L10n.text("保存")) { model.saveNote() }
                    .lumenButton(.primary)
            }
        }
        .padding(Lumen.Metrics.s5)
        .frame(width: 420)
        .background(Lumen.Palette.raised)
    }

    private var backupSheet: some View {
        VStack(alignment: .leading, spacing: Lumen.Metrics.s4) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text(model.backupMode == .export ? "导出加密备份" : "从备份恢复"))
                    .font(Lumen.Typo.title())
                Text(L10n.text(model.backupMode == .export
                     ? "备份使用口令加密，请妥善保管；忘记口令无法恢复内容。"
                     : "恢复会用备份内容替换当前历史。请先确认已保存需要的记录。"))
                    .font(Lumen.Typo.caption())
                    .foregroundStyle(Lumen.Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Lumen.Metrics.s2) {
                SecureField(L10n.text("备份口令"), text: $model.passphrase)
                    .textFieldStyle(.roundedBorder)
                if model.backupMode == .export {
                    SecureField(L10n.text("再次输入口令"), text: $model.passphraseConfirm)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Spacer()
                Button(L10n.text("取消")) { model.showBackupSheet = false }
                    .lumenButton(.secondary)
                Button(L10n.text(model.backupMode == .export ? "选择保存位置…" : "选择备份文件…")) {
                    if model.backupMode == .export { model.exportBackup() } else { model.importBackup() }
                }
                .lumenButton(.primary)
            }
        }
        .padding(Lumen.Metrics.s5)
        .frame(width: 440)
        .background(Lumen.Palette.raised)
    }
}

// ============================================================================
// MARK: - 记录卡片
// ============================================================================

private struct ClipboardCard: View {
    let record: ClipboardRecord
    let sourceName: String
    let onCopy: () -> Void
    let onPin: () -> Void
    let onFavorite: () -> Void
    let onNote: () -> Void
    let onDelete: () -> Void
    let onCopyPlain: () -> Void
    let onOpenLink: () -> Void
    let onReveal: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Lumen.Palette.hairlineSoft)
            preview
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .lumenPanel()
        .overlay(
            RoundedRectangle(cornerRadius: Lumen.Metrics.rPanel, style: .continuous)
                .strokeBorder(hovering ? Lumen.Palette.active.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .shadow(color: .black.opacity(hovering ? 0.10 : 0.03), radius: hovering ? 8 : 2, y: hovering ? 3 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onCopy() }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("剪贴板记录") + " " + record.preview)
        .accessibilityHint(L10n.text("点击复制回系统剪贴板"))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: kindSymbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Lumen.Palette.textFaint)
            Text(sourceName)
                .font(.system(size: 10.5 * Lumen.scale, weight: .medium))
                .foregroundStyle(Lumen.Palette.textMuted)
                .lineLimit(1)
            Spacer(minLength: 4)
            if record.isPinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Lumen.Palette.caution)
            }
            if record.isFavorite {
                Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Lumen.Palette.caution)
            }
            MonoText(text: record.capturedAt.formatted(date: .omitted, time: .shortened),
                     size: 10, color: Lumen.Palette.textGhost)
            if hovering {
                IconAction(symbol: "xmark", help: "删除这条记录", tint: Lumen.Palette.textFaint, size: 10, action: onDelete)
                    .frame(width: 18, height: 18)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
    }

    @ViewBuilder
    private var preview: some View {
        if let image = previewImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 150)
                .background(Lumen.Palette.sunken)
                .clipped()
        } else if let text = record.plainText, !text.isEmpty {
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(Lumen.Typo.mono(11))
                .foregroundStyle(Lumen.Palette.text)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .frame(minHeight: 62, alignment: .topLeading)
        } else {
            Text(record.preview.isEmpty ? "（无预览）" : record.preview)
                .font(Lumen.Typo.dense())
                .foregroundStyle(Lumen.Palette.textFaint)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .frame(minHeight: 62, alignment: .topLeading)
        }

        if let note = record.note, !note.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "text.bubble").font(.system(size: 9))
                Text(note).font(Lumen.Typo.caption()).lineLimit(1)
            }
            .foregroundStyle(Lumen.Palette.textFaint)
            .padding(.horizontal, 11)
            .padding(.bottom, 8)
        }
    }

    private var previewImage: NSImage? {
        guard record.contentKind == "image",
              let data = record.values[NSPasteboard.PasteboardType.png.rawValue]
                  ?? record.values[NSPasteboard.PasteboardType.tiff.rawValue] else { return nil }
        return NSImage(data: data)
    }

    private var kindSymbol: String {
        switch record.contentKind {
        case "image": return "photo"
        case "file": return "doc"
        case "text": return "text.alignleft"
        default: return "square.on.square"
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button(L10n.text("复制到剪贴板")) { onCopy() }
        if record.plainText != nil { Button(L10n.text("复制纯文本")) { onCopyPlain() } }
        Divider()
        Button(L10n.text(record.isPinned ? "取消置顶" : "置顶")) { onPin() }
        Button(L10n.text(record.isFavorite ? "取消收藏" : "收藏")) { onFavorite() }
        Button(L10n.text(record.note == nil ? "添加备注…" : "编辑备注…")) { onNote() }
        Divider()
        if record.contentKind == "file" { Button(L10n.text("在 Finder 中显示")) { onReveal() } }
        if isLink { Button(L10n.text("打开链接")) { onOpenLink() } }
        Divider()
        Button(L10n.text("删除这条记录"), role: .destructive) { onDelete() }
    }

    private var isLink: Bool {
        guard let text = record.plainText?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text) else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}
