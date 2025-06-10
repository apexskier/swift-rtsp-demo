
import Foundation
import AVFoundation

final class VideoEncoder: NSObject {
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    var path: String = ""

    // MARK: - Factory
    static func encoder(forPath path: String, height: Int, width: Int) -> VideoEncoder {
        let enc = VideoEncoder()
        enc.initPath(path: path, height: height, width: width)
        return enc
    }

    // MARK: - Initializer
    func initPath(path: String, height: Int, width: Int) {
        self.path = path

        try? FileManager.default.removeItem(atPath: self.path)
        let url = URL(fileURLWithPath: self.path)

        do {
            writer = try AVAssetWriter(url: url, fileType: .mov)
        } catch {
            print("Error creating AVAssetWriter: \(error)")
            return
        }

        let compressionProperties: [String: Any] = [
            AVVideoAllowFrameReorderingKey: true
        ]
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]

        writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        writerInput?.expectsMediaDataInRealTime = true

        if let writer = writer, let writerInput = writerInput, writer.canAdd(writerInput) {
            writer.add(writerInput)
        } else {
            print("VideoEncoder: Cannot add input to writer.")
        }
    }

    // MARK: - Finish
    func finish(completionHandler handler: @escaping () -> Void) {
        writer?.finishWriting(completionHandler: handler)
    }

    // MARK: - Encode Frame
    func encodeFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return false }
        guard let writer = writer, let writerInput = writerInput else { return false }

        if writer.status == .unknown {
            let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startWriting()
            writer.startSession(atSourceTime: startTime)
        }
        if writer.status == .failed {
            print("writer error \(writer.error?.localizedDescription ?? "Unknown error")")
            return false
        }
        if writerInput.isReadyForMoreMediaData {
            return writerInput.append(sampleBuffer)
        }
        return false
    }
}
