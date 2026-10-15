import AppKit
import SwiftUI
import Charts

@MainActor
final class NetworkDiagnosticsModel: ObservableObject {
    @Published var interfaces: [NetworkDiagnosticInterface] = NetworkDiagnosticService.interfaces()
    @Published var results: [NetworkDiagnosticResult] = []
    @Published var resultKinds: [UUID: NetworkDiagnosticKind] = [:]
    @Published var liveSpeed: NetworkDiagnosticSpeedSample?
    @Published var speedHistory: [NetworkDiagnosticResult] = []
    @Published var jobCompleted = 0
    @Published var jobTotal = 0
    @Published var activeKind: NetworkDiagnosticKind?
    @Published var running = false
    @Published var phase = "点击开始诊断"
    @Published private(set) var startedAt: Date?
    private var runID = UUID()
    private var task: Task<Void, Never>?
    func refreshInterfaces() { interfaces = NetworkDiagnosticService.interfaces() }
    func start(_ plans: [NetworkDiagnosticPlan]) {
        guard !running else { return }
        guard !plans.isEmpty else { phase = "没有可执行的诊断项目，请检查诊断参数。"; return }
        runID = UUID()
        let request = runID
        startedAt = Date()
        running = true; phase = "测试中…"; jobCompleted = 0
        jobTotal = plans.reduce(0) { $0 + $1.expectedResultCount }
        results.removeAll(); resultKinds.removeAll(); liveSpeed = nil
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                for plan in plans {
                    try Task.checkCancellation()
                    await self?.setActive(plan.kind, request: request)
                    do {
                        try await NetworkDiagnosticService.run(plan, liveSpeed: { [weak self] sample in
                            await self?.updateLiveSpeed(sample, request: request)
                        }) { [weak self] result in
                            await self?.append(result, kind: plan.kind, request: request)
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        await self?.append(.init(plan.kind.title, passed: false, summary: error.localizedDescription), kind: plan.kind, request: request)
                    }
                }
                await self?.finish("测试完成", request: request)
            } catch is CancellationError { await self?.finish("测试已取消，已完成的结果保留", request: request) }
            catch { await self?.finish(error.localizedDescription, request: request) }
        }
    }
    private func updateLiveSpeed(_ sample: NetworkDiagnosticSpeedSample, request: UUID) {
        guard request == runID else { return }
        liveSpeed = sample
        phase = "实时测速" + " · " + sample.line
    }
    private func setActive(_ kind: NetworkDiagnosticKind, request: UUID) {
        guard request == runID else { return }
        activeKind = kind; phase = "测试中… · " + kind.title
    }
    private func append(_ result: NetworkDiagnosticResult, kind: NetworkDiagnosticKind, request: UUID) {
        guard request == runID else { return }
        resultKinds[result.id] = kind
        results.append(result)
        jobCompleted += 1
        if kind == .speed {
            liveSpeed = nil
            speedHistory.append(result)
            if speedHistory.count > 40 { speedHistory.removeFirst(speedHistory.count - 40) }
        }
        phase = "测试中… · " + result.line + " · " + result.title
    }
    func measurements(_ kinds: [NetworkDiagnosticKind]) -> [NetworkDiagnosticResult] {
        results.filter { resultKinds[$0.id].map(kinds.contains) ?? false }
    }
    private func finish(_ phase: String, request: UUID) {
        guard request == runID else { return }
        self.phase = phase; running = false; activeKind = nil; liveSpeed = nil; task = nil
    }
    func cancel() {
        guard running else { return }
        runID = UUID()
        task?.cancel(); task = nil
        phase = "测试已取消，已完成的结果保留"
        running = false; activeKind = nil; liveSpeed = nil
    }
    var report: String {
        "AI Lock · " + L10n.text("网络诊断") + "\n" + Date().formatted() + "\n\n" + results.map { result in
            let metrics = result.metrics.map { L10n.text($0.name) + ": " + L10n.text($0.value) }.joined(separator: "\n")
            return "[" + L10n.text(result.title) + "] " + L10n.text(result.line) + "\n" + result.date.formatted() + "\n" + L10n.text(result.summary) + "\n" + metrics + "\n" + result.details
        }.joined(separator: "\n\n--------------------\n\n")
    }
    func copyReport() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(report, forType: .string) }
    func exportReport() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "AI-Lock-Network-Diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do { try self.report.write(to: url, atomically: true, encoding: .utf8) }
            catch { self.phase = error.localizedDescription }
        }
    }
    deinit { task?.cancel() }
}


enum DiagnosticConsole {
    private static func adaptive(_ light: (CGFloat, CGFloat, CGFloat), _ dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(calibratedRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }
    }
    static let backgroundColor = adaptive((0.940, 0.951, 0.957), (0.055, 0.068, 0.080))
    static let background = Color(nsColor: backgroundColor)
    static let panel = Color(nsColor: adaptive((0.995, 0.997, 0.998), (0.090, 0.108, 0.124)))
    static let edge = Color(nsColor: adaptive((0.67, 0.73, 0.77), (0.22, 0.28, 0.32)))
    static let text = Color(nsColor: adaptive((0.12, 0.18, 0.22), (0.88, 0.92, 0.93)))
    static let muted = Color(nsColor: adaptive((0.35, 0.42, 0.46), (0.55, 0.64, 0.69)))
    static let cyan = Color(nsColor: adaptive((0.00, 0.40, 0.44), (0.30, 0.83, 0.88)))
    static let amber = Color(nsColor: adaptive((0.62, 0.34, 0.06), (0.98, 0.68, 0.28)))
    static let red = Color(nsColor: adaptive((0.76, 0.20, 0.18), (0.98, 0.38, 0.36)))
}

struct NetworkDiagnosticsView: View {
    @ObservedObject var model: NetworkDiagnosticsModel
    @AppStorage("appearance.mode") private var appearanceMode = "system"
    @AppStorage("overview.language") private var english = false
    @AppStorage("overview.followSystemLanguage") private var followsSystem = true
    @AppStorage(NetworkDiagnosticNode.catalogRevisionKey) private var nodeCatalogRevision = 0
    @State private var interface = ""
    @State private var allInterfaces = false
    @State private var target = "www.haidatas.com"
    @State private var port = "443"
    @State private var resolver = ""
    @State private var selectedNodes = Set(NetworkDiagnosticNode.defaults.map(\.id))
    @State private var customDownload = ""
    @State private var customUpload = ""
    @State private var validation = ""
    @State private var detailResult: NetworkDiagnosticResult?
    @State private var showingSettings = false
    @State private var displayLine = ""
    private var selectedColorScheme: ColorScheme? { appearanceMode == "light" ? .light : appearanceMode == "dark" ? .dark : nil }
    private var availableLines: [String] { Array(Set(model.interfaces.filter { !$0.ipv6 || !$0.address.lowercased().hasPrefix("fe80:") }.map(\.name))).sorted() }
    private var resultLines: [String] { Array(Set(model.results.filter { model.resultKinds[$0.id] != .local }.map(\.line))).sorted() }
    private var currentLine: String { resultLines.contains(displayLine) ? displayLine : model.liveSpeed?.line ?? resultLines.first ?? "系统默认线路" }
    private func measurements(_ kinds: [NetworkDiagnosticKind]) -> [NetworkDiagnosticResult] {
        model.measurements(kinds).filter { model.resultKinds[$0.id] == .local || $0.line == currentLine }
    }
    private func measurement(_ kind: NetworkDiagnosticKind) -> NetworkDiagnosticResult? { measurements([kind]).last }

    var body: some View {
        let _ = english
        let _ = followsSystem
        let _ = nodeCatalogRevision
        GeometryReader { geometry in
            let contentHeight = max(300, geometry.size.height - (validation.isEmpty ? 148 : 176))
            let miniHeight = (contentHeight - 120) / 2
            VStack(spacing: 10) {
                header
                controls
                if !validation.isEmpty {
                    Text(L10n.text(validation)).foregroundStyle(DiagnosticConsole.amber)
                        .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 10) {
                    card("地区延时地图", code: "02 / ms", kinds: [.regional, .nodes]) { nodesDashboard }
                        .frame(width: (geometry.size.width - 30) * 0.50)
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            card("上传下载测速", code: model.liveSpeed?.line == currentLine ? "LIVE / Mbps" : "01 / Mbps", kinds: [.speed]) { speedDashboard(height: miniHeight) }
                            card("DNS 响应耗时", code: "03 / ms", kinds: [.dns]) { dnsDashboard }
                        }.frame(height: miniHeight)
                        HStack(spacing: 10) {
                            card("延迟与丢包", code: "04 / ms", kinds: [.ping, .port, .ipv6]) { connectivityDashboard }
                            card("路由路径", code: "05 / HOPS", kinds: [.route]) { routeDashboard }
                        }.frame(height: miniHeight)
                        card("本机配置", code: "06 / LAN", kinds: [.local]) { localDashboard }.frame(height: 100)
                    }
                }.frame(height: contentHeight)
                footer
            }.padding(10)
        }
        .foregroundStyle(DiagnosticConsole.text).background(DiagnosticConsole.background)
        .preferredColorScheme(selectedColorScheme).tint(DiagnosticConsole.cyan)
        .onDisappear { model.cancel() }
        .onChange(of: nodeCatalogRevision) { _, _ in selectedNodes.formUnion(NetworkDiagnosticNode.remote.map(\.id)) }
        .sheet(isPresented: $showingSettings) { settingsSheet }
        .sheet(item: $detailResult) { result in
            DiagnosticDetailsSheet(model: model, initial: result).preferredColorScheme(selectedColorScheme)
        }
    }
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg.rectangle").font(.system(size: 22)).foregroundStyle(DiagnosticConsole.cyan)
            Text(L10n.text("网络诊断")).font(.system(size: 17, weight: .semibold))
            Text("NET / 01").font(.system(size: 9, design: .monospaced)).foregroundStyle(DiagnosticConsole.muted)
            Spacer()
            if resultLines.count > 1 {
                Picker(L10n.text("结果线路"), selection: $displayLine) {
                    ForEach(resultLines, id: \.self) { Text(L10n.text($0)).tag($0) }
                }.labelsHidden().frame(width: 125)
            }
            statusBadge("完成", value: String(model.results.count), tint: DiagnosticConsole.cyan)
            statusBadge("需核查", value: String(model.results.filter { !$0.passed }.count), tint: DiagnosticConsole.amber)
            Button { detailResult = model.results.last } label: { Image(systemName: "doc.text.magnifyingglass") }.help(L10n.text("测量详情")).disabled(model.results.isEmpty)
            Button { model.copyReport() } label: { Image(systemName: "doc.on.doc") }.help(L10n.text("复制报告")).disabled(model.results.isEmpty)
            Button { model.exportReport() } label: { Image(systemName: "square.and.arrow.up") }.help(L10n.text("导出报告")).disabled(model.results.isEmpty)
        }.buttonStyle(.borderless).frame(height: 30)
    }
    private var controls: some View {
        HStack(spacing: 10) {
            Image(systemName: "scope").foregroundStyle(DiagnosticConsole.muted)
            TextField(L10n.text("目标域名或 IP"), text: $target).textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity).disabled(model.running)
                .help(L10n.text("目标域名或 IP（不要填写网址）"))
            Picker(L10n.text("测试线路"), selection: $interface) {
                Text(L10n.text("系统默认线路")).tag("")
                ForEach(availableLines, id: \.self) { Text($0).tag($0) }
            }.labelsHidden().frame(width: 160).disabled(model.running || allInterfaces)
            Button { showingSettings = true } label: { Label(L10n.text("诊断参数"), systemImage: "slider.horizontal.3") }.disabled(model.running)
            if model.running {
                ProgressView().controlSize(.small)
                Button { model.cancel() } label: { Label(L10n.text("取消测试"), systemImage: "stop.fill") }.tint(DiagnosticConsole.amber)
            } else {
                Button { startAll() } label: { Label(L10n.text("开始诊断"), systemImage: "play.fill") }.buttonStyle(.borderedProminent)
            }
        }.font(.system(size: 11)).padding(.horizontal, 10).frame(height: 38)
            .background(DiagnosticConsole.panel).overlay(Rectangle().stroke(DiagnosticConsole.edge, lineWidth: 0.7))
    }
    private func card<Content: View>(_ title: String, code: String, kinds: [NetworkDiagnosticKind], @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Rectangle().fill(DiagnosticConsole.cyan).frame(width: 3, height: 10)
                Text(L10n.text(title)).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 2)
                Text(code).font(.system(size: 8, design: .monospaced)).foregroundStyle(DiagnosticConsole.muted)
                Button { detailResult = measurements(kinds).last } label: { Image(systemName: "arrow.up.right") }
                    .buttonStyle(.plain).help(L10n.text("测量详情")).disabled(measurements(kinds).isEmpty)
            }
            content()
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(DiagnosticConsole.panel).overlay(Rectangle().stroke(DiagnosticConsole.edge.opacity(0.7), lineWidth: 0.7))
    }
    private func speedDashboard(height: CGFloat) -> some View {
        let result = measurement(.speed)
        let live = model.liveSpeed.flatMap { $0.line == currentLine ? $0 : nil }
        return VStack(spacing: 7) {
            HStack(spacing: 4) {
                DiagnosticDial(title: L10n.text("下载速度"), value: live != nil ? live?.downloadMbps : result.flatMap { NetworkDiagnosticPlots.metric("下载速度", in: $0) }, tint: DiagnosticConsole.cyan, height: min(112, max(48, height - 105)))
                DiagnosticDial(title: L10n.text("上传速度"), value: live != nil ? live?.uploadMbps : result.flatMap { NetworkDiagnosticPlots.metric("上传速度", in: $0) }, tint: DiagnosticConsole.amber, height: min(112, max(48, height - 105)))
            }.frame(maxHeight: .infinity)
            HStack {
                readout("空闲延迟", value: result.flatMap { metricText("空闲延迟", $0) } ?? "—")
                readout("负载响应能力", value: result.flatMap { metricText("负载响应能力", $0) } ?? "—")
            }
            if let result {
                Text(L10n.text(result.summary))
                    .font(.system(size: 9))
                    .foregroundStyle(result.passed ? DiagnosticConsole.muted : DiagnosticConsole.amber)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if model.running && model.activeKind == .speed {
                Text(L10n.text("正在测试上传和下载速度…"))
                    .font(.system(size: 9))
                    .foregroundStyle(DiagnosticConsole.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private var nodesDashboard: some View {
        let results = measurements([.regional])
        return RegionalLatencyMap(results: results, testing: model.activeKind == .regional) { result in detailResult = result }
    }
    private var dnsDashboard: some View {
        let results = measurements([.dns])
        let times = results.compactMap { NetworkDiagnosticPlots.metric("查询耗时", in: $0) }
        return VStack(spacing: 7) {
            HStack {
                readout("最快中位数", value: times.min().map { String(format: "%.0f ms", $0) } ?? "—")
                readout("解析成功", value: results.isEmpty ? "—" : "\(results.filter { $0.metrics.contains { $0.name == "A 记录" } }.count)/\(results.count)")
            }
            Chart {
                ForEach(results) { result in
                    if let value = NetworkDiagnosticPlots.metric("查询耗时", in: result) {
                        BarMark(x: .value("Resolver", dnsLabel(result)), y: .value("ms", value)).foregroundStyle(result.passed ? DiagnosticConsole.cyan : DiagnosticConsole.amber)
                        PointMark(x: .value("Resolver", dnsLabel(result)), y: .value("ms", value)).foregroundStyle(result.passed ? DiagnosticConsole.cyan : DiagnosticConsole.amber).symbolSize(20)
                    } else {
                        PointMark(x: .value("Resolver", dnsLabel(result)), y: .value("ms", 0)).foregroundStyle(DiagnosticConsole.red).symbol(.cross)
                    }
                }
            }.diagnosticChart().chartYScale(domain: 0...max(10, (times.max() ?? 0) * 1.2))
                .frame(maxHeight: .infinity).overlay { if results.isEmpty { emptyPlot } }
            if results.contains(where: { $0.metrics.contains { $0.name == "解析环境" } }) {
                Text(L10n.text("Fake DNS：耗时可能来自本地代理")).font(.system(size: 8)).foregroundStyle(DiagnosticConsole.amber).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }
    private func dnsLabel(_ result: NetworkDiagnosticResult) -> String {
        let server = result.metrics.first { $0.name == "DNS 服务器" }?.value ?? result.title.replacingOccurrences(of: "DNS · ", with: "")
        return ["系统 DNS": "SYS", "223.5.5.5": "Ali", "119.29.29.29": "DNSPod", "1.1.1.1": "CF", "8.8.8.8": "Google"][server] ?? server
    }
    private var connectivityDashboard: some View {
        let result = measurement(.ping)
        let samples = result.map { NetworkDiagnosticPlots.ping($0.details) } ?? []
        let values = samples.compactMap(\.milliseconds)
        let average = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        let deviation = average.map { mean in sqrt(values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(values.count)) }
        return VStack(spacing: 8) {
            HStack {
                readout("平均延迟", value: average.map { String(format: "%.1f ms", $0) } ?? "—")
                readout("延迟标准差", value: deviation.map { String(format: "%.1f ms", $0) } ?? "—")
                readout("丢包率", value: result.flatMap { NetworkDiagnosticPlots.packetLoss($0.details) }.map { String(format: "%.0f%%", $0) } ?? "—")
            }
            Chart {
                ForEach(samples) { sample in
                    if let time = sample.milliseconds {
                        LineMark(x: .value("Probe", sample.index + 1), y: .value("ms", time), series: .value("Segment", samples.filter { $0.index < sample.index && $0.milliseconds == nil }.count)).foregroundStyle(DiagnosticConsole.cyan)
                        PointMark(x: .value("Probe", sample.index + 1), y: .value("ms", time)).foregroundStyle(DiagnosticConsole.cyan).symbolSize(15)
                    } else {
                        RuleMark(x: .value("Probe", sample.index + 1)).foregroundStyle(DiagnosticConsole.red).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
            }.diagnosticChart().frame(maxHeight: .infinity).overlay { if samples.isEmpty { emptyPlot } }
            HStack {
                connectionBadge("TCP", kind: .port)
                Spacer()
                connectionBadge("IPv6", kind: .ipv6)
            }
        }
    }
    private var routeDashboard: some View {
        let result = measurement(.route)
        let hops = result.map { NetworkDiagnosticPlots.route($0.details) } ?? []
        return VStack(spacing: 8) {
            HStack {
                readout("已探测跳数", value: hops.isEmpty ? "—" : String(hops.count))
                readout("无响应跳数", value: hops.isEmpty ? "—" : String(hops.filter { $0.milliseconds == nil }.count))
            }
            ScrollView {
                if hops.isEmpty {
                    emptyPlot.frame(minHeight: 100)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(hops.indices, id: \.self) { offset in
                            let hop = hops[offset]
                            HStack(alignment: .top, spacing: 9) {
                                VStack(spacing: 0) {
                                    Circle()
                                        .fill(hop.milliseconds == nil ? DiagnosticConsole.amber : DiagnosticConsole.cyan)
                                        .frame(width: 8, height: 8)
                                    if offset < hops.count - 1 {
                                        Rectangle().fill(DiagnosticConsole.edge).frame(width: 1, height: 27)
                                    }
                                }.frame(width: 12)
                                HStack(alignment: .firstTextBaseline, spacing: 5) {
                                    Text(String(format: "%02d", hop.index))
                                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(DiagnosticConsole.muted)
                                    Text(hop.address ?? L10n.text("未响应"))
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(hop.milliseconds == nil ? DiagnosticConsole.amber : DiagnosticConsole.text)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 2)
                                    Text(hop.milliseconds.map { String(format: "%.1f ms", $0) } ?? "—")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(DiagnosticConsole.muted)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
                            }
                            .help("\(hop.index) · \(hop.address ?? L10n.text("未响应")) · " + (hop.milliseconds.map { String(format: "%.1f ms", $0) } ?? "—"))
                        }
                    }.padding(.top, 5)
                }
            }.frame(maxHeight: .infinity)
        }
    }
    private var localDashboard: some View {
        let result = measurement(.local)
        let routeInterface = result.flatMap { metricText("默认接口", $0) } ?? "—"
        let gateway = result.flatMap { metricText("默认网关", $0) } ?? "—"
        let ip = result?.metrics.first { $0.name == routeInterface + " IPv4" }?.value ?? "—"
        let publicIPValue = result.flatMap { metricText("公网 IP", $0) } ?? "—"
        let publicIPParts = publicIPValue.components(separatedBy: " · ")
        let publicIP = publicIPParts.first ?? "—"
        let hasPublicIPLocation = publicIPParts.count > 1
        let publicIPLocation = hasPublicIPLocation ? publicIPParts.dropFirst().joined(separator: " · ") : publicIP == "—" ? "—" : L10n.text("归属地暂不可用")
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(routeInterface + " → " + gateway).font(.system(size: 10, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
                    Label(result.map { L10n.text($0.passed ? "同网段配置正常" : "需要核查配置") } ?? L10n.text("等待测试"), systemImage: result == nil ? "circle.dashed" : result!.passed ? "checkmark.shield" : "exclamationmark.shield")
                        .font(.system(size: 9)).foregroundStyle(result?.passed == false ? DiagnosticConsole.amber : DiagnosticConsole.cyan)
                        .help(result.map { L10n.text($0.summary) } ?? "")
                }.frame(maxWidth: .infinity, alignment: .leading)
                readout("IP / 子网", value: ip)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("公网 IP")).font(.system(size: 8)).foregroundStyle(DiagnosticConsole.muted).lineLimit(1).minimumScaleFactor(0.7)
                    Text(publicIP).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7).textSelection(.enabled)
                    Text(publicIPLocation).font(.system(size: 9)).foregroundStyle(hasPublicIPLocation ? DiagnosticConsole.cyan : DiagnosticConsole.muted).lineLimit(1).minimumScaleFactor(0.7)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .help(L10n.isEnglish
                          ? "Public egress IP and estimated location. ipwho.is receives the IP for lookup; VPNs or proxies may show their exit location."
                          : "当前网络出口 IP 及估算归属地。查询会将公网 IP 发送给 ipwho.is；VPN 或代理可能显示其出口位置。")
            }
        }
    }
    private var footer: some View {
        HStack(spacing: 8) {
            Circle().fill(model.running ? DiagnosticConsole.cyan : DiagnosticConsole.edge).frame(width: 5, height: 5)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = model.running ? model.startedAt.map { " · \(Int(context.date.timeIntervalSince($0)))s" } ?? "" : ""
                Text(L10n.text(validation.isEmpty ? translated(model.phase) : validation) + elapsed)
                    .lineLimit(1).foregroundStyle(validation.isEmpty ? DiagnosticConsole.muted : DiagnosticConsole.amber)
            }
            Spacer()
            if model.running {
                Text("\(model.jobCompleted)/\(model.jobTotal)")
                ProgressView(value: Double(model.jobCompleted), total: Double(max(1, model.jobTotal))).frame(width: 100)
            } else { Text("AI LOCK / NET-01").tracking(1) }
        }.font(.system(size: 9, design: .monospaced)).frame(height: 20)
    }
    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(L10n.text("诊断参数")).font(.headline); Spacer(); Button(L10n.text("完成")) { showingSettings = false } }
            HStack {
                Toggle(L10n.text("逐条比较接口"), isOn: $allInterfaces).toggleStyle(.checkbox)
                Spacer()
                Button(L10n.text("刷新接口")) { model.refreshInterfaces(); if !availableLines.contains(interface) { interface = "" } }
            }
            HStack { field("端口", text: $port); field("自定义 DNS 服务器 IP（可选）", text: $resolver) }
            Text(L10n.text("多节点测速")).font(.caption.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(NetworkDiagnosticNode.defaults) { node in
                    Toggle(node.localizedName, isOn: Binding(get: { selectedNodes.contains(node.id) }, set: { if $0 { selectedNodes.insert(node.id) } else { selectedNodes.remove(node.id) } })).toggleStyle(.checkbox)
                }
            }.font(.system(size: 11))
            field("自定义下载地址（可选，HTTP/HTTPS）", text: $customDownload)
            field("自定义上传地址（可选，需支持 POST 接收测试数据）", text: $customUpload)
            note("测速每条线路约 30 秒，流量取决于网速；所有检查依次执行，避免测速干扰延迟结果。")
            note("每节点最多下载 4 MiB、上传 2 MiB，每次请求最多 12 秒。国内镜像仅作小样本下载比较；海外 CDN 可能就近选点，连接 IP 可能属于代理或 VPN。")
            note("指定接口的 HTTP 测试绕过 HTTP 代理，VPN 隧道仍可能影响选路；多线路指本机接口，不会自动切换运营商。")
        }.padding(24).frame(width: 610).foregroundStyle(DiagnosticConsole.text).background(DiagnosticConsole.background).preferredColorScheme(selectedColorScheme)
    }
    private var emptyPlot: some View {
        VStack(spacing: 5) {
            Image(systemName: "waveform.path").font(.system(size: 20)).foregroundStyle(DiagnosticConsole.edge)
            Text(L10n.text("等待测试")).font(.system(size: 9)).foregroundStyle(DiagnosticConsole.muted)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(DiagnosticConsole.panel).allowsHitTesting(false)
    }
    private func readout(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.text(title)).font(.system(size: 8)).foregroundStyle(DiagnosticConsole.muted).lineLimit(1).minimumScaleFactor(0.7)
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func legend(_ title: String, tint: Color) -> some View {
        HStack(spacing: 4) { Rectangle().fill(tint).frame(width: 6, height: 6); Text(L10n.text(title)).font(.system(size: 8)).foregroundStyle(DiagnosticConsole.muted) }
    }
    private func statusBadge(_ title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 4) { Text(L10n.text(title)).foregroundStyle(DiagnosticConsole.muted); Text(value).foregroundStyle(tint) }.font(.system(size: 10, design: .monospaced))
    }
    private func connectionBadge(_ title: String, kind: NetworkDiagnosticKind) -> some View {
        let result = measurement(kind)
        return Label(title + " " + (result.map { L10n.text($0.passed ? "连接成功" : "未连通") } ?? "—"), systemImage: result == nil ? "circle.dashed" : result!.passed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.system(size: 9)).foregroundStyle(result?.passed == false ? DiagnosticConsole.amber : DiagnosticConsole.cyan)
    }
    private func note(_ text: String) -> some View { Text(L10n.text(text)).font(.system(size: 10)).foregroundStyle(DiagnosticConsole.muted).fixedSize(horizontal: false, vertical: true) }
    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(L10n.text(title)).font(.system(size: 10)); TextField("", text: text).textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced)) }
    }
    private func metricText(_ name: String, _ result: NetworkDiagnosticResult) -> String? { result.metrics.first { $0.name == name }?.value }
    private func translated(_ text: String) -> String { text.components(separatedBy: " · ").map(L10n.text).joined(separator: " · ") }
    private func startAll() {
        validation = ""
        model.refreshInterfaces()
        let host = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let dns = resolver.trimmingCharacters(in: .whitespacesAndNewlines)
        let download = customDownload.trimmingCharacters(in: .whitespacesAndNewlines)
        let upload = customUpload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NetworkDiagnosticService.validTarget(host) else { validation = "请填写有效的域名或 IP，不包含空格、协议或路径"; return }
        guard let tcpPort = Int(port), (1...65535).contains(tcpPort) else { validation = "端口必须为 1–65535"; return }
        guard dns.isEmpty || NetworkDiagnosticService.validIP(dns) else { validation = "DNS 服务器必须为有效 IP 地址"; return }
        guard download.isEmpty || NetworkDiagnosticService.validEndpoint(download), upload.isEmpty || NetworkDiagnosticService.validEndpoint(upload), upload.isEmpty || !download.isEmpty else { validation = "请填写有效 HTTP/HTTPS 地址；上传测试需要同时填写下载节点"; return }
        let lines = allInterfaces ? availableLines : [interface]
        guard !lines.isEmpty else { validation = "没有可用的网络接口"; return }
        var nodes = NetworkDiagnosticNode.defaults.filter { selectedNodes.contains($0.id) }
        if !download.isEmpty { nodes.append(.init(id: "custom", name: "自定义节点", region: "自定义", download: download, upload: upload.isEmpty ? nil : upload)) }
        guard !nodes.isEmpty else { validation = "请至少选择一个节点"; return }
        // A quick local check provides a first result before bandwidth measurement.
        let plans = NetworkDiagnosticPlan.comprehensive(interfaces: lines, target: host, port: tcpPort, resolver: dns, nodes: nodes)
        displayLine = ""
        model.start(plans)
    }

}

private struct DiagnosticDetailsSheet: View {
    @ObservedObject var model: NetworkDiagnosticsModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID
    init(model: NetworkDiagnosticsModel, initial: NetworkDiagnosticResult) {
        self.model = model
        _selection = State(initialValue: initial.id)
    }
    private var focused: NetworkDiagnosticResult? { model.results.first { $0.id == selection } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.text("测量详情")).font(.headline)
                Spacer()
                Button(L10n.text("完成")) { dismiss() }
            }
            Picker(L10n.text("测量结果"), selection: $selection) {
                ForEach(model.results) { result in
                    Text(result.title.components(separatedBy: " · ").map(L10n.text).joined(separator: " · ") + " · " + L10n.text(result.line)).tag(result.id)
                }
            }.labelsHidden()
            if let focused {
                Text(L10n.text(focused.summary)).font(.system(size: 10)).foregroundStyle(DiagnosticConsole.muted)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], alignment: .leading, spacing: 12) {
                        ForEach(Array(focused.metrics.enumerated()), id: \.offset) { _, metric in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.text(metric.name)).font(.system(size: 9)).foregroundStyle(DiagnosticConsole.muted)
                                Text(L10n.text(metric.value)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text(focused.details).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 16)
                }
            }
        }.padding(24).frame(width: 690, height: 480).foregroundStyle(DiagnosticConsole.text).background(DiagnosticConsole.background)
    }
}

private struct DiagnosticDial: View {
    let title: String
    let value: Double?
    let tint: Color
    var height: CGFloat = 100
    private var limit: Double {
        guard let value else { return 100 }
        return [100.0, 500, 1000, 5000, 10000].first { $0 >= value } ?? ceil(value / 10000) * 10000
    }
    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height * 0.56)
                let radius = min(geometry.size.width * 0.42, geometry.size.height * 0.44)
                ZStack {
                    Canvas { context, _ in
                        for tick in 0...40 {
                            let angle = Double(tick) / 40 * 270 + 135
                            let radians = angle * .pi / 180
                            let outer = radius
                            let inner = radius - (tick % 5 == 0 ? 7 : 3)
                            var path = Path()
                            path.move(to: CGPoint(x: center.x + cos(radians) * inner, y: center.y + sin(radians) * inner))
                            path.addLine(to: CGPoint(x: center.x + cos(radians) * outer, y: center.y + sin(radians) * outer))
                            let active = value.map { Double(tick) / 40 <= min(1, $0 / limit) } ?? false
                            context.stroke(path, with: .color(active ? tint : DiagnosticConsole.edge), lineWidth: tick % 5 == 0 ? 2 : 1)
                        }
                        if let value {
                            let radians = (min(1, value / limit) * 270 + 135) * .pi / 180
                            var needle = Path()
                            needle.move(to: center)
                            needle.addLine(to: CGPoint(x: center.x + cos(radians) * (max(0, radius - 12)), y: center.y + sin(radians) * (max(0, radius - 12))))
                            context.stroke(needle, with: .color(tint.opacity(0.6)), lineWidth: 1)
                        }
                    }
                    VStack(spacing: 3) {
                        Text(value.map { String(format: "%.1f", $0) } ?? "—").font(.system(size: height < 70 ? 16 : 20, weight: .medium, design: .monospaced)).foregroundStyle(tint).minimumScaleFactor(0.6)
                        Text("Mbps").font(.system(size: 9, design: .monospaced)).foregroundStyle(DiagnosticConsole.muted)
                    }.background(DiagnosticConsole.panel).position(x: center.x, y: center.y + radius * 0.35)
                    Text("0").font(.system(size: 8, design: .monospaced)).foregroundStyle(DiagnosticConsole.muted).position(x: center.x - radius * 0.76, y: center.y + radius * 0.76)
                    Text(String(format: "%.0f", limit)).font(.system(size: 8, design: .monospaced)).foregroundStyle(DiagnosticConsole.muted).position(x: center.x + radius * 0.76, y: center.y + radius * 0.76)
                }
            }.frame(height: height)
            Text(L10n.text(title)).font(.system(size: 10, weight: .medium)).foregroundStyle(DiagnosticConsole.muted)
        }.frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text(title))
            .accessibilityValue(value.map { String(format: "%.1f Mbps", $0) } ?? L10n.text("尚未测量"))
    }
}

private extension View {
    func diagnosticChart() -> some View {
        self.chartXAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(DiagnosticConsole.edge.opacity(0.5))
                AxisTick().foregroundStyle(DiagnosticConsole.edge)
                AxisValueLabel().foregroundStyle(DiagnosticConsole.muted).font(.system(size: 9, design: .monospaced))
            }
        }.chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(DiagnosticConsole.edge.opacity(0.5))
                AxisTick().foregroundStyle(DiagnosticConsole.edge)
                AxisValueLabel().foregroundStyle(DiagnosticConsole.muted).font(.system(size: 9, design: .monospaced))
            }
        }.chartPlotStyle { plot in plot.background(DiagnosticConsole.background.opacity(0.5)) }
            .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
    }
}

/// Native offline map; region buttons expose exact measurements and target provenance.
private struct RegionalLatencyMap: View {
    let results: [NetworkDiagnosticResult]
    let testing: Bool
    let inspect: (NetworkDiagnosticResult) -> Void
    private let callouts = ["北京", "天津", "上海", "香港", "澳门"]
    private func result(_ id: String) -> NetworkDiagnosticResult? {
        results.last { $0.metrics.contains { $0.name == "地区 ID" && $0.value == id } }
    }
    private func latency(_ id: String) -> Double? { result(id).flatMap { NetworkDiagnosticPlots.metric("平均延迟", in: $0) } }
    private func tint(_ id: String) -> Color {
        guard let value = latency(id) else { return DiagnosticConsole.edge }
        if value < 30 { return Color.green }
        if value < 60 { return DiagnosticConsole.cyan }
        if value < 100 { return DiagnosticConsole.amber }
        return DiagnosticConsole.red
    }
    private func number(_ id: String) -> String {
        if let value = latency(id) { return String(format: value < 10 ? "%.1f" : "%.0f", value) }
        return result(id) == nil && testing ? "…" : "—"
    }
    private func name(_ id: String) -> String {
        guard let region = NetworkLatencyRegion.defaults.first(where: { $0.id == id }) else { return id }
        return L10n.isEnglish ? region.englishName : region.name
    }
    private func mapLabel(_ id: String) -> String {
        guard L10n.isEnglish, !callouts.contains(id) else { return name(id) }
        let labels = ["甘肃": "GS", "青海": "QH", "广西": "GX", "贵州": "GZ", "重庆": "CQ", "福建": "FJ", "安徽": "AH", "广东": "GD", "西藏": "XZ", "新疆": "XJ", "海南": "HI", "宁夏": "NX", "陕西": "SN", "山西": "SX", "湖北": "HB", "湖南": "HN", "四川": "SC", "云南": "YN", "河北": "HE", "河南": "HA", "辽宁": "LN", "山东": "SD", "江西": "JX", "江苏": "JS", "浙江": "ZJ", "吉林": "JL", "内蒙古": "NM", "黑龙江": "HLJ", "台湾": "TW"]
        return labels[id] ?? name(id)
    }
    private func project(_ coordinate: [Double], size: CGSize) -> CGPoint {
        let width = max(1, size.width - 50), height = max(1, size.height - 8)
        let scale = min(width / (62 * 0.82), height / 37)
        return CGPoint(x: (coordinate[0] - 73) * 0.82 * scale + (width - 62 * 0.82 * scale) / 2 + 3,
                       y: (54 - coordinate[1]) * scale + (height - 37 * scale) / 2 + 3)
    }
    private func anchor(_ province: NetworkProvinceGeometry, size: CGSize) -> CGPoint {
        if let index = callouts.firstIndex(of: province.id) {
            return CGPoint(x: size.width - 22, y: 20 + CGFloat(index) * max(22, min(32, (size.height - 40) / 5)))
        }
        let adjusted: [String: [Double]] = ["内蒙古": [110, 43.7], "河北": [116, 39], "河南": [113.5, 34], "山西": [112, 37.7], "陕西": [108.7, 35], "宁夏": [106.3, 38.3], "重庆": [108, 30], "四川": [102, 30.5], "湖北": [112.8, 31.6], "江苏": [120, 33.5], "安徽": [116.8, 31.5], "浙江": [120.3, 29], "台湾": [123, 23.8]]
        return project(adjusted[province.id] ?? province.center, size: size)
    }
    private func path(_ province: NetworkProvinceGeometry, size: CGSize) -> Path {
        var path = Path()
        for polygon in province.polygons {
            for ring in polygon {
                guard let first = ring.first, first.count >= 2 else { continue }
                path.move(to: project(first, size: size))
                for point in ring.dropFirst() where point.count >= 2 { path.addLine(to: project(point, size: size)) }
                path.closeSubpath()
            }
        }
        return path
    }
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                ForEach(Array([("<30", Color.green), ("30–60", DiagnosticConsole.cyan), ("60–100", DiagnosticConsole.amber), ("≥100", DiagnosticConsole.red)].enumerated()), id: \.offset) { item in
                    HStack(spacing: 3) { Rectangle().fill(item.element.1).frame(width: 7, height: 5); Text(item.element.0) }
                }
                Text("ms").foregroundStyle(DiagnosticConsole.muted)
                Spacer(minLength: 0)
                Text("\(results.count)/\(NetworkLatencyRegion.defaults.count)").foregroundStyle(DiagnosticConsole.muted)
            }.font(.system(size: 8, design: .monospaced))
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        for province in NetworkProvinceGeometry.defaults {
                            let boundary = path(province, size: size)
                            context.fill(boundary, with: .color(tint(province.id).opacity(latency(province.id) == nil ? 0.17 : 0.45)), style: FillStyle(eoFill: true))
                            context.stroke(boundary, with: .color(DiagnosticConsole.edge), lineWidth: 0.5)
                            if callouts.contains(province.id) {
                                var line = Path(); line.move(to: project(province.center, size: size)); line.addLine(to: anchor(province, size: size))
                                context.stroke(line, with: .color(tint(province.id).opacity(0.6)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                            }
                        }
                    }
                    ForEach(NetworkProvinceGeometry.defaults) { province in
                        Button { if let value = result(province.id) { inspect(value) } } label: {
                            VStack(spacing: 0) {
                                Text(mapLabel(province.id)).font(.system(size: 8))
                                Text(number(province.id)).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(latency(province.id) == nil ? DiagnosticConsole.muted : DiagnosticConsole.text)
                            }.padding(.horizontal, 2).padding(.vertical, 1).background(DiagnosticConsole.panel.opacity(0.72), in: RoundedRectangle(cornerRadius: 2))
                        }.buttonStyle(.plain).position(anchor(province, size: geometry.size))
                            .accessibilityLabel(name(province.id) + " " + number(province.id) + " ms")
                            .help(tooltip(province.id))
                    }
                    if NetworkProvinceGeometry.defaults.isEmpty { Text(L10n.text("地图数据未加载")) }
                }
            }.frame(maxHeight: .infinity)
            HStack(spacing: 4) {
                ForEach(NetworkLatencyRegion.defaults.filter(\.overseas)) { region in
                    Button { if let value = result(region.id) { inspect(value) } } label: {
                        VStack(spacing: 2) {
                            Text(name(region.id)).font(.system(size: 8)).lineLimit(1).minimumScaleFactor(0.7)
                            Text(number(region.id) + " ms").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(tint(region.id))
                        }.frame(maxWidth: .infinity).padding(.vertical, 5)
                            .background(tint(region.id).opacity(0.08)).overlay(Rectangle().stroke(tint(region.id).opacity(0.3), lineWidth: 0.5))
                    }.buttonStyle(.plain).help(tooltip(region.id))
                }
            }
            Text(L10n.text("本机 → 地区代表节点 · ICMP · — 未响应")).font(.system(size: 8)).foregroundStyle(DiagnosticConsole.muted)
                .help(L10n.text("省级节点为公开区域地址，位置可能调整；延时不代表整个省份。VPN 会影响路由。"))
        }
    }
    private func tooltip(_ id: String) -> String {
        guard let result = result(id) else { return name(id) + " · " + L10n.text("等待测试") }
        let target = result.metrics.first { $0.name == "节点地址" }?.value ?? "—"
        let carrier = result.metrics.first { $0.name == "运营商" }?.value ?? ""
        let source = result.metrics.first { $0.name == "节点来源" }?.value
        return name(id) + " · " + number(id) + " ms\n" + target + " · " + L10n.text(carrier)
            + (source.map { "\n" + L10n.text("来源") + " · " + $0 } ?? "")
            + "\n" + L10n.text(result.summary)
    }
}
