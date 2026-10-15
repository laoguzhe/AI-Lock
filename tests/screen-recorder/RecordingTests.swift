import AVFoundation
import AppKit

// Keep this focused executable independent of the rest of the application's UI.
enum L10n { static func text(_ value: String) -> String { value } }

@main
struct RecordingTests {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for codec in [AVVideoCodecType.h264, .hevc] {
            let url = directory.appendingPathComponent("\(codec.rawValue).mov")
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: codec, AVVideoWidthKey: 320, AVVideoHeightKey: 180
            ])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
                sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
            precondition(writer.canAdd(video))
            writer.add(video)
            precondition(writer.startWriting())
            writer.startSession(atSourceTime: .zero)
            for frame in 0..<30 {
                var retries = 0
                while !video.isReadyForMoreMediaData && retries < 500 {
                    try await Task.sleep(for: .milliseconds(10))
                    retries += 1
                }
                precondition(video.isReadyForMoreMediaData)
                var buffer: CVPixelBuffer?
                precondition(CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer) == kCVReturnSuccess)
                CVPixelBufferLockBaseAddress(buffer!, [])
                memset(CVPixelBufferGetBaseAddress(buffer!), Int32(frame * 7), CVPixelBufferGetDataSize(buffer!))
                CVPixelBufferUnlockBaseAddress(buffer!, [])
                precondition(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
            }
            video.markAsFinished()
            await writer.finishWriting()
            precondition(writer.status == .completed, "writer failed: \(String(describing: writer.error))")
            let duration = try await ScreenRecorderModel.validateRecording(at: url)
            precondition(duration >= 1)
            print("PASS: \(codec.rawValue) MOV finalized and decoded by AVFoundation")
            let result = ScreenRecordingResult(url: url, duration: duration, fileSize: 123,
                qualityTitle: "1080p", succeeded: true, message: "saved")
            let restored = try JSONDecoder().decode([ScreenRecordingResult].self, from: JSONEncoder().encode([result]))
            precondition(restored.first?.url == url && restored.first?.succeeded == true)
            precondition(restored.first?.finishedAt == result.finishedAt)
            print("PASS: history preserves result, location and completion date")
        }
        for name in ["empty.mov", "truncated.mov"] {
            let url = directory.appendingPathComponent(name)
            try (name == "empty.mov" ? Data() : Data("invalid movie".utf8)).write(to: url)
            do {
                _ = try await ScreenRecorderModel.validateRecording(at: url)
                fatalError("invalid recording incorrectly accepted")
            } catch { print("PASS: \(name) rejected before publishing success") }
        }
    }
}
