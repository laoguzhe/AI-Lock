import AppKit
import Combine

/// The app owns sampling and resource alert state; opening a view never resets them.
final class MonitoringService: ObservableObject {
    static let shared = MonitoringService()
    @Published private(set) var snapshot = SystemSnapshot.empty
    private let sample: () -> SystemSnapshot
    private let alerts: ResourceAlerts
    private let recordHistory: (SystemSnapshot) -> Void
    private var timer: Timer?
    private let backgroundSampling: Bool
    private let queue = DispatchQueue(label: "com.laogu.ailock.resource-sampling", qos: .utility)
    private var inProgress = false
    private var generation = 0
    var onSample: ((SystemSnapshot) -> Void)?

    private convenience init() {
        let monitor = SystemMonitor()
        self.init(sample: { monitor.sample() }, alerts: ResourceAlerts(), recordHistory: { value in
            NetworkHistory.shared.record(at: value.timestamp, downloadBytesPerSecond: value.networkDownload,
                                         uploadBytesPerSecond: value.networkUpload, duration: value.networkSampleDuration)
        }, backgroundSampling: true)
    }

    init(sample: @escaping () -> SystemSnapshot, alerts: ResourceAlerts,
         recordHistory: @escaping (SystemSnapshot) -> Void, backgroundSampling: Bool = false) {
        self.backgroundSampling = backgroundSampling
        self.sample = sample; self.alerts = alerts; self.recordHistory = recordHistory
    }

    func start(interval: TimeInterval = 1) {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: max(interval, 0.01), repeats: true) { [weak self] _ in self?.refresh() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        generation += 1; inProgress = false
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        guard !inProgress else { return }
        let request = generation
        if backgroundSampling {
            inProgress = true
            queue.async { [weak self] in
                guard let self else { return }
                let value = self.sample()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == request else { return }
                    self.inProgress = false
                    self.publish(value)
                }
            }
        } else { publish(sample()) }
    }

    private func publish(_ value: SystemSnapshot) {
        recordHistory(value)
        alerts.evaluate(value)
        snapshot = value
        onSample?(value)
    }

    deinit { timer?.invalidate() }
}
