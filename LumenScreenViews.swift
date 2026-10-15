import AppKit
import AVKit
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

// ============================================================================
//  屏幕录制 / 显示器控制 / 程序坞锁定 / 菜单栏收纳
//  录制配置项、DDC 写入、Dock 边缘参数、收纳开关的存取方式保持不变。
// ============================================================================

// ============================================================================
// MARK: - 录屏
// ============================================================================

struct LumenScreenRecorderView: View {
    @ObservedObject private var localizationState = LumenLanguageState.shared
    @StateObject private var model = ScreenRecorderModel.shared
    @State private var previewResult: ScreenRecordingResult?
    @State private var cleanupTargets: [ScreenRecordingResult] = []
    @State private var showCleanup = false
    @State private var cleanupError: String?
    @State private var showCleanupError = false
    @AppStorage("screenRecorder.quality") private var qualityRawValue = ScreenRecorderQuality.p1080.rawValue
    @AppStorage("screenRecorder.outputDirectory") private var outputDirectoryPath = FileManager.default
        .urls(for: .moviesDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
    @AppStorage("screenRecorder.shortcut.keyCode") private var shortcutKeyCode = 0
    @AppStorage("screenRecorder.shortcut.modifiers") private var shortcutModifiers = 0

    private var quality: ScreenRecorderQuality {
        ScreenRecorderQuality(rawValue: qualityRawValue) ?? .p1080
    }

    private var shortcutTitle: String {
        DashboardWindow.screenRecorderShortcutTitle
    }

    var body: some View {
        let _ = localizationState.revision
        ModulePage(
            module: .screenRecorder,
            subtitle: model.status,
            trailing: { actions },
            footer: { footer },
            content: { content }
        )
        .sheet(item: $previewResult) { result in
            RecordingPreview(result: result)
        }
        .confirmationDialog(L10n.text("清理录屏历史"), isPresented: $showCleanup, titleVisibility: .visible) {
            Button(L10n.text("仅清除历史记录")) { clearHistory(includingFiles: false) }
            Button(L10n.text("清除记录并将文件移到废纸篓"), role: .destructive) { clearHistory(includingFiles: true) }
            Button(L10n.text("取消"), role: .cancel) { cleanupTargets = [] }
        } message: {
            Text(cleanupTargets.count == 1
                 ? cleanupTargets[0].url.lastPathComponent
                 : L10n.format("将清理 %{0} 条录屏记录", arguments: [String(cleanupTargets.count)]))
        }
        .alert(L10n.text("部分录屏文件未能清理"), isPresented: $showCleanupError) {
            Button(L10n.text("好"), role: .cancel) {}
        } message: {
            Text(cleanupError ?? "")
        }
        .onAppear { model.identifySelectedDisplay() }
        // Pages stay mounted when the sidebar switches away, so re-entering the page is a resume, not an appear.
        .moduleActivity(module: .screenRecorder,
                        onResume: { Task { @MainActor in model.identifySelectedDisplay() } },
                        onSuspend: {})
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshDisplays() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in model.refreshDisplays() }
    }

    @ViewBuilder
    private var actions: some View {
        if model.isRecording {
            Button(L10n.text("停止录制")) { model.stopRecording() }
                .lumenButton(.danger, icon: "stop.fill")
                .disabled(model.isStopping)
        } else {
            Button(L10n.text("开始录制")) {
                model.startRecording(in: URL(fileURLWithPath: outputDirectoryPath), quality: quality)
            }
            .lumenButton(.primary, icon: "record.circle")
            .disabled(model.selectedDisplayID == nil || model.displays.isEmpty || model.isStarting)
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: Lumen.Metrics.s4) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: Lumen.Metrics.s3) {
                    LumenPanel("录制设置", code: "CAPTURE") {
                        VStack(spacing: 0) {
                            SettingRow("显示器", detail: model.displays.isEmpty ? "正在读取可录制的显示器…" : "选择要录制的屏幕") {
                                Picker("", selection: $model.selectedDisplayID) {
                                    ForEach(model.displays) { option in
                                        Text(option.title).tag(Optional(option.id))
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 200)
                                .disabled(model.isRecording || model.isStarting || model.displays.isEmpty)
                                .onChange(of: model.selectedDisplayID) { _, _ in model.identifySelectedDisplay() }
                            }

                            SettingRow("清晰度", detail: "支持 2K、4K 和原始分辨率，不超过屏幕实际像素") {
                                Picker("", selection: $qualityRawValue) {
                                    ForEach(ScreenRecorderQuality.allCases) { option in
                                        Text(option.title).tag(option.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 200)
                                .disabled(model.isRecording || model.isStarting)
                            }

                            SettingRow("保存位置", detail: outputDirectoryPath) {
                                Button(L10n.text("更改…")) { chooseOutputDirectory() }
                                    .lumenButton(.secondary, compact: true)
                                    .disabled(model.isRecording)
                            }

                            SettingRow("录制快捷键", detail: shortcutTitle) {
                                Button(L10n.text("在设置中修改…")) {
                                    DashboardWindow.openPreferences(section: "快捷键")
                                }
                                .lumenButton(.secondary, compact: true)
                            }

                            SettingRow("系统声音", detail: "录制时同步捕获系统音频") {
                                Pill("已启用", tone: .active)
                            }
                        }
                    }

                    if !model.history.isEmpty {
                        LumenPanel("录屏历史", code: "HISTORY", trailing: AnyView(
                            Button(L10n.text("清理历史")) {
                                cleanupTargets = model.history
                                showCleanup = true
                            }
                            .lumenButton(.secondary, compact: true)
                        )) {
                            VStack(alignment: .leading, spacing: Lumen.Metrics.s3) {
                                ForEach(model.history) { result in
                                    historyRow(result)
                                }
                            }
                        }
                    }

                    if !model.hasScreenPermission {
                        Button(L10n.text("检查录屏权限")) { model.requestScreenPermission() }
                            .lumenButton(.secondary, icon: "lock")
                        NoticeBar(level: .info, text: "首次录制需要授予「屏幕与系统录音」权限。输出为 MOV 文件，保存在上方目录。")
                    }
                }
                .padding(.bottom, Lumen.Metrics.s6)
            }
            .frame(width: 420)

            statusCard
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, Lumen.Metrics.pageInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func clearHistory(includingFiles: Bool) {
        let ids = Set(cleanupTargets.map(\.id))
        cleanupError = model.clearHistory(ids: ids, includingFiles: includingFiles)
        cleanupTargets = []
        showCleanupError = cleanupError != nil
    }

    private func historyRow(_ result: ScreenRecordingResult) -> some View {
        let available = result.succeeded && FileManager.default.fileExists(atPath: result.url.path)
        return HStack(alignment: .top, spacing: 12) {
            Button { previewResult = result } label: {
                RecordingHistoryThumbnail(result: result)
            }
            .buttonStyle(.plain)
            .disabled(!available)
            .accessibilityLabel(L10n.text("预览播放"))
            .help(L10n.text("预览播放"))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button { model.selectResult(result) } label: {
                        Text(result.url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    Button {
                        cleanupTargets = [result]
                        showCleanup = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Lumen.Palette.textMuted)
                    .accessibilityLabel(L10n.text("清除这条记录"))
                    .help(L10n.text("清除这条记录"))
                }
                Text(result.finishedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Lumen.Typo.caption())
                    .foregroundStyle(Lumen.Palette.textMuted)
                Text(result.url.deletingLastPathComponent().path)
                    .font(Lumen.Typo.caption())
                    .foregroundStyle(Lumen.Palette.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Button(L10n.text("预览播放")) { previewResult = result }
                        .lumenButton(.secondary, compact: true)
                        .disabled(!available)
                    Button(L10n.text("在 Finder 中显示")) {
                        NSWorkspace.shared.activateFileViewerSelecting([result.url])
                    }
                    .lumenButton(.secondary, compact: true)
                    .disabled(!available)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .hairlineBottom()
    }

    /// Right-hand panel that fills the page: live timer while recording, the saved file afterwards.
    @ViewBuilder
    private var statusCard: some View {
        if model.isRecording {
            recordingCard
        } else if let result = model.lastResult {
            resultCard(result)
        } else {
            idleCard
        }
    }

    private var idleCard: some View {
        EmptyState(
            symbol: "record.circle",
            title: "尚未录制",
            detail: "选择显示器与清晰度后开始录制，完成后会在这里显示结果。"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Lumen.Metrics.s5)
        .lumenPanel()
    }

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: Lumen.Metrics.s4) {
            HStack(spacing: Lumen.Metrics.s2) {
                Circle()
                    .fill(Lumen.Palette.danger)
                    .frame(width: 10, height: 10)
                Text(L10n.text(model.isStopping ? "正在保存录屏…" : "正在录制"))
                    .font(Lumen.Typo.heading())
                    .foregroundStyle(Lumen.Palette.dangerInk)
            }

            MonoText(text: elapsed, size: 40, weight: .light, color: Lumen.Palette.text)

            if let output = model.outputURL {
                Text(output.path)
                    .font(Lumen.Typo.caption())
                    .foregroundStyle(Lumen.Palette.textFaint)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)

            if let output = model.outputURL {
                Button(L10n.text("在 Finder 中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                }
                .lumenButton(.secondary, icon: "folder")
            }
        }
        .padding(Lumen.Metrics.s5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .lumenPanel()
    }

    private func resultCard(_ result: ScreenRecordingResult) -> some View {
        VStack(alignment: .leading, spacing: Lumen.Metrics.s4) {
            HStack(alignment: .center, spacing: Lumen.Metrics.s3) {
                Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(result.succeeded ? Lumen.Palette.active : Lumen.Palette.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text(result.succeeded ? "录制已保存" : "录制未能保存"))
                        .font(Lumen.Typo.title())
                        .foregroundStyle(Lumen.Palette.text)
                    Text(result.url.lastPathComponent)
                        .font(Lumen.Typo.dense())
                        .foregroundStyle(Lumen.Palette.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            VStack(spacing: 0) {
                resultRow("时长", value: formatDuration(result.duration))
                resultRow("清晰度", value: result.qualityTitle)
                resultRow("文件大小", value: UnitFormat.bytes(UInt64(max(0, result.fileSize))))
                resultRow("保存位置", value: result.url.deletingLastPathComponent().path)
                    .textSelection(.enabled)
            }

            if !result.succeeded {
                NoticeBar(level: .danger, text: result.message)
            }

            Spacer(minLength: 0)

            HStack(spacing: Lumen.Metrics.s2) {
                Button(L10n.text("预览播放")) { previewResult = result }
                    .lumenButton(.primary, icon: "play.fill")
                    .disabled(!result.succeeded || !FileManager.default.fileExists(atPath: result.url.path))
                Button(L10n.text("在 Finder 中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([result.url])
                }
                .lumenButton(.secondary, icon: "folder")
            }
        }
        .padding(Lumen.Metrics.s5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .lumenPanel()
    }

    private func resultRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Lumen.Metrics.s4) {
            Text(L10n.text(title))
                .font(Lumen.Typo.dense())
                .foregroundStyle(Lumen.Palette.textFaint)
            Spacer(minLength: Lumen.Metrics.s4)
            Text(value)
                .font(Lumen.Typo.dense())
                .foregroundStyle(Lumen.Palette.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .hairlineBottom()
    }


    private var elapsed: String {
        formatDuration(model.elapsedSeconds)
    }

    private func formatDuration(_ seconds: Int) -> String {
        String(format: "%02d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
    }

    private var footer: some View {
        PageFooter(
            leading: model.status,
            tone: model.isRecording ? .danger : .active,
            trailing: model.isRecording
                ? [elapsed, quality.title, URL(fileURLWithPath: outputDirectoryPath).lastPathComponent]
                : [quality.title, URL(fileURLWithPath: outputDirectoryPath).lastPathComponent]
        )
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: outputDirectoryPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputDirectoryPath = url.path
    }
}

private struct RecordingHistoryThumbnail: View {
    let result: ScreenRecordingResult
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.08)
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: result.succeeded ? "film" : "exclamationmark.triangle")
                    .font(.system(size: 22))
                    .foregroundStyle(Lumen.Palette.textFaint)
            }
            if thumbnail != nil {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.55), radius: 3)
            }
        }
        .frame(width: 104, height: 68)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: result.url) {
            guard result.succeeded else { return }
            thumbnail = await RecordingThumbnail.firstFrame(at: result.url)
        }
    }
}

/// Use AppKit's player directly, avoiding the system SwiftUI VideoPlayer bridge.
private struct RecordingPlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

private struct RecordingPreview: View {
    let result: ScreenRecordingResult
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(result.url.lastPathComponent).font(.headline)
                Spacer()
                Button(L10n.text("关闭")) { dismiss() }
            }
            RecordingPlayerView(player: player)
                .frame(minWidth: 720, minHeight: 405)
            Text(result.url.path)
                .font(.caption)
                .textSelection(.enabled)
            Button(L10n.text("在 Finder 中显示")) {
                NSWorkspace.shared.activateFileViewerSelecting([result.url])
            }
        }
        .padding(20)
        .onAppear {
            player = AVPlayer(url: result.url)
            player?.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

// ============================================================================
// MARK: - 显示器亮度
// ============================================================================

struct LumenDisplayBrightnessView: View {
    @ObservedObject private var localizationState = LumenLanguageState.shared
    @State private var brightness = 70.0
    @State private var volume = 50.0
    @State private var displays: [ExternalDisplayDDC.DisplayTarget] = []
    @State private var selected = Set<CGDirectDisplayID>()
    @State private var status = ""
    @State private var applying = false

    var body: some View {
        let _ = localizationState.revision
        ModulePage(module: .displayBrightness,
                   subtitle: status.isEmpty ? "选择外接显示器后调整亮度或音量。" : status,
                   trailing: {
                       Button(L10n.text("重新检测")) { rescan() }
                           .lumenButton(.secondary, icon: "arrow.clockwise").disabled(applying)
                   },
                   footer: {
                       PageFooter(leading: status, tone: .active,
                                  trailing: [L10n.format("已选择 %{0} / %{1} 块显示器", arguments: [String(selected.count), String(displays.count)])])
                   },
                   content: {
                       ModuleForm(maxWidth: 620) {
                           VStack(alignment: .leading, spacing: Lumen.Metrics.s3) {
                               LumenPanel("显示器", code: "DISPLAY") {
                                   VStack(alignment: .leading, spacing: 10) {
                                       Toggle(L10n.text("全选"), isOn: Binding(
                                           get: { !displays.isEmpty && selected == Set(displays.map(\.id)) },
                                           set: { selected = $0 ? Set(displays.map(\.id)) : [] }
                                       )).toggleStyle(.checkbox).disabled(applying || displays.isEmpty)
                                       ForEach(displays) { display in
                                           Toggle(isOn: Binding(
                                               get: { selected.contains(display.id) },
                                               set: { enabled in
                                                   if enabled { selected.insert(display.id); DisplaySelectionIndicator.flash(display.id) }
                                                   else { selected.remove(display.id) }
                                               }
                                           )) {
                                               Label(display.name + " · " + String(display.id), systemImage: "display")
                                           }.toggleStyle(.checkbox).disabled(applying)
                                       }
                                       if displays.isEmpty { Text(L10n.text("未发现外接显示器。")) }
                                   }
                               }
                               LumenPanel("亮度", code: "DDC / 10") {
                                   control($brightness, symbol: "sun.max.fill", code: 0x10)
                               }
                               LumenPanel("显示器音量", code: "DDC / 62") {
                                   control($volume, symbol: "speaker.wave.2.fill", code: 0x62)
                               }
                               NoticeBar(level: .info, text: "松开滑块后只控制所选显示器。显示器需支持并启用 DDC/CI；音量需要显示器支持扬声器音量命令。无法确认控制通道时会报告失败。")
                           }
                       }
                   })
        .onAppear { rescan() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in rescan() }
    }

    private func control(_ value: Binding<Double>, symbol: String, code: UInt8) -> some View {
        HStack(spacing: Lumen.Metrics.s3) {
            Image(systemName: symbol).foregroundStyle(Lumen.Palette.textMuted)
            Slider(value: value, in: 0...100, step: 1) { editing in
                if !editing { apply(code, percent: Int(value.wrappedValue)) }
            }.tint(Lumen.Palette.active).disabled(selected.isEmpty || applying)
            MonoText(text: "\(Int(value.wrappedValue))%", size: 13).frame(width: 52, alignment: .trailing)
        }
    }

    private func rescan() {
        let previous = displays
        displays = ExternalDisplayDDC.connectedDisplays().filter { !$0.builtIn }
        selected.formIntersection(Set(displays.map(\.id)))
        if previous.isEmpty && selected.isEmpty, let first = displays.first { selected.insert(first.id) }
        status = displays.isEmpty ? "未发现外接显示器。" : "请选择要控制的显示器。"
    }

    private func apply(_ code: UInt8, percent: Int) {
        guard !selected.isEmpty, !applying else { return }
        let targets = selected
        applying = true
        status = "正在发送显示器控制命令…"
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                ExternalDisplayDDC.setControl(code, percent: percent, displayIDs: targets)
            }.value
            applying = false
            guard let result else { status = "当前设备不支持 DDC 控制。"; return }
            status = "已向 \(result.sent) 块显示器发送命令，\(result.failed) 块失败。"
            if result.failed > 0 { status += "请检查 DDC/CI、连接方式及显示器支持情况。" }
        }
    }
}

// ============================================================================
// MARK: - 程序坞锁定
// ============================================================================

struct LumenDockLockView: View {
    @ObservedObject private var localizationState = LumenLanguageState.shared
    @State private var enabled = DashboardWindow.dockLockEnabled
    @State private var target = DashboardWindow.dockLockTargetSetting
    @State private var edgeMargin = AppSettings.shared.edgeMargin
    @State private var autoSnap = AppSettings.shared.autoSnap
    @State private var screens: [DockLock.ScreenChoice] = DashboardWindow.dockLockScreens
    @State private var coveredDisplays = DashboardWindow.coveredDisplays
    @State private var accessibilityTrusted = AXIsProcessTrusted()

    var body: some View {
        let _ = localizationState.revision
        ModulePage(
            module: .dockLock,
            subtitle: enabled ? "正在把程序坞锁定到目标显示器。" : "程序坞锁定已关闭。",
            trailing: {
                Button(L10n.text(enabled ? "关闭锁定" : "开启锁定")) {
                    enabled = DashboardWindow.toggleDockLock()
                    screens = DashboardWindow.dockLockScreens
                }
                .lumenButton(enabled ? .secondary : .primary, icon: enabled ? "stop.fill" : "play.fill")
            },
            footer: {
                PageFooter(
                    leading: enabled ? "锁定已开启" : "锁定已关闭",
                    tone: enabled ? .active : .neutral,
                    trailing: [accessibilityTrusted ? "辅助功能已授权" : "需要辅助功能权限",
                               "边缘余量 \(Int(edgeMargin)) pt"]
                )
            },
            content: {
                ModuleForm(maxWidth: 640) {
                    VStack(alignment: .leading, spacing: Lumen.Metrics.s3) {
                        if !accessibilityTrusted {
                            NoticeBar(level: .caution,
                                      text: "程序坞锁定需要辅助功能权限。系统设置中授权后需要重新开启锁定。",
                                      symbol: "lock.shield")
                        }

                        LumenPanel("目标显示器", code: "TARGET") {
                            VStack(spacing: 0) {
                                SettingRow("锁定到", detail: "真实鼠标移动会取消正在进行的回弹") {
                                    Picker("", selection: Binding(
                                        get: { target },
                                        set: { value in
                                            target = value
                                            DashboardWindow.setDockLockTarget(value)
                                        }
                                    )) {
                                        Text(L10n.text("自动（主屏优先）")).tag("builtin")
                                        ForEach(screens, id: \.id) { screen in
                                            Text(L10n.text(screen.name)).tag(String(screen.id))
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 220)
                                }
                            }
                        }

                        LumenPanel("行为", code: "BEHAVIOR") {
                            VStack(spacing: 0) {
                                SettingRow("边缘余量", detail: "指针需要越过的边缘距离，数值越大越不易误触") {
                                    HStack(spacing: Lumen.Metrics.s2) {
                                        Slider(value: $edgeMargin, in: 1...100) { editing in
                                            if !editing { AppSettings.shared.edgeMargin = edgeMargin }
                                        }
                                        .frame(width: 150)
                                        .tint(Lumen.Palette.active)
                                        MonoText(text: "\(Int(edgeMargin))", size: 12)
                                            .frame(width: 30, alignment: .trailing)
                                    }
                                }
                                SettingRow("空闲时拉回程序坞", detail: "空闲后把指针带回目标屏幕") {
                                    LumenToggle(isOn: Binding(
                                        get: { autoSnap },
                                        set: { value in
                                            autoSnap = value
                                            AppSettings.shared.autoSnap = value
                                        }
                                    ))
                                }
                            }
                        }

                        LumenPanel("隐私遮罩", code: "DISPLAY PRIVACY") {
                            VStack(alignment: .leading, spacing: Lumen.Metrics.s3) {
                                Text(L10n.text("点选显示器预览即可切换黑色遮罩。至少保留一块屏幕可见；遮罩不阻止系统或其他应用读取屏幕内容。"))
                                    .font(Lumen.Typo.caption())
                                    .foregroundStyle(Lumen.Palette.textFaint)
                                    .fixedSize(horizontal: false, vertical: true)

                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Lumen.Metrics.s2)], spacing: Lumen.Metrics.s2) {
                                    ForEach(screens, id: \.id) { screen in
                                        DisplayPrivacyTile(
                                            screen: screen,
                                            covered: coveredDisplays.contains(screen.id),
                                            onTap: {
                                                DashboardWindow.toggleDisplayPrivacy(screen.id)
                                                coveredDisplays = DashboardWindow.coveredDisplays
                                            }
                                        )
                                    }
                                }

                                if screens.count <= 1 {
                                    NoticeBar(level: .info, text: "连接第二块显示器后，可在另一块屏幕保持工作内容可见。")
                                }

                                HStack {
                                    Button(L10n.text("解除全部遮罩")) {
                                        DashboardWindow.clearDisplayPrivacy()
                                        coveredDisplays = DashboardWindow.coveredDisplays
                                    }
                                    .lumenButton(.secondary, icon: "eye")
                                    .disabled(coveredDisplays.isEmpty)
                                    Spacer()
                                    Text(L10n.format("已遮罩 %{0} / %{1} 块", arguments: [String(coveredDisplays.count), String(screens.count)]))
                                        .font(Lumen.Typo.caption())
                                        .foregroundStyle(Lumen.Palette.textFaint)
                                }
                            }
                        }

                        Button(L10n.text("打开辅助功能设置")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .lumenButton(.secondary, icon: "gearshape")
                    }
                }
            }
        )
        .onAppear {
            accessibilityTrusted = AXIsProcessTrusted()
            screens = DashboardWindow.dockLockScreens
            coveredDisplays = DashboardWindow.coveredDisplays
        }
        .moduleActivity(module: .dockLock,
                        onResume: {
                            accessibilityTrusted = AXIsProcessTrusted()
                            screens = DashboardWindow.dockLockScreens
                            coveredDisplays = DashboardWindow.coveredDisplays
                        },
                        onSuspend: {})
        .onReceive(NotificationCenter.default.publisher(for: .displayPrivacyChanged)) { _ in
            coveredDisplays = DashboardWindow.coveredDisplays
            screens = DashboardWindow.dockLockScreens
        }
    }
}

private struct DisplayPrivacyTile: View {
    let screen: DockLock.ScreenChoice
    let covered: Bool
    let onTap: () -> Void

    private var wallpaper: NSImage? {
        guard let target = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == screen.id
        }), let url = NSWorkspace.shared.desktopImageURL(for: target) else { return nil }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    if let wallpaper {
                        Image(nsImage: wallpaper)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Lumen.Palette.sunken
                    }
                    if covered {
                        Color.black
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    VStack {
                        HStack {
                            Text(screen.isBuiltin ? L10n.text("内置屏幕") : L10n.text("外接屏幕"))
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.45), in: Capsule())
                            Spacer()
                        }
                        Spacer()
                        HStack {
                            Text(screen.size)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.white)
                            Spacer()
                        }
                    }
                    .padding(7)
                }
                .frame(height: 84)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                HStack(spacing: 5) {
                    StatusDot(tone: covered ? .danger : .active, size: 5)
                    Text(L10n.text(screen.name))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Lumen.Palette.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(L10n.text(covered ? "已遮罩" : "可见"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(covered ? Lumen.Palette.dangerInk : Lumen.Palette.textFaint)
                }
            }
            .padding(7)
            .background(Lumen.Palette.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(covered ? Lumen.Palette.danger.opacity(0.35) : Lumen.Palette.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(L10n.text(covered ? "点击解除显示器遮罩" : "点击测试显示器遮罩"))
    }
}

// ============================================================================
// MARK: - 菜单栏收纳
// ============================================================================

struct LumenMenuBarOrganizerView: View {
    @ObservedObject private var localizationState = LumenLanguageState.shared
    @ObservedObject private var organizer = MenuBarOrganizer.shared
    @AppStorage(MenuBarOrganizer.autoHideKey) private var autoHide = true

    var body: some View {
        let _ = localizationState.revision
        ModulePage(
            module: .menuBarOrganizer,
            subtitle: organizer.enabled ? "不常用的菜单栏图标已折叠到箭头左侧。" : "菜单栏收纳已关闭。",
            trailing: {
                Button(L10n.text(organizer.enabled ? "关闭收纳" : "开启收纳")) {
                    organizer.toggleEnabled()
                }
                .lumenButton(organizer.enabled ? .secondary : .primary, icon: organizer.enabled ? "stop.fill" : "play.fill")
            },
            footer: {
                PageFooter(
                    leading: organizer.enabled ? "收纳已开启" : "收纳已关闭",
                    tone: organizer.enabled ? .active : .neutral,
                    trailing: ["展开后 15 秒自动收起"]
                )
            },
            content: {
                ModuleForm(maxWidth: 640) {
                    VStack(alignment: .leading, spacing: Lumen.Metrics.s3) {
                        LumenPanel("收纳行为", code: "ORGANIZER") {
                    VStack(spacing: 0) {
                        SettingRow("展开后自动收起", detail: "定时收起已展开的菜单栏图标") {
                            LumenToggle(isOn: Binding(
                                get: { autoHide },
                                set: { value in
                                    autoHide = value
                                    NotificationCenter.default.post(name: MenuBarOrganizer.settingsChanged, object: nil)
                                }
                            ))
                        }
                        SettingRow("立即展开并排列", detail: "临时展开全部图标，方便拖动排序") {
                                    Button(L10n.text("展开")) { organizer.expandForArrangement() }
                                        .lumenButton(.secondary, compact: true)
                                        .disabled(!organizer.enabled)
                                }
                            }
                        }

                        if let message = organizer.message {
                            NoticeBar(level: .info, text: message)
                        }

                        NoticeBar(level: .info,
                                  text: "收纳通过移动一个不可见的占位项实现。系统更新可能影响图标位置，重新开启收纳即可恢复。")
                    }
                }
            }
        )
    }
}
