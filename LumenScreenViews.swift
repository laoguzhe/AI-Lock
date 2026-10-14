import AppKit
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
    @StateObject private var model = ScreenRecorderModel()
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
        ModulePage(
            module: .screenRecorder,
            subtitle: model.status,
            trailing: { actions },
            footer: { footer },
            content: { content }
        )
    }

    @ViewBuilder
    private var actions: some View {
        if model.isRecording {
            Button(L10n.text("停止录制")) { model.stopRecording() }
                .lumenButton(.danger, icon: "stop.fill")
        } else {
            Button(L10n.text("开始录制")) {
                model.startRecording(in: URL(fileURLWithPath: outputDirectoryPath), quality: quality)
            }
            .lumenButton(.primary, icon: "record.circle")
            .disabled(model.selectedDisplayID == nil || model.displays.isEmpty)
        }
    }

    private var content: some View {
        ModuleForm(maxWidth: 620) {
            VStack(alignment: .leading, spacing: Lumen.Metrics.s3) {
                recordingStatus

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
                            .disabled(model.isRecording || model.displays.isEmpty)
                        }

                        SettingRow("清晰度", detail: "分辨率越高，文件越大") {
                            Picker("", selection: $qualityRawValue) {
                                ForEach(ScreenRecorderQuality.allCases) { option in
                                    Text(option.title).tag(option.rawValue)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 200)
                            .disabled(model.isRecording)
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

                if model.outputURL == nil {
                    NoticeBar(level: .info, text: "首次录制需要授予「屏幕与系统录音」权限。输出为 MOV 文件，保存在上方目录。")
                }
            }
        }
    }

    private var recordingStatus: some View {
        HStack(spacing: Lumen.Metrics.s4) {
            ZStack {
                Circle()
                    .fill(model.isRecording ? Lumen.Palette.dangerWash : Lumen.Palette.fill)
                    .frame(width: 46, height: 46)
                Circle()
                    .fill(model.isRecording ? Lumen.Palette.danger : Lumen.Palette.textGhost)
                    .frame(width: model.isRecording ? 15 : 12, height: model.isRecording ? 15 : 12)
            }

            VStack(alignment: .leading, spacing: 3) {
                if model.isRecording {
                    Text(L10n.text("正在录制"))
                        .font(Lumen.Typo.heading())
                        .foregroundStyle(Lumen.Palette.dangerInk)
                    MonoText(text: elapsed, size: 20, weight: .light, color: Lumen.Palette.text)
                } else {
                    Text(L10n.text("未在录制"))
                        .font(Lumen.Typo.heading())
                        .foregroundStyle(Lumen.Palette.textMuted)
                    Text(L10n.text("选择显示器与清晰度后开始录制。"))
                        .font(Lumen.Typo.caption())
                        .foregroundStyle(Lumen.Palette.textFaint)
                }
            }

            Spacer(minLength: 0)

            if let output = model.outputURL {
                Button(L10n.text("在 Finder 中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                }
                .lumenButton(.secondary, compact: true)
            }
        }
        .padding(Lumen.Metrics.s4)
        .lumenPanel()
    }

    private var elapsed: String {
        let seconds = model.elapsedSeconds
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
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

// ============================================================================
// MARK: - 显示器亮度
// ============================================================================

struct LumenDisplayBrightnessView: View {
    @State private var value: Double = 0.7
    @State private var channelCount = 0
    @State private var status = ""
    @State private var applied: String?

    var body: some View {
        ModulePage(
            module: .displayBrightness,
            subtitle: status.isEmpty ? "向支持 DDC 的外接显示器发送统一亮度值。" : status,
            trailing: {
                Button(L10n.text("重新检测")) { rescan() }
                    .lumenButton(.secondary, icon: "arrow.clockwise")
            },
            footer: {
                PageFooter(
                    leading: channelCount > 0 ? L10n.format("已发现 %{0} 个可控通道", arguments: [String(channelCount)])
                                             : "未发现支持 DDC 的外接显示器",
                    tone: channelCount > 0 ? .active : .caution,
                    trailing: applied.map { ["上次写入 \($0)"] } ?? []
                )
            },
            content: {
                ModuleForm(maxWidth: 620) {
                    VStack(alignment: .leading, spacing: Lumen.Metrics.s3) {
                        LumenPanel("亮度", code: "DDC") {
                            VStack(alignment: .leading, spacing: Lumen.Metrics.s3) {
                                HStack(spacing: Lumen.Metrics.s3) {
                                    Image(systemName: "sun.min")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Lumen.Palette.textFaint)
                                    Slider(value: $value, in: 0...1) { editing in
                                        if !editing { apply() }
                                    }
                                    .tint(Lumen.Palette.active)
                                    Image(systemName: "sun.max.fill")
                                        .font(.system(size: 15))
                                        .foregroundStyle(Lumen.Palette.textMuted)
                                    MonoText(text: String(format: "%.0f%%", value * 100), size: 13)
                                        .frame(width: 52, alignment: .trailing)
                                }

                                Text(L10n.text("拖动后松开即写入。该功能只发送亮度值，不读取显示器当前亮度。"))
                                    .font(Lumen.Typo.caption())
                                    .foregroundStyle(Lumen.Palette.textFaint)
                            }
                        }

                        NoticeBar(level: .info,
                                  text: "支持范围取决于显示器与连接方式。Intel Mac、部分 HDMI 与扩展坞组合不支持 DDC 控制。")
                    }
                }
            }
        )
        .onAppear { rescan() }
    }

    private func rescan() {
        guard let count = ExternalDisplayDDC.availableChannelCount() else {
            channelCount = 0
            status = "当前设备不支持 DDC 亮度控制。"
            return
        }
        channelCount = count
        status = count > 0
            ? L10n.format("已发现 %{0} 个可控通道", arguments: [String(count)])
            : "未发现支持 DDC 的外接显示器。"
    }

    private func apply() {
        let percent = Int((value * 100).rounded())
        applied = "\(percent)%"
        guard let result = ExternalDisplayDDC.setBrightness(percent) else {
            status = "当前设备不支持 DDC 亮度控制。"
            return
        }
        if result.sent > 0, result.failed == 0 {
            status = L10n.format("已向 %{0} 个通道写入亮度。", arguments: [String(result.sent)])
        } else if result.sent > 0 {
            status = L10n.format("已写入 %{0} 个通道，%{1} 个失败。",
                                 arguments: [String(result.sent), String(result.failed)])
        } else if result.failed > 0 {
            status = L10n.format("%{0} 个通道写入失败；显示器可能未启用 DDC/CI。", arguments: [String(result.failed)])
        } else {
            status = "未发现可写入的外接显示器。"
        }
    }
}

// ============================================================================
// MARK: - 程序坞锁定
// ============================================================================

struct LumenDockLockView: View {
    @State private var enabled = DashboardWindow.dockLockEnabled
    @State private var target = DashboardWindow.dockLockTargetSetting
    @State private var edgeMargin = AppSettings.shared.edgeMargin
    @State private var autoSnap = AppSettings.shared.autoSnap
    @State private var screens: [DockLock.ScreenChoice] = DashboardWindow.dockLockScreens
    @State private var coveredDisplays = DashboardWindow.coveredDisplays
    @State private var accessibilityTrusted = AXIsProcessTrusted()

    var body: some View {
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
    @ObservedObject private var organizer = MenuBarOrganizer.shared
    @AppStorage(MenuBarOrganizer.autoHideKey) private var autoHide = true

    var body: some View {
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
