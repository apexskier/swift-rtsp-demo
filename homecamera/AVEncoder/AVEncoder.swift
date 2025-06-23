import AVFoundation
import Foundation

final class AVEncoder {
    private var audioBlock: ((Data, Double) -> Void)?

    let videoEncoder: VideoEncoder?
    private let aacEncoder: AACEncoder?

    init(height: Int, width: Int, audioChannels: Int) {
        aacEncoder = AACEncoder(inputChannels: UInt32(audioChannels))
        videoEncoder = VideoEncoder(height: height, width: width)
    }

    func setup(
        videoBlock: @escaping EncoderHandler,
        audioBlock: @escaping (Data, Double) -> Void,
        onParams paramsHandler: @escaping ParamHandler,
        outputSampleBuffer: ((CMSampleBuffer) -> Void)?
    ) {
        self.audioBlock = audioBlock
        self.videoEncoder?
            .setup(
                withBlock: videoBlock,
                onParams: paramsHandler,
                outputSampleBuffer: outputSampleBuffer
            )
    }

    func encodeAudio(frame sampleBuffer: CMSampleBuffer) {
        if let result = aacEncoder?.encode(pcmBuffer: sampleBuffer) {
            self.audioBlock?(result.data, CMTimeGetSeconds(result.pts))
        }
    }

    func encodeVideo(frame sampleBuffer: CMSampleBuffer) {
        videoEncoder?.encodeVideo(frame: sampleBuffer)
    }

    func shutdown() {
        videoEncoder?.shutdown()
    }
}
