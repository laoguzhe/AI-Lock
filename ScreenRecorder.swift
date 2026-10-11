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
        let display: SCDisplay
        var id: UInt32 { display.displayID }
        var title: String { "显示器 \(id) · \(display.width) × \(display.height)" }
    }

    @Published private(set) var displays: [DisplayOption] = []
    @Published var selectedDisplayID: UInt32?
    @Published private(set) var isRecording = false
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
        status = "正在读取可录制的显示器…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let options = content.displays.map(DisplayOption.init(display:))
                displays = options
                if !options.contains(where: { $0.id == self.selectedDisplayID }) {
                    selectedDisplayID = options.first?.id
                }
                status = options.isEmpty ? "没有找到可录制的显示器。" : "就绪。录制前请选择保存位置。"
            } catch {
                displays = []
                status = "无法读取显示器：\(error.localizedDescription)"
            }
        }
    }

    func chooseOutputAndStart(quality: ScreenRecorderQuality) {
        guard let selectedDisplayID,
              displays.contains(where: { $0.id == selectedDisplayID }) else {
            status = "请先选择一个显示器。"
            return
        }
        let panel = NSSavePanel()
        panel.title = L10n.text("保存录屏")
        panel.nameFieldStringValue = "录屏-\(Self.fileTimestamp()).mov"
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
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

    private func startRecording(to url: URL, displayID: UInt32, quality: ScreenRecorderQuality) async {
        guard let display = displays.first(where: { $0.id == displayID })?.display else { return }
        status = "正在启动录制…"
        outputURL = url
        elapsedSeconds = 0
        isStopping = false
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let currentDisplay = content.displays.first(where: { $0.displayID == display.displayID }) else {
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
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let startDate = self.startDate else { return }
                    self.elapsedSeconds = Int(Date().timeIntervalSince(startDate))
                }
            }
        } catch {
            stream = nil
            writer?.cancelWriting()
            if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
            writer = nil
            videoInput = nil
            audioInput = nil
            self.outputURL = nil
            status = "录制未能启动：\(error.localizedDescription) 请在系统设置的“隐私与安全性 → 屏幕与系统录音”中允许 AI Lock 后重试。"
        }
    }

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

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private enum RecorderError: LocalizedError {
        case displayUnavailable
        case writerUnavailable
        var errorDescription: String? {
            switch self {
            case .displayUnavailable: "所选显示器已断开。"
            case .writerUnavailable: "无法创建视频编码器。"
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

struct ScreenRecorderView: View {
    @StateObject private var model = ScreenRecorderModel()
    @AppStorage("screenRecorder.quality") private var qualityRawValue = ScreenRecorderQuality.p1080.rawValue

    private var quality: ScreenRecorderQuality {
        ScreenRecorderQuality(rawValue: qualityRawValue) ?? .p1080
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "record.circle").font(.system(size: 32)).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("录屏工具")).font(.title2.weight(.semibold))
                    Text(L10n.text("录制显示器画面和系统声音，并保存为 QuickTime 视频。"))
                        .font(.callout).foregroundStyle(.secondary)
                    Text(L10n.text("快捷键：⌘⇧R 开始或停止录制"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            GroupBox(L10n.text("录制来源")) {
                HStack {
                    Picker(L10n.text("显示器"), selection: $model.selectedDisplayID) {
                        ForEach(model.displays) { option in
                            Text(option.title).tag(Optional(option.id))
                        }
                    }
                    .disabled(model.isRecording || model.displays.isEmpty)
                    Button { model.refreshDisplays() } label: { Image(systemName: "arrow.clockwise") }
                        .help(L10n.text("刷新显示器列表"))
                        .disabled(model.isRecording)
                }.padding(.top, 4)
            }

            GroupBox(L10n.text("录制清晰度")) {
                Picker(L10n.text("清晰度"), selection: $qualityRawValue) {
                    ForEach(ScreenRecorderQuality.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .disabled(model.isRecording)
                .padding(.top, 4)
            }

            HStack(spacing: 14) {
                if model.isRecording {
                    Circle().fill(.red).frame(width: 9, height: 9)
                    Text("\(L10n.text("录制中"))  \(duration(model.elapsedSeconds))")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                    Spacer()
                    Button(role: .destructive) { model.stopRecording() } label: {
                        Label(L10n.text("停止并保存"), systemImage: "stop.fill")
                    }.keyboardShortcut(.return, modifiers: [.command])
                } else {
                    Button { model.chooseOutputAndStart(quality: quality) } label: {
                        Label(L10n.text("开始录制"), systemImage: "record.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.displays.isEmpty)
                    Spacer()
                }
            }

            Text(model.status)
                .font(.callout)
                .foregroundStyle(model.status.contains("未能") || model.status.contains("中断") ? Color.red : Color.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)

            if let url = model.outputURL, !model.isRecording {
                HStack {
                    Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(L10n.text("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 360)
        .onReceive(NotificationCenter.default.publisher(for: .screenRecorderShortcut)) { _ in
            if model.isRecording { model.stopRecording() }
            else { model.chooseOutputAndStart(quality: quality) }
        }
    }

    private func duration(_ seconds: Int) -> String {
        String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}

extension Notification.Name {
    static let screenRecorderShortcut = Notification.Name("AILockScreenRecorderShortcut")
}
