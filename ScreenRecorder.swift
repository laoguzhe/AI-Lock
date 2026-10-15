import AVFoundation
import AppKit
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

enum ScreenRecorderQuality: String, CaseIterable, Identifiable {
    case p720
    case p1080
    case p1440
    case p2160
    case original

    var id: String { rawValue }
    var title: String {
        switch self {
        case .p720: "720p"
        case .p1080: "1080p"
        case .p1440: "1440p (2K)"
        case .p2160: "2160p (4K)"
        case .original: L10n.text("原始分辨率")
        }
    }

    func dimensions(for display: SCDisplay, pixelScale: CGFloat) -> (width: Int, height: Int) {
        let nativeWidth = CGFloat(display.width) * pixelScale
        let nativeHeight = CGFloat(display.height) * pixelScale
        let maxHeight: CGFloat
        switch self {
        case .p720: maxHeight = 720
        case .p1080: maxHeight = 1080
        case .p1440: maxHeight = 1440
        case .p2160: maxHeight = 2160
        case .original: maxHeight = nativeHeight
        }
        let scale = min(1, maxHeight / nativeHeight)
        let width = max(2, Int((nativeWidth * scale).rounded()) / 2 * 2)
        let height = max(2, Int((nativeHeight * scale).rounded()) / 2 * 2)
        return (width, height)
    }

    var bitRate: Int {
        switch self {
        case .p720: 4_000_000
        case .p1080: 8_000_000
        case .p1440: 16_000_000
        case .p2160: 32_000_000
        case .original: 48_000_000
        }
    }
}

/// Outcome of the most recent recording, shown on the recorder page once it finishes.
struct ScreenRecordingResult: Sendable, Codable, Identifiable {
    var id: String { url.absoluteString }
    var finishedAt: Date = Date()
    let url: URL
    let duration: Int
    let fileSize: Int64
    let qualityTitle: String
    let succeeded: Bool
    let message: String
}

/// Small, asynchronously decoded covers; retain a bounded cache while browsing history.
@MainActor
enum RecordingThumbnail {
    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 100
        return cache
    }()

    static func remove(at url: URL) { cache.removeObject(forKey: url as NSURL) }

    static func firstFrame(at url: URL) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let image = cache.object(forKey: url as NSURL) { return image }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 312, height: 204)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        do {
            let frame = try await generator.image(at: .zero)
            guard !Task.isCancelled else { return nil }
            let image = NSImage(cgImage: frame.image, size: .zero)
            cache.setObject(image, forKey: url as NSURL)
            return image
        } catch {
            return nil
        }
    }
}

final class ScreenRecorderModel: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = ScreenRecorderModel()
    private static let historyKey = "screenRecorder.history.v1"
    struct DisplayOption: Identifiable {
        let id: UInt32
        var title: String {
            NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }?.localizedName ?? L10n.text("显示器")
        }
    }

    @Published private(set) var displays: [DisplayOption] = []
    @Published var selectedDisplayID: UInt32?
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var hasScreenPermission = CGPreflightScreenCaptureAccess()
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var status = "正在读取可录制的显示器…"
    @Published private(set) var outputURL: URL?
    @Published private(set) var lastResult: ScreenRecordingResult?

    @Published private(set) var history: [ScreenRecordingResult] = []
    @Published private(set) var isStopping = false
    private var workingOutputURL: URL?
    private var recordingIndicator: NSPanel?
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var writerStarted = false
    private var startDate: Date?
    private var timer: Timer?
    private let sampleQueue = DispatchQueue(label: "com.laogu.ailock.screen-recorder.samples")
    private var recordingQualityTitle = ""
    // Read and written only on sampleQueue once capture has started.
    private var sessionStartTime: CMTime?
    private var inputsFinished = false
    private var writeFailure: String?

    private let defaults: UserDefaults

    override convenience init() {
        self.init(defaults: .standard)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        super.init()
        refreshDisplays()
        if let data = defaults.data(forKey: Self.historyKey),
           let saved = try? JSONDecoder().decode([ScreenRecordingResult].self, from: data) {
            history = saved
            lastResult = saved.first
        }
    }

    func refreshDisplays() {
        // Listing connected screens does not require capture authorization.
        displays = NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return DisplayOption(id: id)
        }
        if !displays.contains(where: { $0.id == selectedDisplayID }) { selectedDisplayID = displays.first?.id }
        hasScreenPermission = CGPreflightScreenCaptureAccess()
        guard !isRecording, !isStarting, !isStopping, lastResult == nil else { return }
        status = displays.isEmpty ? "没有找到可录制的显示器。" : (hasScreenPermission ? "" : "开始录制时将请求屏幕与系统录音权限。")
    }

    func requestScreenPermission() {
        hasScreenPermission = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        status = hasScreenPermission ? "录屏权限已开启。" : "请在系统设置中允许 AI Lock 的屏幕与系统录音权限，必要时退出后重开。"
        if !hasScreenPermission, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    func identifySelectedDisplay() {
        guard !isRecording, !isStarting, let selectedDisplayID else { return }
        DisplaySelectionIndicator.flash(selectedDisplayID)
    }

    /// A global shortcut must work even when the recorder page is not mounted.
    @MainActor
    func toggleRecording() {
        guard !isStarting, !isStopping else { return }
        if isRecording {
            stopRecording()
        } else {
            let defaults = UserDefaults.standard
            let directory = defaults.string(forKey: "screenRecorder.outputDirectory")
                ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first?.path
                ?? NSHomeDirectory()
            let quality = defaults.string(forKey: "screenRecorder.quality")
                .flatMap(ScreenRecorderQuality.init(rawValue:)) ?? .p1080
            startRecording(in: URL(fileURLWithPath: directory), quality: quality)
        }
    }

    @MainActor
    func startRecording(in directory: URL, quality: ScreenRecorderQuality) {
        guard !isRecording, !isStarting, !isStopping else { return }
        guard let selectedDisplayID,
              displays.contains(where: { $0.id == selectedDisplayID }) else {
            status = "请先选择一个显示器。"
            return
        }
        isStarting = true
        DisplaySelectionIndicator.clear()
        let url = Self.uniqueOutputURL(in: directory)
        Task { @MainActor in await self.startRecording(to: url, displayID: selectedDisplayID, quality: quality) }
    }

    @MainActor
    func stopRecording() {
        requestStop()
    }

    /// Button and shortcut share one serialized finalization path.
    @MainActor
    private func requestStop() {
        guard let stream, !isStopping else { return }
        isStopping = true
        status = "正在保存录屏…"
        timer?.invalidate()
        let duration = elapsedSeconds
        let qualityTitle = recordingQualityTitle
        Task { @MainActor in
            try? await stream.stopCapture()
            recordingIndicator?.orderOut(nil)
            recordingIndicator = nil
            sampleQueue.async {
                self.inputsFinished = true
                let failure = self.writeFailure
                guard let writer = self.writer, self.writerStarted, writer.status == .writing else {
                    self.writer?.cancelWriting()
                    let message = failure ?? self.writer?.error?.localizedDescription ?? "没有收到录屏画面，请检查屏幕录制权限后重试。"
                    Task { @MainActor in
                        await self.completeRecording(duration: duration, qualityTitle: qualityTitle, failure: message)
                    }
                    return
                }
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                writer.finishWriting {
                    let error = writer.status == .completed ? failure : (writer.error?.localizedDescription ?? failure ?? "未知错误")
                    Task { @MainActor in
                        await self.completeRecording(duration: duration, qualityTitle: qualityTitle, failure: error)
                    }
                }
            }
        }
    }

    @MainActor
    private func completeRecording(duration: Int, qualityTitle: String, failure: String?) async {
        guard let target = outputURL, let working = workingOutputURL else {
            finishUI(message: "无法保存录屏：没有输出文件。")
            return
        }
        var errorMessage = failure
        var actualDuration = duration
        if errorMessage == nil {
            do {
                actualDuration = try await Self.validateRecording(at: working)
                try FileManager.default.moveItem(at: working, to: target)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        let succeeded = errorMessage == nil
        if !succeeded { try? FileManager.default.removeItem(at: working) }
        let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
        let message = succeeded ? "录制已保存：\(target.lastPathComponent)" : "无法保存录屏：\(errorMessage ?? "未知错误")"
        let result = ScreenRecordingResult(url: target, duration: actualDuration,
            fileSize: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
            qualityTitle: qualityTitle, succeeded: succeeded, message: message)
        history.insert(result, at: 0)
        history = Array(history.prefix(100))
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: Self.historyKey)
        }
        lastResult = result
        workingOutputURL = nil
        finishUI(message: message)
    }

    /// Read back an actual decoded frame before publishing a completed recording.
    static func validateRecording(at url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard playable, duration.seconds.isFinite, duration.seconds > 0, let track = tracks.first else {
            throw RecorderError.invalidRecording
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        guard reader.canAdd(output) else { throw RecorderError.invalidRecording }
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
              CMSampleBufferGetImageBuffer(sample) != nil else {
            throw reader.error ?? RecorderError.invalidRecording
        }
        reader.cancelReading()
        return max(1, Int(duration.seconds.rounded()))
    }

    /// Failed file removals retain their history entries so the user can retry.
    @MainActor
    func clearHistory(ids: Set<String>, includingFiles: Bool) -> String? {
        var removed = Set<String>()
        var failures: [String] = []
        for result in history where ids.contains(result.id) {
            do {
                if includingFiles, FileManager.default.fileExists(atPath: result.url.path) {
                    try FileManager.default.trashItem(at: result.url, resultingItemURL: nil)
                }
                removed.insert(result.id)
                RecordingThumbnail.remove(at: result.url)
            } catch {
                failures.append("\(result.url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        history.removeAll { removed.contains($0.id) }
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: Self.historyKey)
        }
        if let result = lastResult, removed.contains(result.id) { lastResult = history.first }
        if !isRecording, !isStarting, !isStopping {
            status = lastResult?.message ?? ""
        }
        return failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func selectResult(_ result: ScreenRecordingResult) {
        guard !isRecording, !isStarting, !isStopping else { return }
        lastResult = result
        status = result.message
    }


    @MainActor
    private func startRecording(to url: URL, displayID: UInt32, quality: ScreenRecorderQuality) async {
        defer { isStarting = false }
        hasScreenPermission = CGPreflightScreenCaptureAccess()
        if !hasScreenPermission {
            requestScreenPermission()
            guard hasScreenPermission else { return }
        }
        status = "正在启动录制…"
        outputURL = url
        let workingURL = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).recording.mov")
        workingOutputURL = workingURL
        lastResult = nil
        recordingQualityTitle = quality.title
        elapsedSeconds = 0
        isStopping = false
        sessionStartTime = nil
        inputsFinished = false
        writeFailure = nil
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            let indicator = try makeRecordingIndicator(displayID: displayID)
            recordingIndicator = indicator
            // Register at normal level first: high-level overlay panels may be omitted
            // from ScreenCaptureKit's shareable-window snapshot.
            indicator.orderFrontRegardless()
            indicator.displayIfNeeded()
            let (content, indicatorWindow) = try await Self.contentExcludingIndicator(indicator)
            guard let currentDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RecorderError.displayUnavailable
            }
            let filter = SCContentFilter(display: currentDisplay, excludingWindows: [indicatorWindow])
            // The exclusion follows the window ID when the panel is raised.
            indicator.level = .screenSaver
            let configuration = SCStreamConfiguration()
            let dimensions = quality.dimensions(for: currentDisplay, pixelScale: CGFloat(filter.pointPixelScale))
            configuration.width = dimensions.width
            configuration.height = dimensions.height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 5
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = true
            configuration.capturesAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2

            let width = configuration.width
            let height = configuration.height
            let assetWriter = try AVAssetWriter(outputURL: workingURL, fileType: .mov)
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: (quality == .p720 || quality == .p1080) ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: quality.bitRate]
            ])
            video.expectsMediaDataInRealTime = true
            guard assetWriter.canAdd(video) else { throw RecorderError.writerUnavailable }
            assetWriter.add(video)

            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000
            ])
            audio.expectsMediaDataInRealTime = true
            if assetWriter.canAdd(audio) { assetWriter.add(audio) }

            writer = assetWriter
            videoInput = video
            audioInput = assetWriter.inputs.first(where: { $0.mediaType == .audio })
            writerStarted = false
            let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
            try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            stream = capture
            try await capture.startCapture()
            isRecording = true
            startDate = Date()
            status = "正在录制屏幕与系统声音。"
            timer?.invalidate()
            let clock = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let startDate = self.startDate else { return }
                    self.elapsedSeconds = Int(Date().timeIntervalSince(startDate))
                }
            }
            timer = clock
            RunLoop.main.add(clock, forMode: .common)
        } catch {
            recordingIndicator?.orderOut(nil)
            recordingIndicator = nil
            stream = nil
            writer?.cancelWriting()
            try? FileManager.default.removeItem(at: workingURL)
            workingOutputURL = nil
            writer = nil
            videoInput = nil
            audioInput = nil
            self.outputURL = nil
            hasScreenPermission = CGPreflightScreenCaptureAccess()
            status = "录制未能启动：\(error.localizedDescription)" + (hasScreenPermission ? "" : " 请在系统设置的“隐私与安全性 → 屏幕与系统录音”中允许 AI Lock 后重试。")
        }
    }

    @MainActor
    private func finishUI(message: String) {
        recordingIndicator?.orderOut(nil)
        recordingIndicator = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        isStopping = false
        stream = nil
        writer = nil
        videoInput = nil
        audioInput = nil
        writerStarted = false
        startDate = nil
        status = message
    }

    @MainActor
    private static func contentExcludingIndicator(_ indicator: NSPanel) async throws -> (SCShareableContent, SCWindow) {
        let windowID = CGWindowID(indicator.windowNumber)
        // WindowServer registration and ScreenCaptureKit enumeration are asynchronous.
        // Include offscreen/occluded windows so another window cannot hide the badge
        // from the exclusion list while recording is starting.
        for attempt in 0..<10 {
            try Task.checkCancellation()
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let window = content.windows.first(where: { $0.windowID == windowID }) {
                return (content, window)
            }
            if attempt < 9 { try await Task.sleep(for: .milliseconds(100)) }
        }
        throw RecorderError.indicatorUnavailable
    }

    @MainActor
    private func makeRecordingIndicator(displayID: UInt32) throws -> NSPanel {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { throw RecorderError.displayUnavailable }
        let area = screen.visibleFrame
        let frame = NSRect(x: area.maxX - 148, y: area.maxY - 48, width: 132, height: 32)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .normal
        panel.sharingType = .readOnly
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView:
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 9, height: 9)
                Text(L10n.text("正在录屏")).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(width: 132, height: 32)
            .background(Color.black.opacity(0.82), in: Capsule())
        )
        return panel
    }

    private static func uniqueOutputURL(in directory: URL) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let baseName = L10n.text("录屏") + "-" + formatter.string(from: Date())
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension("mov")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(suffix)").appendingPathExtension("mov")
            suffix += 1
        }
        return candidate
    }

    private enum RecorderError: LocalizedError {
        case displayUnavailable
        case writerUnavailable
        case indicatorUnavailable
        case invalidRecording
        var errorDescription: String? {
            switch self {
            case .displayUnavailable: L10n.text("所选显示器已断开。")
            case .invalidRecording: L10n.text("录屏文件未通过播放验证，请重新录制。")
            case .indicatorUnavailable: L10n.text("无法创建不入镜的录屏标志，请重试。")
            case .writerUnavailable: L10n.text("无法创建视频编码器。")
            }
        }
    }
}

extension ScreenRecorderModel: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid, !inputsFinished, writeFailure == nil else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid else { return }
        switch outputType {
        case .screen:
            // ScreenCaptureKit also sends idle, blank and started status buffers without pixels.
            // Appending those fails the writer and leaves an unfinished .mov that QuickTime rejects.
            guard Self.isCompleteFrame(sampleBuffer) else { return }
            if !writerStarted {
                guard let writer else { return }
                guard writer.startWriting() else {
                    markWriteFailed(writer.error)
                    return
                }
                writer.startSession(atSourceTime: presentationTime)
                sessionStartTime = presentationTime
                writerStarted = true
            }
            guard let videoInput, videoInput.isReadyForMoreMediaData else { return }
            if !videoInput.append(sampleBuffer) { markWriteFailed(writer?.error) }
        case .audio:
            // Audio can arrive before the first complete frame; anything older than the session start is dropped.
            guard writerStarted, let sessionStart = sessionStartTime,
                  CMTimeCompare(presentationTime, sessionStart) >= 0 else { return }
            guard let audioInput, audioInput.isReadyForMoreMediaData else { return }
            if !audioInput.append(sampleBuffer) { markWriteFailed(writer?.error) }
        case .microphone:
            return
        @unknown default:
            return
        }
    }

    /// Runs on sampleQueue. Keeps the first failure and stops capture, so the file is finalized
    /// with a clear message instead of silently dropping every remaining frame.
    private func markWriteFailed(_ error: Error?) {
        guard writeFailure == nil else { return }
        writeFailure = "录制写入失败：\(error?.localizedDescription ?? "未知错误")"
        Task { @MainActor in self.requestStop() }
    }

    /// Only frames with `.complete` status carry an image buffer worth encoding.
    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return false }
        return status == .complete
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard isRecording, !isStopping else { return }
            status = "录制中断：\(error.localizedDescription)"
            stopRecording()
        }
    }
}

/// Brief click-through outline; never activates or moves the application window.
@MainActor
enum DisplaySelectionIndicator {
    private static var panel: NSPanel?
    private static var animation: Task<Void, Never>?
    static func clear() {
        animation?.cancel(); animation = nil
        panel?.orderOut(nil); panel = nil
    }
    static func flash(_ id: CGDirectDisplayID) {
        clear()
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }) else { return }
        let outline = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        outline.isOpaque = false; outline.backgroundColor = .clear
        outline.hasShadow = false; outline.ignoresMouseEvents = true
        outline.level = .screenSaver
        outline.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let border = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        border.wantsLayer = true
        border.layer?.borderWidth = 6
        border.layer?.borderColor = NSColor.systemGreen.cgColor
        outline.contentView = border
        panel = outline
        outline.orderFrontRegardless()
        animation = Task { @MainActor in
            // 20 steps × 250 ms keeps the display outline flashing for 5 seconds.
            for step in 0..<20 {
                guard !Task.isCancelled else { return }
                outline.alphaValue = step % 2 == 0 ? 1 : 0.15
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            clear()
        }
    }
}
