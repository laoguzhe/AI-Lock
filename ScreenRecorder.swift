import AVFoundation
import AppKit
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

enum ScreenRecorderQuality: String, CaseIterable, Identifiable {
    case p720
    case p1080
    case original

    var id: String { rawValue }
    var title: String {
        switch self {
        case .p720: "720p"
        case .p1080: "1080p"
        case .original: L10n.text("原始分辨率")
        }
    }

    func dimensions(for display: SCDisplay) -> (width: Int, height: Int) {
        let maxHeight: CGFloat
        switch self {
        case .p720: maxHeight = 720
        case .p1080: maxHeight = 1080
        case .original: maxHeight = CGFloat(display.height)
        }
        let scale = min(1, maxHeight / CGFloat(display.height))
        let width = max(2, Int((CGFloat(display.width) * scale).rounded()) / 2 * 2)
        let height = max(2, Int((CGFloat(display.height) * scale).rounded()) / 2 * 2)
        return (width, height)
    }

    var bitRate: Int {
        switch self {
        case .p720: 4_000_000
        case .p1080: 8_000_000
        case .original: 24_000_000
        }
    }
}

final class ScreenRecorderModel: NSObject, ObservableObject, @unchecked Sendable {
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

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var writerStarted = false
    private var startDate: Date?
    private var timer: Timer?
    private let sampleQueue = DispatchQueue(label: "com.laogu.ailock.screen-recorder.samples")
    private var isStopping = false

    override init() {
        super.init()
        refreshDisplays()
    }

    func refreshDisplays() {
        // Listing connected screens does not require capture authorization.
        displays = NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return DisplayOption(id: id)
        }
        if !displays.contains(where: { $0.id == selectedDisplayID }) { selectedDisplayID = displays.first?.id }
        hasScreenPermission = CGPreflightScreenCaptureAccess()
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

    func stopRecording() {
        guard let stream, !isStopping else { return }
        isStopping = true
        status = "正在保存录屏…"
        Task { @MainActor in
            do {
                try await stream.stopCapture()
            } catch {
                status = "停止录制时出错：\(error.localizedDescription)"
            }
            sampleQueue.async { [weak self] in
                guard let self else { return }
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                guard let writer = self.writer, self.writerStarted else {
                    if let url = self.outputURL { try? FileManager.default.removeItem(at: url) }
                    Task { @MainActor in self.finishUI(message: "没有收到录屏画面，请检查屏幕录制权限后重试。") }
                    return
                }
                writer.finishWriting {
                    let succeeded = writer.status == .completed
                    let message = succeeded
                        ? "录制已保存：\(self.outputURL?.lastPathComponent ?? "")"
                        : "无法保存录屏：\(writer.error?.localizedDescription ?? "未知错误")"
                    Task { @MainActor in self.finishUI(message: message) }
                }
            }
        }
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
        elapsedSeconds = 0
        isStopping = false
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let currentDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RecorderError.displayUnavailable
            }
            let filter = SCContentFilter(display: currentDisplay, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            let dimensions = quality.dimensions(for: currentDisplay)
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
            let assetWriter = try AVAssetWriter(outputURL: url, fileType: .mov)
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
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
            stream = nil
            writer?.cancelWriting()
            if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
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
        var errorDescription: String? {
            switch self {
            case .displayUnavailable: L10n.text("所选显示器已断开。")
            case .writerUnavailable: L10n.text("无法创建视频编码器。")
            }
        }
    }
}

extension ScreenRecorderModel: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid else { return }
        if !writerStarted {
            guard outputType == .screen else { return }
            guard let writer, writer.startWriting() else { return }
            writer.startSession(atSourceTime: presentationTime)
            writerStarted = true
        }
        switch outputType {
        case .screen:
            if videoInput?.isReadyForMoreMediaData == true { _ = videoInput?.append(sampleBuffer) }
        case .audio:
            if audioInput?.isReadyForMoreMediaData == true { _ = audioInput?.append(sampleBuffer) }
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard isRecording, !isStopping else { return }
            status = "录制中断：\(error.localizedDescription)"
            stopRecording()
        }
    }
}

extension Notification.Name {
    static let screenRecorderShortcut = Notification.Name("AILockScreenRecorderShortcut")
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
            for step in 0..<6 {
                guard !Task.isCancelled else { return }
                outline.alphaValue = step % 2 == 0 ? 1 : 0.15
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            clear()
        }
    }
}
