import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

// ============================================================================
//  设置
//  各设置项读写的 key、阈值校验、快捷键存储与热键重建方式保持不变。
// ============================================================================

struct LumenPreferencesView: View {
    @ObservedObject private var localizationState = LumenLanguageState.shared
    @ObservedObject private var language = LumenLanguageState.shared
    @AppStorage("preferences.selectedSection") private var storedSection = "通用"
    @AppStorage("overview.language") private var selectedEnglish = false
    @AppStorage("overview.followSystemLanguage") private var followSystemLanguage = true
    @AppStorage("appearance.mode") private var appearanceMode = "system"
    @AppStorage("overview.fontScale.v1") private var fontScale = 1.0
    @AppStorage("overview.statusMetrics") private var statusMetricsRaw = ""

    @State private var clipboardRetention = AppSettings.shared.clipboardRetentionDays

    @State private var hotkeyMessage: String?
    @State private var capturingQuickAction = false
    @State private var capturingRecorderShortcut = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginMessage: String?

    private static let sections = ["通用", "快捷键", "首页图标", "预警阈值", "系统扩展", "程序坞锁定", "菜单栏收纳", "关于"]

    /// 侧栏分组。设置项很多，按用途归类比一长条列表好扫。
    private static let groups: [(String, [String])] = [
        ("常规", ["通用", "快捷键", "首页图标"]),
        ("监控", ["预警阈值", "系统扩展"]),
        ("屏幕", ["程序坞锁定", "菜单栏收纳"]),
        ("系统", ["关于"])
    ]

    /// 旧版本写入的分节名到这里统一归一，避免升级后落到空白页。
    private static let legacyNames: [String: String] = [
        "通用设置": "通用",
        "监控预警": "预警阈值",
        "DockLock": "程序坞锁定",
        "帮助/关于": "关于"
    ]

    private var selection: String {
        get {
            let normalized = Self.legacyNames[storedSection] ?? storedSection
            return Self.sections.contains(normalized) ? normalized : "通用"
        }
        nonmutating set { storedSection = newValue }
    }

    var body: some View {
        let _ = localizationState.revision
        let _ = language.revision
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        sectionContent
                    }
                    .padding(.horizontal, Lumen.Metrics.s6)
                    .padding(.top, Lumen.Metrics.s5)
                    .padding(.bottom, Lumen.Metrics.s8)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollContentBackground(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Lumen.Palette.canvas)
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(Lumen.Palette.canvas)
        .preferredColorScheme(DashboardWindow.preferredColorScheme)
    }

    // ---------------------------------------------------------------- 侧栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Lumen.Metrics.s2) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Lumen.Palette.active)
                Text(L10n.text("设置"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Lumen.Palette.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: Lumen.Metrics.hToolbar + 2)
            .hairlineBottom()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(Self.groups.enumerated()), id: \.offset) { _, group in
                        MicroText(group.0)
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 6)
                        ForEach(group.1, id: \.self) { item in
                            sectionItem(item)
                        }
                    }
                }
                .padding(.bottom, Lumen.Metrics.s4)
            }
        }
        .frame(width: 186)
        .frame(maxHeight: .infinity)
        .background(Lumen.Palette.rail)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Lumen.Palette.hairline).frame(width: 1)
        }
    }

    private func sectionItem(_ item: String) -> some View {
        Button { selection = item } label: {
            Text(L10n.text(item))
                .font(.system(size: 12 * Lumen.scale, weight: selection == item ? .semibold : .regular))
                .foregroundStyle(selection == item ? Lumen.Palette.text : Lumen.Palette.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(selection == item ? Lumen.Palette.raised : .clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // ---------------------------------------------------------------- 内容

    @ViewBuilder
    private var sectionContent: some View {
        switch selection {
        case "快捷键": hotkeySection
        case "首页图标": homeIconsSection
        case "预警阈值": thresholdsSection
        case "系统扩展": ExtensionSettingsView()
        case "程序坞锁定": dockLockSection
        case "菜单栏收纳": LumenMenuBarOrganizerView()
        case "关于": aboutSection
        default: generalSection
        }
    }

    private func sectionTitle(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text(title))
                .font(.system(size: 16.5 * Lumen.scale, weight: .semibold))
            Text(L10n.text(detail))
                .font(Lumen.Typo.caption())
                .foregroundStyle(Lumen.Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, Lumen.Metrics.s3)
    }

    // ---------------------------------------------------------------- 通用

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("通用", "界面语言、外观与启动行为。改动立即生效，无需重启。")

            LumenPanel("外观", code: "APPEARANCE") {
                VStack(spacing: 0) {
                    SettingRow("主题", detail: "浅色为默认，深色为完整对等模式") {
                        Picker("", selection: Binding(
                            get: { appearanceMode },
                            set: { value in
                                appearanceMode = value
                                NotificationCenter.default.post(name: .appearanceModeChanged, object: nil)
                            }
                        )) {
                            Text(L10n.text("跟随系统")).tag("system")
                            Text(L10n.text("浅色")).tag("light")
                            Text(L10n.text("深色")).tag("dark")
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }

                    SettingRow("界面字号", detail: "影响当前窗口及后续打开页面的排版密度") {
                        HStack(spacing: Lumen.Metrics.s2) {
                            Slider(value: $fontScale, in: 0.8...1.4, step: 0.05)
                                .frame(width: 150)
                                .tint(Lumen.Palette.active)
                            MonoText(text: String(format: "%.0f%%", fontScale * 100), size: 12)
                                .frame(width: 46, alignment: .trailing)
                        }
                    }

                    SettingRow("界面语言", detail: "中文为源语言，英文为完整翻译") {
                        Picker("", selection: Binding(
                            get: { followSystemLanguage ? "system" : (selectedEnglish ? "en" : "zh") },
                            set: { value in
                                followSystemLanguage = value == "system"
                                if value != "system" { selectedEnglish = value == "en" }
                                NotificationCenter.default.post(name: L10n.changed, object: nil)
                            }
                        )) {
                            Text(L10n.text("跟随系统")).tag("system")
                            Text(L10n.text("简体中文")).tag("zh")
                            Text("English").tag("en")
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }

                    SettingRow("剪贴板历史保留", detail: "到期后自动清除本机加密记录") {
                        Picker("", selection: Binding(
                            get: { clipboardRetention },
                            set: { days in
                                clipboardRetention = days
                                ClipboardHistory.shared.retentionDays = days
                            }
                        )) {
                            ForEach([1, 3, 7, 14, 30], id: \.self) { days in
                                Text(L10n.format("保留 %{0} 天", arguments: [String(days)])).tag(days)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                }
            }

            LumenPanel("菜单栏指标", code: "STATUS") {
                HStack(spacing: Lumen.Metrics.s5) {
                    statusMetric("cpu", title: "CPU", symbol: "cpu")
                    statusMetric("memory", title: "内存", symbol: "memorychip")
                    statusMetric("disk", title: "硬盘", symbol: "internaldrive")
                    statusMetric("network", title: "网络", symbol: "network")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, Lumen.Metrics.s3)

            LumenPanel("开机启动", code: "STARTUP") {
                SettingRow("登录时启动", detail: "在后台运行，不显示窗口") {
                    LumenToggle(isOn: Binding(
                        get: { launchAtLogin },
                        set: { setLaunchAtLogin($0) }
                    ))
                }
            }
            .padding(.top, Lumen.Metrics.s3)

            if let loginMessage {
                NoticeBar(level: .caution, text: loginMessage)
                    .padding(.top, Lumen.Metrics.s2)
            }

            HStack {
                Spacer()
                Button(L10n.text("退出 AI Lock")) { NSApplication.shared.terminate(nil) }
                    .lumenButton(.danger, icon: "power")
            }
            .padding(.top, Lumen.Metrics.s4)
        }
        .onChange(of: fontScale) { _, value in
            Lumen.scale = CGFloat(value)
            LumenLanguageState.shared.refresh()
        }
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            Lumen.scale = CGFloat(fontScale)
        }
    }

    private func statusMetric(_ key: String, title: String, symbol: String) -> some View {
        let selected = statusMetricBinding(key).wrappedValue
        return Button {
            statusMetricBinding(key).wrappedValue.toggle()
        } label: {
            VStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: symbol)
                        .font(.system(size: 21))
                        .foregroundStyle(selected ? Lumen.Palette.activeInk : Lumen.Palette.textFaint)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Lumen.Palette.active)
                            .offset(x: 5, y: -4)
                    }
                }
                .frame(width: 34, height: 30)
                Text(L10n.text(title))
                    .font(Lumen.Typo.caption())
                    .foregroundStyle(selected ? Lumen.Palette.text : Lumen.Palette.textFaint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statusMetricBinding(_ key: String) -> Binding<Bool> {
        Binding(get: {
            let values = Set(statusMetricsRaw.split(separator: ",").map(String.init))
            return key == "network"
                ? values.contains("network") || values.contains("networkUpload") || values.contains("networkDownload")
                : values.contains(key)
        }, set: { enabled in
            var values = Set(statusMetricsRaw.split(separator: ",").map(String.init))
            if key == "network" {
                values.remove("networkUpload")
                values.remove("networkDownload")
                if enabled { values.insert("network") } else { values.remove("network") }
            } else if enabled {
                values.insert(key)
            } else {
                values.remove(key)
            }
            statusMetricsRaw = values.sorted().joined(separator: ",")
            NotificationCenter.default.post(name: .statusMetricsChanged, object: nil)
        })
    }

    /// 登录项注册可能失败（未签名、被策略阻止），失败时如实回报而不是假装成功。
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginMessage = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginMessage = L10n.format("启动项设置失败：%{0}", arguments: [String(error.localizedDescription)])
        }
    }

    // ---------------------------------------------------------------- 快捷键

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("快捷键", "配置快捷操作条与录屏的全局快捷键。若组合被其他程序占用，设置后会提示注册失败。")

            LumenPanel("全局快捷键", code: "HOTKEY") {
                VStack(spacing: 0) {
                    SettingRow("快捷操作条", detail: capturingQuickAction ? "请按下快捷键组合，Esc 取消" : DashboardWindow.quickActionShortcutTitle) {
                        HStack(spacing: Lumen.Metrics.s2) {
                            QuickActionShortcutRecorder(
                                title: capturingQuickAction ? L10n.text("正在录制…") : L10n.text("录制快捷键"),
                                isCapturing: capturingQuickAction,
                                recordingChanged: { capturingQuickAction = $0 },
                                onCapture: { keyCode, modifiers in
                                    DashboardWindow.saveQuickActionShortcut(keyCode: keyCode, modifiers: modifiers)
                                    capturingQuickAction = false
                                    hotkeyMessage = DashboardWindow.refreshGlobalHotkeys().joined(separator: "\n")
                                },
                                onCancel: { capturingQuickAction = false }
                            )
                            .frame(width: 128, height: 27)

                            Button(L10n.text("重置")) { DashboardWindow.resetQuickActionShortcut() }
                                .lumenButton(.secondary, compact: true)
                                .disabled(!DashboardWindow.hasCustomQuickActionShortcut)
                        }
                    }
                    SettingRow("录屏开始 / 停止", detail: capturingRecorderShortcut ? "请按下快捷键组合，Esc 取消" : DashboardWindow.screenRecorderShortcutTitle) {
                        HStack(spacing: Lumen.Metrics.s2) {
                            QuickActionShortcutRecorder(
                                title: capturingRecorderShortcut ? L10n.text("正在录制…") : L10n.text("录制快捷键"),
                                isCapturing: capturingRecorderShortcut,
                                recordingChanged: { capturingRecorderShortcut = $0 },
                                onCapture: { keyCode, modifiers in
                                    DashboardWindow.saveScreenRecorderShortcut(keyCode: keyCode, modifiers: modifiers)
                                    capturingRecorderShortcut = false
                                    hotkeyMessage = DashboardWindow.refreshGlobalHotkeys().joined(separator: "\n")
                                },
                                onCancel: { capturingRecorderShortcut = false }
                            )
                            .frame(width: 128, height: 27)

                            Button(L10n.text("重置")) {
                                DashboardWindow.resetScreenRecorderShortcut()
                                hotkeyMessage = L10n.text("已恢复默认快捷键。")
                            }
                            .lumenButton(.secondary, compact: true)
                        }
                    }
                }
            }

            NoticeBar(level: .info,
                      text: "部分全局快捷键需要「输入监控」权限。授权后需重新打开应用或重启快捷键注册。")
                .padding(.top, Lumen.Metrics.s3)

            if !DashboardWindow.hasInputMonitoringAccess {
                NoticeBar(level: .caution,
                          text: "双击 Command 与快捷键需要「输入监控」权限，才能在其它应用中生效。")
                    .padding(.top, Lumen.Metrics.s3)
                Button(L10n.text("打开输入监控设置")) {
                    DashboardWindow.requestInputMonitoringAccess()
                    hotkeyMessage = "已打开系统设置。请允许 AI Lock 的输入监控后，等待几秒或重新打开应用。"
                }
                .lumenButton(.primary, icon: "lock.open")
                .padding(.top, Lumen.Metrics.s2)
            } else if !DashboardWindow.globalShortcutsActive {
                NoticeBar(level: .caution,
                          text: "权限已授予，但全局监听尚未启动。请点击「重新注册全局快捷键」，或重新打开 AI Lock。")
                    .padding(.top, Lumen.Metrics.s3)
            }

            Button(L10n.text("重新注册全局快捷键")) {
                let errors = DashboardWindow.refreshGlobalHotkeys()
                hotkeyMessage = errors.isEmpty ? "全局快捷键已重新注册。" : errors.joined(separator: "；")
            }
            .lumenButton(.secondary, icon: "arrow.clockwise")
            .padding(.top, Lumen.Metrics.s3)

            if let hotkeyMessage {
                NoticeBar(level: hotkeyMessage.contains("失败") || hotkeyMessage.contains("占用") ? .caution : .info,
                          text: hotkeyMessage)
                    .padding(.top, Lumen.Metrics.s2)
            }
        }
    }

    // ---------------------------------------------------------------- 首页图标

    private var homeIconsSection: some View {
        HomeIconSettings()
    }

    // ---------------------------------------------------------------- 阈值

    private var thresholdsSection: some View {
        LumenAlertsThresholdsView()
    }

    // ---------------------------------------------------------------- DockLock

    private var dockLockSection: some View {
        LumenDockLockView()
    }

    // ---------------------------------------------------------------- 关于

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("关于", "AI Lock 的版本信息、数据位置与开源许可。")

            LumenPanel("版本", code: "VERSION") {
                VStack(alignment: .leading, spacing: 3) {
                    DetailPair(key: "名称", value: "AI Lock")
                    DetailPair(key: "版本", value: version, mono: true)
                    DetailPair(key: "系统", value: ProcessInfo.processInfo.operatingSystemVersionString)
                }
            }

            LumenPanel("数据位置", code: "STORAGE") {
                VStack(alignment: .leading, spacing: 3) {
                    DetailPair(key: "应用日志", value: "~/Library/Logs/AILock.log", mono: true)
                    DetailPair(key: "剪贴板历史", value: "~/Library/Application Support/AILock/", mono: true)
                    DetailPair(key: "Agent Hooks", value: "agent-hook-history.sqlite3", mono: true)
                }
            }
            .padding(.top, Lumen.Metrics.s3)

            NoticeBar(level: .info,
                      text: "剪贴板历史、文件活动与 Agent Hooks 数据均保存在本机。删除可在对应模块中操作。")
                .padding(.top, Lumen.Metrics.s3)

            HStack(spacing: Lumen.Metrics.s3) {
                Button(L10n.text("打开日志目录")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs"))
                }
                .lumenButton(.secondary, icon: "folder")

                Button(L10n.text("查看项目主页")) {
                    if let url = URL(string: "https://github.com/laoguzhe/AI-Lock") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .lumenButton(.secondary, icon: "link")
            }
            .padding(.top, Lumen.Metrics.s3)
        }
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(short) (\(build))"
    }
}

// ============================================================================
// MARK: - 预警阈值（设置页与「监控预警」模块共用）
// ============================================================================

struct LumenAlertsThresholdsView: View {
    @ObservedObject private var localizationState = LumenLanguageState.shared
    @State private var alerts = AppSettings.shared.alerts
    @State private var cameraMonitoringEnabled = UserDefaults.standard.bool(forKey: "alert.camera.enabled")
    @State private var microphoneMonitoringEnabled = UserDefaults.standard.bool(forKey: "alert.microphone.enabled")
    @State private var message: String?
    @State private var savedAlerts = AppSettings.shared.alerts
    @State private var isSaving = false
    @State private var savedCamera = UserDefaults.standard.bool(forKey: "alert.camera.enabled")
    @State private var savedMicrophone = UserDefaults.standard.bool(forKey: "alert.microphone.enabled")
    private var hasChanges: Bool { alerts != savedAlerts || cameraMonitoringEnabled != savedCamera || microphoneMonitoringEnabled != savedMicrophone }

    var body: some View {
        let _ = localizationState.revision
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
            LumenPanel("阈值", code: "ALERT") {
                VStack(spacing: 0) {
                    SettingRow("摄像头使用提醒", detail: "需要启用后，才会在 macOS 报告摄像头正在使用时提醒") {
                        LumenToggle(isOn: Binding(
                            get: { cameraMonitoringEnabled },
                            set: { cameraMonitoringEnabled = $0 }
                        ))
                    }
                    SettingRow("麦克风使用提醒", detail: "需要启用后，才会在 macOS 报告麦克风正在使用时提醒") {
                        LumenToggle(isOn: Binding(
                            get: { microphoneMonitoringEnabled },
                            set: { microphoneMonitoringEnabled = $0 }
                        ))
                    }
                    row("处理器占用", $alerts.cpu, unit: "%", range: 1...100)
                    row("内存占用", $alerts.memory, unit: "%", range: 1...100)
                    row("磁盘剩余空间", $alerts.diskFreePercent, unit: "%", range: 1...100)
                    row("网络速率", $alerts.networkMB, unit: "MB/s", range: 0.1...1_000)
                    row("电池电量", $alerts.batteryPercent, unit: "%", range: 1...100)
                    SettingRow("温度预警", detail: "达到所选温度状态时提醒") {
                        Picker(L10n.text("温度预警"), selection: $alerts.thermalLevel) {
                            Text(L10n.text("高温")).tag(2.0)
                            Text(L10n.text("严重过热")).tag(3.0)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 270)
                    }
                }
            }

            HStack(spacing: Lumen.Metrics.s3) {
                Button(L10n.text("保存阈值")) {
                    guard hasChanges, !isSaving else { return }
                    isSaving = true
                    let snapshot = alerts
                    let camera = cameraMonitoringEnabled
                    let microphone = microphoneMonitoringEnabled
                    Task { @MainActor in
                        await Task.yield()
                        let ok = AppSettings.shared.saveAlerts(snapshot)
                        if ok {
                            savedAlerts = snapshot; savedCamera = camera; savedMicrophone = microphone
                            UserDefaults.standard.set(camera, forKey: "alert.camera.enabled")
                            UserDefaults.standard.set(microphone, forKey: "alert.microphone.enabled")
                            NotificationCenter.default.post(name: .mediaMonitoringSettingsChanged, object: nil)
                        }
                        message = ok ? "阈值已保存，下次采样生效。" : "设置由更高版本写入，当前版本不会覆盖。"
                        isSaving = false
                    }
                }
                .lumenButton(hasChanges && !isSaving ? .primary : .secondary)
                .disabled(!hasChanges || isSaving)

                Button(L10n.text("测试提醒")) {
                    NotificationCenter.default.post(name: .resourceAlertPreview, object: nil)
                }
                .lumenButton(.secondary, icon: "bell")
            }
            .padding(.top, Lumen.Metrics.s3)

            if let message {
                NoticeBar(level: message.contains("更高版本") ? .caution : .info, text: message)
                    .padding(.top, Lumen.Metrics.s2)
            }

            NoticeBar(level: .info,
                      text: "电池仅在使用电池供电时参与判断。摄像头与麦克风监视默认关闭。")
                .padding(.top, Lumen.Metrics.s3)
            }
            .padding(.bottom, Lumen.Metrics.s3)
        }
        .scrollIndicators(.visible)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            alerts = AppSettings.shared.alerts; savedAlerts = alerts
            cameraMonitoringEnabled = UserDefaults.standard.bool(forKey: "alert.camera.enabled"); savedCamera = cameraMonitoringEnabled
            microphoneMonitoringEnabled = UserDefaults.standard.bool(forKey: "alert.microphone.enabled"); savedMicrophone = microphoneMonitoringEnabled
        }
    }

    private func row(_ title: String, _ value: Binding<Double>, unit: String, range: ClosedRange<Double>) -> some View {
        SettingRow(title) {
            HStack(spacing: Lumen.Metrics.s2) {
                Slider(value: value, in: range)
                    .frame(width: 150)
                    .tint(Lumen.Palette.active)
                NumberField(value: value, width: 58, unit: unit)
            }
        }
    }
}

// ============================================================================
// MARK: - 首页图标设置
// ============================================================================

private struct HomeIconSettings: View {
    @State private var visible: [String] = AppSettings.shared.visibleModuleIDs ?? ModuleCatalog.all.map(\.rawValue)
    @State private var order: [String] = {
        let stored = AppSettings.shared.orderedModuleIDs
        let known = Set(ModuleCatalog.all.map(\.rawValue))
        var result = stored.filter { known.contains($0) }
        for module in ModuleCatalog.all where !result.contains(module.rawValue) {
            result.append(module.rawValue)
        }
        return result
    }()

    private var byID: [String: DashboardWindow.Module] {
        Dictionary(uniqueKeysWithValues: ModuleCatalog.all.map { ($0.rawValue, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("首页图标"))
                    .font(.system(size: 16.5 * Lumen.scale, weight: .semibold))
                Text(L10n.text("选择总览弹窗中显示的模块，并调整它们的顺序。"))
                    .font(Lumen.Typo.caption())
                    .foregroundStyle(Lumen.Palette.textFaint)
            }
            .padding(.bottom, Lumen.Metrics.s3)

            LumenPanel("总览图标", code: "\(visible.count) / \(order.count)", padding: 0) {
                VStack(spacing: 0) {
                    ForEach(order, id: \.self) { id in
                        if let module = byID[id] {
                            HStack(spacing: Lumen.Metrics.s3) {
                                Image(systemName: "line.3.horizontal")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Lumen.Palette.textGhost)

                                Image(systemName: ModuleCatalog.symbol(module))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Lumen.Palette.textMuted)
                                    .frame(width: 18)

                                Text(L10n.text(module.displayTitle))
                                    .font(Lumen.Typo.dense())
                                    .foregroundStyle(Lumen.Palette.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                MonoText(text: ModuleCatalog.code(module), size: 9.5, color: Lumen.Palette.textGhost)

                                IconAction(symbol: "chevron.up", help: "上移") {
                                    move(id, by: -1)
                                }
                                .disabled(order.firstIndex(of: id) == 0)

                                IconAction(symbol: "chevron.down", help: "下移") {
                                    move(id, by: 1)
                                }
                                .disabled(order.firstIndex(of: id) == order.count - 1)

                                LumenToggle(isOn: Binding(
                                    get: { visible.contains(id) },
                                    set: { on in
                                        if on { visible.append(id) } else { visible.removeAll { $0 == id } }
                                        AppSettings.shared.visibleModuleIDs = visible.isEmpty ? [] : visible
                                    }
                                ))
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .hairlineBottom()
                        }
                    }
                }
            }

            HStack(spacing: Lumen.Metrics.s3) {
                Button(L10n.text("全部显示")) {
                    visible = order
                    AppSettings.shared.visibleModuleIDs = visible
                }
                .lumenButton(.secondary, compact: true)

                Button(L10n.text("恢复默认顺序")) {
                    order = ModuleCatalog.all.map(\.rawValue)
                    AppSettings.shared.orderedModuleIDs = order
                }
                .lumenButton(.secondary, compact: true)
            }
            .padding(.top, Lumen.Metrics.s3)

            NoticeBar(level: .info,
                      text: "也可以在总览弹窗中直接拖动图标排序，或点右上角进入编辑模式隐藏图标。")
                .padding(.top, Lumen.Metrics.s3)

            Button(L10n.text("完成")) {
                AppSettings.shared.visibleModuleIDs = visible.isEmpty ? [] : visible
                AppSettings.shared.orderedModuleIDs = order
            }
            .lumenButton(.primary)
            .padding(.top, Lumen.Metrics.s3)
        }
    }

    private func move(_ id: String, by delta: Int) {
        guard let index = order.firstIndex(of: id) else { return }
        let destination = index + delta
        guard order.indices.contains(destination) else { return }
        order.swapAt(index, destination)
        AppSettings.shared.orderedModuleIDs = order
    }
}
