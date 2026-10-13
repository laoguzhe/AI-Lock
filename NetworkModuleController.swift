import AppKit
import SwiftUI
import Darwin

// A record represents one continuously observed socket, rather than a pair of event rows.
struct NetworkActivityRecord: Identifiable {
    let id: UUID
    var connection: NetworkConnection
    let firstSeen: Date
    var lastSeen: Date
    var endedAt: Date?
    let baseline: Bool
    var changes: [String]
    var stateChangedAt: Date? = nil
    var active: Bool { endedAt == nil }
    var change: String {
        if !active { return "已结束" }
        if let date = stateChangedAt, Date().timeIntervalSince(date) <= 30 { return "状态变化" }
        return !baseline && Date().timeIntervalSince(firstSeen) <= 30 ? "新出现" : "持续存在"
    }
    var scope: String { NetworkEndpoint.scope(connection) }
    var service: String { NetworkEndpoint.service(connection) }
    var duration: String {
        let seconds = max(0, Int(lastSeen.timeIntervalSince(firstSeen)))
        return seconds < 60 ? "\(seconds) 秒" : seconds < 3600 ? "\(seconds / 60) 分 \(seconds % 60) 秒" : "\(seconds / 3600) 时 \(seconds % 3600 / 60) 分"
    }
    static func identity(_ connection: NetworkConnection) -> String {
        connection.id + "|" + (connection.processStartTime.map { String($0.timeIntervalSince1970) } ?? "unknown")
    }
}

enum NetworkEndpoint {
    static func host(_ endpoint: String) -> String {
        guard let colon = endpoint.lastIndex(of: ":") else { return endpoint }
        return String(endpoint[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }
    static func scope(_ connection: NetworkConnection) -> String {
        if connection.state == "LISTEN" { return "监听" }
        if connection.remote == "*" { return "未连接" }
        let address = host(connection.remote).lowercased()
        if address == "::1" || address.hasPrefix("127.") { return "本机" }
        let parts = address.split(separator: ".").compactMap { Int($0) }
        if address.hasPrefix("ff") || parts.count == 4 && (224...239).contains(parts[0]) { return "多播" }
        if parts.count == 4 && (parts[0] == 10 || parts[0] == 192 && parts[1] == 168 || parts[0] == 172 && (16...31).contains(parts[1]) || parts[0] == 169 && parts[1] == 254) { return "局域网" }
        if address.hasPrefix("fe80:") || address.hasPrefix("fc") || address.hasPrefix("fd") { return "局域网" }
        return "外网"
    }
    static func service(_ connection: NetworkConnection) -> String {
        let endpoint = connection.remote == "*" ? connection.local : connection.remote
        guard let token = endpoint.split(separator: ":").last, let port = Int(token) else { return "—" }
        return [22: "SSH", 25: "SMTP", 53: "DNS", 80: "HTTP", 123: "NTP", 143: "IMAP", 443: "HTTPS / QUIC", 465: "SMTPS", 587: "SMTP", 993: "IMAPS", 3306: "MySQL", 5432: "PostgreSQL", 5353: "mDNS", 6379: "Redis", 8080: "HTTP 代理/开发", 8443: "HTTPS 开发"][port] ?? "端口 \(port)"
    }
    static func resolve(_ endpoint: String) -> String? {
        let address = host(endpoint)
        guard !address.isEmpty, address != "*" else { return nil }
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, nil, &hints, &result) == 0, let result else { return nil }
        defer { freeaddrinfo(result) }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(result.pointee.ai_addr, result.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NAMEREQD) == 0 else { return nil }
        return String(cString: buffer)
    }
}

struct NetworkActivityHistory {
    private(set) var records: [NetworkActivityRecord] = []
    private var baseline = false
    mutating func interrupt() { baseline = false }
    mutating func ingest(_ connections: [NetworkConnection], at now: Date) {
        let current = Dictionary(connections.map { (NetworkActivityRecord.identity($0), $0) }, uniquingKeysWith: { first, _ in first })
        var remaining = current
        for index in records.indices where records[index].active {
            let key = NetworkActivityRecord.identity(records[index].connection)
            if let connection = remaining.removeValue(forKey: key) {
                let previousState = records[index].connection.state
                if connection.state != previousState {
                    records[index].stateChangedAt = now
                    records[index].changes.append("\(now.formatted(date: .omitted, time: .standard))  \(previousState) → \(connection.state)")
                    records[index].changes = Array(records[index].changes.suffix(30))
                }
                records[index].connection = connection
                records[index].lastSeen = now
            } else {
                records[index].endedAt = now
                records[index].changes.append("\(now.formatted(date: .omitted, time: .standard))  \(baseline ? "采样发现连接结束" : "恢复采样时已不存在（结束时间未知）")")
            }
        }
        for connection in remaining.values {
            records.append(NetworkActivityRecord(id: UUID(), connection: connection, firstSeen: now, lastSeen: now, endedAt: nil, baseline: !baseline,
                changes: ["\(now.formatted(date: .omitted, time: .standard))  \(baseline ? "首次发现" : "采样基线：首次观测")"]))
        }
        baseline = true
        // Bound history without ever discarding a live connection.
        let retained = Set(records.filter { !$0.active }.sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }.prefix(1000).map(\.id))
        records.removeAll { !$0.active && !retained.contains($0.id) }
    }
}

struct NetworkTrafficSample: Identifiable {
    let date: Date
    let download: Double
    let upload: Double
    var id: Date { date }
}

struct NetworkApplicationBandwidth: Identifiable {
    let name: String
    let pid: pid_t
    let download: Double
    let upload: Double
    var id: String { name }
    var total: Double { download + upload }
}

final class NetworkActivityModel: ObservableObject {
    @Published var history = NetworkActivityHistory()
    @Published var search = ""
    @Published var period = "当前连接"
    @Published var app = "所有应用"
    @Published var proto = "所有协议"
    @Published var scope = "所有范围"
    @Published var sort = "最近变化"
    @Published var grouped = false
    @Published var paused = false
    @Published var sampling = false
    @Published var status = "正在读取连接…"
    @Published var sampledAt: Date?
    @Published var rates: [pid_t: ProcessNetworkMonitor.Rate] = [:]
    @Published private(set) var trafficSamples: [NetworkTrafficSample] = []
    @Published var trafficWindowSeconds = 60
    @Published var selected: UUID?
    @Published var detail: NetworkActivityRecord?
    var refresh: (() -> Void)?
    var togglePause: (() -> Void)?
    var all: [NetworkActivityRecord] { history.records }
    var apps: [String] { Array(Set(all.map { $0.connection.process })).sorted() }
    var visibleTrafficSamples: [NetworkTrafficSample] {
        let cutoff = Date().addingTimeInterval(-Double(trafficWindowSeconds))
        return trafficSamples.filter { $0.date >= cutoff }
    }
    var topBandwidthApps: [NetworkApplicationBandwidth] {
        let grouped = Dictionary(grouping: all.filter(\.active), by: { $0.connection.process })
        return grouped.compactMap { name, records -> NetworkApplicationBandwidth? in
            let pids = Set(records.map { $0.connection.pid })
            let values = pids.compactMap { rates[$0] }
            guard !values.isEmpty else { return nil }
            let download = values.reduce(0) { $0 + max(0, $1.down) }
            let upload = values.reduce(0) { $0 + max(0, $1.up) }
            guard download + upload > 0, let pid = pids.min() else { return nil }
            return NetworkApplicationBandwidth(name: name, pid: pid, download: download, upload: upload)
        }.sorted { $0.total == $1.total ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.total > $1.total }.prefix(5).map { $0 }
    }
    var visible: [NetworkActivityRecord] {
        let now = Date()
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.filter { record in
            let c = record.connection
            let recent = (!record.baseline && now.timeIntervalSince(record.firstSeen) <= 60) || record.endedAt.map { now.timeIntervalSince($0) <= 60 } == true || record.stateChangedAt.map { now.timeIntervalSince($0) <= 60 } == true
            let inPeriod = period == "全部记录" || (period == "最近变化" ? recent : record.active || record.endedAt.map { now.timeIntervalSince($0) <= 30 } == true)
            return inPeriod && (app == "所有应用" || c.process == app) && (proto == "所有协议" || c.protocolName == proto) && (scope == "所有范围" || record.scope == scope) && (query.isEmpty || "\(c.process) \(c.pid) \(c.local) \(c.remote) \(c.state) \(record.service)".localizedCaseInsensitiveContains(query))
        }.sorted { a, b in
            switch sort {
            case "应用名称": return a.connection.process == b.connection.process ? a.id.uuidString < b.id.uuidString : a.connection.process.localizedStandardCompare(b.connection.process) == .orderedAscending
            case "远端地址": return a.connection.remote == b.connection.remote ? a.id.uuidString < b.id.uuidString : a.connection.remote < b.connection.remote
            case "观测时长": return a.lastSeen.timeIntervalSince(a.firstSeen) > b.lastSeen.timeIntervalSince(b.firstSeen)
            default: return (a.endedAt ?? a.stateChangedAt ?? a.firstSeen) > (b.endedAt ?? b.stateChangedAt ?? b.firstSeen)
            }
        }
    }
    var chosen: NetworkActivityRecord? { visible.first { $0.id == selected } }
    func appendTrafficSample(download: Double, upload: Double, at date: Date = Date()) {
        guard download.isFinite, upload.isFinite else { return }
        trafficSamples.append(NetworkTrafficSample(date: date, download: max(0, download), upload: max(0, upload)))
        let cutoff = date.addingTimeInterval(-120)
        trafficSamples.removeAll { $0.date < cutoff }
        if trafficSamples.count > 120 { trafficSamples.removeFirst(trafficSamples.count - 120) }
    }
    func rate(for records: [NetworkActivityRecord]) -> (down: Double, up: Double)? {
        let pids = Set(records.filter(\.active).map { $0.connection.pid })
        let values = pids.compactMap { rates[$0] }
        guard !values.isEmpty else { return nil }
        return values.reduce((down: 0.0, up: 0.0)) { ($0.down + $1.down, $0.up + $1.up) }
    }
    static func speed(_ bytes: Double) -> String { if bytes == 0 { return "0 B/s" }; return ByteCountFormatter.string(fromByteCount: Int64(min(Double(Int64.max / 2), max(0, bytes))), countStyle: .binary) + "/s" }
    func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    static func csv(_ rows: [NetworkActivityRecord]) -> String {
        func field(_ value: String) -> String {
            // Avoid executing spreadsheet formulas when an application name is exported.
            let safe = ["=", "+", "-", "@", "\t", "\r"].contains(where: { value.hasPrefix($0) }) ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let formatter = ISO8601DateFormatter()
        let header = ["应用", "PID", "协议", "本地地址", "远端地址", "状态", "变化", "范围", "端口说明", "首次发现", "最后发现", "发现结束", "观测时长"]
        let data = [header] + rows.map { r in [r.connection.process, String(r.connection.pid), r.connection.protocolName, r.connection.local, r.connection.remote, r.connection.state, r.change, r.scope, r.service, formatter.string(from: r.firstSeen), formatter.string(from: r.lastSeen), r.endedAt.map { formatter.string(from: $0) } ?? "", r.duration] }
        return "\u{FEFF}" + data.map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n")
    }
    func export() {
        let rows = visible
        let panel = NSSavePanel(); panel.nameFieldStringValue = L10n.text("网络活动.csv"); panel.allowedContentTypes = [.commaSeparatedText]
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try Self.csv(rows).write(to: url, atomically: true, encoding: .utf8) }
            catch { let alert = NSAlert(); alert.messageText = L10n.text("导出失败"); alert.informativeText = L10n.text(error.localizedDescription); alert.beginSheetModal(for: window) }
        }
    }
}

final class NetworkModuleController: ModuleViewController {
    private let model = NetworkActivityModel()
    private let traffic = ProcessNetworkMonitor()
    private var timer: Timer?
    private var generation = 0
    private var inProgress = false
    private let queue = DispatchQueue(label: "com.laogu.ailock.network-page", qos: .utility)
    override func loadView() {
        model.refresh = { [weak self] in self?.refresh() }
        model.togglePause = { [weak self] in
            guard let self else { return }
            self.model.paused.toggle()
            if self.model.paused { self.stop() } else { self.resume() }
        }
        view = NSHostingView(rootView: NetworkActivityView(model: model))
    }
    func stop() {
        generation += 1; timer?.invalidate(); timer = nil; traffic.stop(); inProgress = false
        model.sampling = false; model.rates = [:]; model.history.interrupt()
    }
    func resume() {
        stop()
        guard !model.paused else { return }
        traffic.start(); refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.model.rates = self.traffic.currentRates()
            if let rate = self.model.rate(for: self.model.all) {
                self.model.appendTrafficSample(download: rate.down, upload: rate.up)
            }
            if self.model.sampledAt.map({ Date().timeIntervalSince($0) >= 5 }) ?? true { self.refresh() }
            // Refresh age-based badges and auto-hide ended rows between snapshots.
            self.model.objectWillChange.send()
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func refresh() {
        guard !inProgress, !model.paused else { return }
        inProgress = true; model.sampling = true
        let request = generation
        queue.async { [weak self] in
            let result = Result { try NetworkObservationService.shared.observation(maxAge: 0) }
            DispatchQueue.main.async { [weak self] in
                guard let self, request == self.generation else { return }
                self.inProgress = false; self.model.sampling = false
                switch result {
                case .success(let observation):
                    self.model.history.ingest(observation.connections, at: observation.sampledAt)
                    self.model.sampledAt = observation.sampledAt
                    self.model.status = "每 5 秒采样 · 已结束连接保留 30 秒 · 最近变化为 60 秒 · 历史最多 1,000 条"
                case .failure(let error): self.model.status = "采样失败，保留上次结果：\(error.localizedDescription)"
                }
            }
        }
    }
    deinit { timer?.invalidate(); traffic.stop() }
}

private struct NetworkFilterMenu: NSViewRepresentable {
    @ObservedObject var model: NetworkActivityModel
    let scopes: [String]

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.controlSize = .regular
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        context.coordinator.button = button
        context.coordinator.rebuildMenu(scopes: scopes)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.model = model
        context.coordinator.button = button
        context.coordinator.scopes = scopes
        if !context.coordinator.menuOpen {
            context.coordinator.rebuildMenu(scopes: scopes)
        }
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        var model: NetworkActivityModel
        weak var button: NSPopUpButton?
        var scopes: [String] = []
        var menuOpen = false

        init(model: NetworkActivityModel) { self.model = model }

        func rebuildMenu(scopes: [String]) {
            self.scopes = scopes
            guard let button else { return }

            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self
            var selectedFilters: [String] = []
            let query = model.search.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty { selectedFilters.append(L10n.format("搜索：%{0}", arguments: [query])) }
            if model.period != "当前连接" { selectedFilters.append(L10n.format("记录：%{0}", arguments: [L10n.text(model.period)])) }
            if model.app != "所有应用" { selectedFilters.append(L10n.format("应用：%{0}", arguments: [model.app])) }
            if model.proto != "所有协议" { selectedFilters.append(L10n.format("协议：%{0}", arguments: [model.proto])) }
            if model.scope != "所有范围" { selectedFilters.append(L10n.format("范围：%{0}", arguments: [L10n.text(model.scope)])) }
            if model.sort != "最近变化" { selectedFilters.append(L10n.format("排序：%{0}", arguments: [L10n.text(model.sort)])) }
            let title = ([L10n.text("筛选")] + selectedFilters).joined(separator: " · ")
            let titleItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            titleItem.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: nil)
            menu.addItem(titleItem)

            addSubmenu("显示记录", values: ["当前连接", "最近变化", "全部记录"], selected: model.period, key: "period", to: menu)
            addSubmenu("应用", values: ["所有应用"] + model.apps, selected: model.app, key: "app", to: menu)
            addSubmenu("协议", values: ["所有协议", "TCP", "UDP"], selected: model.proto, key: "proto", to: menu)
            addSubmenu("网络范围", values: scopes, selected: model.scope, key: "scope", to: menu)
            addSubmenu("排序方式", values: ["最近变化", "应用名称", "远端地址", "观测时长"], selected: model.sort, key: "sort", to: menu)

            button.menu = menu
            button.selectItem(at: 0)
        }

        private func addSubmenu(_ title: String, values: [String], selected: String, key: String, to menu: NSMenu) {
            let parent = NSMenuItem(title: L10n.text(title), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for value in values {
                let item = NSMenuItem(title: L10n.text(value), action: #selector(selectFilter(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = "\(key)\u{1F}\(value)" as NSString
                item.state = value == selected ? .on : .off
                submenu.addItem(item)
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }

        @objc private func selectFilter(_ sender: NSMenuItem) {
            guard let payload = sender.representedObject as? String else { return }
            let parts = payload.components(separatedBy: "\u{1F}")
            guard parts.count == 2 else { return }
            switch parts[0] {
            case "period": model.period = parts[1]
            case "app": model.app = parts[1]
            case "proto": model.proto = parts[1]
            case "scope": model.scope = parts[1]
            case "sort": model.sort = parts[1]
            default: break
            }
        }

        func menuWillOpen(_ menu: NSMenu) { menuOpen = true }

        func menuDidClose(_ menu: NSMenu) {
            menuOpen = false
            // Model changes refresh the visible selection and count after the native menu closes.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.rebuildMenu(scopes: self.scopes)
            }
        }
    }
}

private struct NetworkActivityView: View {
    @AppStorage("overview.language") private var localizationEnglish = false
    @AppStorage("overview.followSystemLanguage") private var localizationFollowsSystem = true
    @ObservedObject var model: NetworkActivityModel
    private let scopes = ["所有范围", "外网", "局域网", "本机", "多播", "监听", "未连接"]
    var body: some View {
        let _ = localizationEnglish
        let _ = localizationFollowsSystem
        VStack(alignment: .leading, spacing: 10) {
            overview
            trafficDashboard
            HStack(spacing: 8) {
                TextField(L10n.text("搜索应用、PID、IP、端口或服务"), text: $model.search)
                    .textFieldStyle(.roundedBorder).frame(minWidth: 180, maxWidth: .infinity)
                filterMenu
                Toggle(L10n.text("按应用分组"), isOn: $model.grouped).toggleStyle(.checkbox)
                Button(L10n.text("重置筛选")) { model.search = ""; model.app = "所有应用"; model.proto = "所有协议"; model.scope = "所有范围"; model.period = "当前连接"; model.sort = "最近变化" }
                Button { model.export() } label: { Label(L10n.text("导出"), systemImage: "square.and.arrow.up") }.disabled(model.visible.isEmpty)
            }
            if model.grouped { groupedList } else { connectionTable }
            HStack {
                Text(L10n.format("显示 %{0} / %{1} 条", arguments: [String(describing: model.visible.count), String(describing: model.all.count)]))
                Spacer()
                Button(L10n.text("复制远端")) { if let record = model.chosen { model.copy(record.connection.remote) } }.disabled(model.chosen == nil)
                Button(L10n.text("连接详情")) { model.detail = model.chosen }.disabled(model.chosen == nil)
            }
            HStack {
                Spacer()
                if let date = model.sampledAt { Text(L10n.format("更新 %{0}", arguments: [String(describing: date.formatted(date: .omitted, time: .standard))])) }
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.top, 0).padding(.bottom, 0)
        .frame(minWidth: 700, minHeight: 430, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $model.detail) { record in NetworkConnectionDetail(record: record, model: model) }
    }
    private var filterMenu: some View {
        NetworkFilterMenu(
            model: model,
            scopes: scopes
        )
    }
    private var overview: some View {
        let active = model.all.filter(\.active)
        let recent = model.all.filter { !$0.baseline && Date().timeIntervalSince($0.firstSeen) <= 60 }.count
        let ended = model.all.filter { $0.endedAt.map { Date().timeIntervalSince($0) <= 60 } == true }.count
        return HStack(spacing: 8) {
            metric("当前连接", "\(active.count)")
            metric("联网进程", "\(Set(active.filter { $0.connection.remote != "*" }.map { $0.connection.pid }).count)")
            metric("监听端口", "\(Set(active.filter { $0.scope == "监听" }.map { $0.connection.local }).count)")
            metric("近 1 分钟", "+\(recent) / −\(ended)")
            let rate = model.rate(for: active)
            metric("下载 / 上传", (model.paused ? "已暂停" : rate.map { "↓ \(NetworkActivityModel.speed($0.down))  ↑ \(NetworkActivityModel.speed($0.up))" } ?? "等待流量采样"))
        }
    }
    private var trafficDashboard: some View {
        let samples = model.visibleTrafficSamples
        let maximum = max(1, samples.reduce(0.0) { max($0, max($1.download, $1.upload)) })
        let apps = model.topBandwidthApps
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(L10n.text("流量趋势")).font(.caption.weight(.semibold))
                    HStack(spacing: 4) { Circle().fill(.cyan).frame(width: 6, height: 6); Text(L10n.text("下载速度")).foregroundStyle(.secondary) }
                    HStack(spacing: 4) { Circle().fill(.orange).frame(width: 6, height: 6); Text(L10n.text("上传速度")).foregroundStyle(.secondary) }
                    Spacer()
                    Picker(L10n.text("时间范围"), selection: $model.trafficWindowSeconds) {
                        Text("60s").tag(60)
                        Text("120s").tag(120)
                    }.pickerStyle(.segmented).frame(width: 104).controlSize(.small)
                }.font(.caption2)
                Canvas { context, size in
                    var grid = Path()
                    for fraction in [0.0, 0.5, 1.0] {
                        let y = size.height * CGFloat(fraction)
                        grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(grid, with: .color(Color.secondary.opacity(0.18)), lineWidth: 1)
                    let cutoff = Date().addingTimeInterval(-Double(model.trafficWindowSeconds))
                    func curve(_ value: (NetworkTrafficSample) -> Double) -> Path {
                        var path = Path()
                        var previousDate: Date?
                        for sample in samples {
                            let elapsed = CGFloat(sample.date.timeIntervalSince(cutoff))
                            let x = min(size.width, max(0, size.width * elapsed / CGFloat(model.trafficWindowSeconds)))
                            let y = size.height * (1 - CGFloat(min(1, value(sample) / maximum)))
                            let point = CGPoint(x: x, y: y)
                            if previousDate == nil || sample.date.timeIntervalSince(previousDate!) > 2.5 { path.move(to: point) }
                            else { path.addLine(to: point) }
                            previousDate = sample.date
                        }
                        return path
                    }
                    context.stroke(curve { $0.download }, with: .color(.cyan), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    context.stroke(curve { $0.upload }, with: .color(.orange), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                .frame(height: 76)
                HStack {
                    Text(L10n.text(model.paused ? "已暂停采样" : (samples.isEmpty ? "等待流量采样" : "实时"))).foregroundStyle(.secondary)
                    Spacer()
                    if let latest = samples.last {
                        Text("↓ \(NetworkActivityModel.speed(latest.download))   ↑ \(NetworkActivityModel.speed(latest.upload))").monospacedDigit().foregroundStyle(.secondary)
                    }
                }.font(.system(size: 10))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text("高流量应用")).font(.caption.weight(.semibold))
                if apps.isEmpty {
                    Text(L10n.text("暂无进程流量")).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                } else {
                    ForEach(apps) { app in
                        HStack(spacing: 6) {
                            Image(nsImage: applicationIcon(for: app.pid))
                                .resizable().aspectRatio(contentMode: .fit).frame(width: 18, height: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name).lineLimit(1)
                                Text("↓ \(NetworkActivityModel.speed(app.download))   ↑ \(NetworkActivityModel.speed(app.upload))")
                                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
                            }
                            Spacer(minLength: 0)
                        }.frame(height: 20)
                    }
                }
            }
            .frame(width: 230, alignment: .leading)
        }
        .padding(10)
        .frame(height: 142)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(L10n.text(title)).font(.caption).foregroundStyle(.secondary); Text(L10n.text(value)).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8) }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
    private func applicationIcon(for pid: pid_t) -> NSImage {
        if let icon = NSRunningApplication(processIdentifier: pid)?.icon { return icon }
        if pid > 0 {
            var buffer = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                return NSWorkspace.shared.icon(forFile: String(cString: buffer))
            }
        }
        return NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage(size: NSSize(width: 18, height: 18))
    }
    private var connectionTable: some View {
        Table(model.visible, selection: $model.selected) {
            TableColumn(L10n.text("应用 / PID")) { r in
                HStack(spacing: 5) {
                    Image(nsImage: NSRunningApplication(processIdentifier: r.connection.pid)?.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!).resizable().frame(width: 18, height: 18)
                    VStack(alignment: .leading) { Text(r.connection.process); Text(String(r.connection.pid)).font(.caption2).foregroundStyle(.secondary) }
                }.opacity(r.active ? 1 : 0.5)
            }.width(min: 130, ideal: 140)
            TableColumn(L10n.text("协议")) { r in Text(r.connection.protocolName) }.width(L10n.isEnglish ? 70 : 45)
            TableColumn(L10n.text("远端 / 服务")) { r in VStack(alignment: .leading) { Text(r.connection.remote); Text(L10n.text(r.service)).font(.caption2).foregroundStyle(.secondary) }.help(L10n.text(r.connection.remote)).opacity(r.active ? 1 : 0.5) }.width(min: 160, ideal: 200)
            TableColumn(L10n.text("本地地址")) { r in Text(r.connection.local).help(L10n.text(r.connection.local)).opacity(r.active ? 1 : 0.5) }.width(min: 130, ideal: 140)
            TableColumn(L10n.text("状态 / 变化")) { r in
                VStack(alignment: .leading) {
                    Text(L10n.text(r.active ? r.connection.state : L10n.text("已结束"))).font(.caption)
                    Text(L10n.text(r.change)).font(.caption2).foregroundStyle(r.active ? Color.green : Color.secondary)
                }
            }.width(min: 80, ideal: L10n.isEnglish ? 110 : 100)
            TableColumn(L10n.text("范围")) { r in Text(L10n.text(r.scope)) }.width(L10n.isEnglish ? 70 : 55)
            TableColumn(L10n.text("观测时长")) { r in Text(L10n.text(r.duration)).font(.caption) }.width(90)
        }
        .overlay { if model.visible.isEmpty { emptyState } }
        .contextMenu { Button(L10n.text("复制远端")) { if let r = model.chosen { model.copy(r.connection.remote) } }.disabled(model.chosen == nil); Button(L10n.text("连接详情")) { model.detail = model.chosen }.disabled(model.chosen == nil) }
    }
    private var groupedList: some View {
        let groups = Dictionary(grouping: model.visible, by: { $0.connection.process })
        return List(selection: $model.selected) {
            ForEach(groups.keys.sorted(), id: \.self) { name in
                let rows = groups[name] ?? []
                DisclosureGroup {
                    ForEach(rows) { r in
                        HStack {
                            Text("\(r.connection.protocolName) · \(r.connection.pid)").frame(width: 85, alignment: .leading)
                            Text(r.connection.remote).lineLimit(1)
                            Spacer()
                            Text(L10n.text(r.scope)).foregroundStyle(.secondary)
                            Text(L10n.text(r.active ? r.connection.state : L10n.text("已结束"))).frame(width: 100)
                            Button(L10n.text("详情")) { model.selected = r.id; model.detail = r }.buttonStyle(.borderless)
                        }.font(.caption).opacity(r.active ? 1 : 0.5).tag(r.id)
                    }
                } label: {
                    HStack {
                        Text(name).fontWeight(.medium)
                        Text(L10n.format("%{0} 条当前 / %{1} 条显示", arguments: [String(describing: rows.filter(\.active).count), String(describing: rows.count)])).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let rate = model.rate(for: rows) { Text("↓ \(NetworkActivityModel.speed(rate.down))   ↑ \(NetworkActivityModel.speed(rate.up))").monospacedDigit().font(.caption) }
                        else { Text(L10n.text("流量暂无数据")).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }.overlay { if model.visible.isEmpty { emptyState } }
    }
    private var emptyState: some View {
        VStack(spacing: 8) { Image(systemName: "network").font(.largeTitle); Text(L10n.text(model.sampling ? L10n.text("正在读取连接…") : L10n.text("没有符合筛选条件的连接"))); Text(L10n.text("可切换到全部记录或重置筛选")).font(.caption) }.foregroundStyle(.secondary).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct NetworkConnectionDetail: View {
    @AppStorage("overview.language") private var localizationEnglish = false
    @AppStorage("overview.followSystemLanguage") private var localizationFollowsSystem = true
    let record: NetworkActivityRecord
    @ObservedObject var model: NetworkActivityModel
    @Environment(\.dismiss) private var dismiss
    @State private var hostname = "查询中…"
    private var current: NetworkActivityRecord { model.all.first { $0.id == record.id } ?? record }
    var body: some View {
        let _ = localizationEnglish
        let _ = localizationFollowsSystem
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(L10n.text("连接详情")).font(.headline); Spacer(); Button(L10n.text("完成")) { dismiss() }.keyboardShortcut(.cancelAction) }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    detail("应用 / PID", "\(current.connection.process) / \(current.connection.pid)")
                    detail("协议 / 状态", "\(current.connection.protocolName) / \(current.active ? current.connection.state : L10n.text("已结束"))")
                    detail("本地地址", current.connection.local)
                    detail("远端地址", current.connection.remote)
                    detail("远端主机名", L10n.text(hostname))
                    detail("范围 / 端口说明", "\(L10n.text(current.scope)) / \(L10n.text(current.service))")
                    detail("首次发现", current.firstSeen.formatted(date: .numeric, time: .standard))
                    detail("最后发现", current.lastSeen.formatted(date: .numeric, time: .standard))
                    if let date = current.endedAt { detail("发现结束", date.formatted(date: .numeric, time: .standard)) }
                    detail("观测时长", L10n.text(current.duration) + (current.baseline ? L10n.text("（基线连接，实际开始时间未知）") : ""))
                    detail("可执行文件", executablePath ?? L10n.text("进程已结束或路径不可访问"))
                    Divider()
                    Text(L10n.text("本次观测变化")).fontWeight(.medium)
                    ForEach(Array(current.changes.enumerated()), id: \.offset) { _, value in Text(L10n.text(value)).font(.caption).textSelection(.enabled) }
                }
            }
            HStack {
                Button(L10n.text("复制远端")) { model.copy(current.connection.remote) }
                Button(L10n.text("复制详情")) { model.copy("\(current.connection.process) (PID \(current.connection.pid))\n\(current.connection.protocolName) \(current.connection.local) → \(current.connection.remote)\n\(L10n.text("状态："))\(L10n.text(current.connection.state))\n\(L10n.text("首次发现："))\(current.firstSeen)\n\(L10n.text("最后发现："))\(current.lastSeen)\n\(current.changes.map { L10n.text($0) }.joined(separator: "\n"))") }
                Button(L10n.text("在 Finder 查看进程文件")) { if let path = executablePath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }.disabled(executablePath == nil)
            }
        }.padding(20).frame(width: 620, height: 500)
        .task(id: record.id) {
            let endpoint = record.connection.remote
            if endpoint == "*" { hostname = "无远端地址"; return }
            let value = await Task.detached(priority: .utility) { NetworkEndpoint.resolve(endpoint) }.value
            guard !Task.isCancelled else { return }
            hostname = value ?? "无反向 DNS 记录"
        }
    }
    private var executablePath: String? {
        guard current.active, current.connection.pid > 0, let expected = current.connection.processStartTime else { return nil }
        var info = proc_bsdinfo()
        guard proc_pidinfo(current.connection.pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size),
              Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000) == expected else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(current.connection.pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(L10n.text(title)).foregroundStyle(.secondary).frame(width: 105, alignment: .leading); Text(value).textSelection(.enabled); Spacer() }.font(.system(size: 12))
    }
}
