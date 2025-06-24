//
//  AudioEncoder.swift
//  homecamera
//
//  Created by Cameron Little on 2025-06-20.
//

import AudioToolbox
import CoreMedia

// AAC frame size
private let frameCount = 1024

class AACEncoder {
    private let converter: AudioConverterRef
    private let inputFormat: AudioStreamBasicDescription
    private let outputFormat: AudioStreamBasicDescription

    private var pcmBuffer = Data()
    private var bytesPerFrame: Int

    init?(sampleRate: Int, inputChannels: UInt32) {
        // Input PCM format (from AVCaptureAudioDataOutput)
        var inputFormat = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: inputChannels * 2,  // 2 bytes per 16-bit sample
            mFramesPerPacket: 1,
            mBytesPerFrame: inputChannels * 2,
            mChannelsPerFrame: inputChannels,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        // Output AAC format
        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: AudioFormatFlags(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0,  // Variable bitrate
            mFramesPerPacket: UInt32(frameCount),
            mBytesPerFrame: 0,
            mChannelsPerFrame: inputChannels,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        bytesPerFrame = Int(inputChannels * 2)

        var converter: AudioConverterRef?
        AudioConverterNew(&inputFormat, &outputFormat, &converter)
        guard let converter else {
            return nil
        }

        self.converter = converter
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
    }

    func encode(blockBuffer: CMBlockBuffer) -> Data? {
        // Append new PCM data to our internal buffer
        try? blockBuffer.withUnsafeMutableBytes { ptr in
            guard let data = ptr.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            pcmBuffer.append(data, count: ptr.count)
        }

        // Check if we have enough for all frames
        let requiredBytes = frameCount * bytesPerFrame
        guard pcmBuffer.count >= requiredBytes else {
            // Not enough data yet
            return nil
        }
       
        // Prepare input buffer for frames
        var inputData = pcmBuffer.prefix(requiredBytes)
        // Remove used data from buffer
        pcmBuffer.removeFirst(requiredBytes)
       
        // Output buffer
        let outputDataSize = frameCount * 2 * Int(outputFormat.mChannelsPerFrame)
        let outputData = UnsafeMutablePointer<UInt8>.allocate(capacity: outputDataSize)
        defer { outputData.deallocate() }
        var outputBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: outputFormat.mChannelsPerFrame,
                mDataByteSize: UInt32(outputDataSize),
                mData: outputData
            )
        )

        var ioOutputDataPackets: UInt32 = 1
        // Use withUnsafeMutableBytes with return value to ensure the input buffer memory is valid for the duration of the conversion
        return inputData.withUnsafeMutableBytes { inputDataPtr -> Data? in
            guard let baseAddress = inputDataPtr.baseAddress else { return nil }
            var converterContext = ConverterContext(
                inputBufferList: AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: inputFormat.mChannelsPerFrame,
                        mDataByteSize: UInt32(requiredBytes),
                        mData: baseAddress
                    )
                ),
                consumed: false
            )
            guard AudioConverterFillComplexBuffer(
                converter,
                { _, ioNumberDataPackets, ioData, _, inUserData in
                    guard let context = inUserData?.assumingMemoryBound(to: ConverterContext.self)
                    else {
                        return 1
                    }
                    if context.pointee.consumed {
                        ioNumberDataPackets.pointee = 0
                        return noErr
                    }
                    ioData.pointee = context.pointee.inputBufferList
                    ioNumberDataPackets.pointee = UInt32(frameCount)
                    context.pointee.consumed = true
                    return noErr
                },
                &converterContext,
                &ioOutputDataPackets,
                &outputBufferList,
                nil
            ) == noErr else {
                return nil
            }
            return Data(
                bytes: outputData,
                count: Int(outputBufferList.mBuffers.mDataByteSize)
            )
        }
    }

    private struct ConverterContext {
        var inputBufferList: AudioBufferList
        var consumed: Bool
    }

    deinit {
        AudioConverterDispose(converter)
    }
}
