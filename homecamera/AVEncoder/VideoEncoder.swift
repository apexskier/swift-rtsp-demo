@preconcurrency import AVFoundation
import Foundation

// VideoEncoder: Handles AVAssetWriter setup and frame encoding for H.264 video
final class VideoEncoder: Sendable {
    private let writer: AVAssetWriter
    private let writerInput: AVAssetWriterInput
    let path: String

    // Initialize encoder for a given file path, height, and width
    init?(path: String, height: Int, width: Int) {
        self.path = path
        try? FileManager.default.removeItem(atPath: path)
        let url = URL(fileURLWithPath: path)
        guard let writer = try? AVAssetWriter(url: url, fileType: .mov) else {
            return nil
        }
        self.writer = writer
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: NSNumber(value: width),
            AVVideoHeightKey: NSNumber(value: height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAllowFrameReorderingKey: false
            ],
        ]
        writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        writerInput.expectsMediaDataInRealTime = true
        writer.add(writerInput)
    }

    func finishWithCompletionHandler(_ handler: @Sendable @escaping () -> Void) {
        writer.finishWriting(completionHandler: handler)
    }

    func encodeFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return false }
        if writer.status == .unknown {
            let startTime = sampleBuffer.presentationTimeStamp
            writer.startWriting()
            writer.startSession(atSourceTime: startTime)
        }
        if writer.status == .failed {
            print("writer error \(writer.error?.localizedDescription ?? "unknown")")
            return false
        }
        if writerInput.isReadyForMoreMediaData {
            writerInput.append(sampleBuffer)
            return true
        }
        return false
    }
}
