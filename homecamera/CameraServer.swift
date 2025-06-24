//
//  CameraServer.swift
//  Encoder Demo
//
//  Created by Geraint Davies on 19/02/2013.
//  Copyright (c) 2013 GDCL http://www.gdcl.co.uk/license.htm
//

import AVFoundation
import Combine
import Foundation

#if canImport(UIKit)
import UIKit
#else
import CoreImage
#endif

@Observable
final class CameraServer: NSObject {
    // Singleton instance
    static let shared = CameraServer()

    let pipeline = PassthroughSubject<CMSampleBuffer, Never>()

    var session: AVCaptureSession? = nil
    let audioDeviceDiscovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [
            .microphone,
            .external,
        ],
        mediaType: .audio,
        position: .unspecified
    )
    var audioDevice: AVCaptureDevice? = deviceFromDefaults(
        forKey: "selectedAudioDeviceID",
        mediaType: .audio
    )
    {
        didSet {
            CameraServer.persistDevice(audioDevice, forKey: "selectedAudioDeviceID")
            replaceInput(oldValue: oldValue, newValue: audioDevice)
        }
    }
    #if os(macOS)
    let videoDeviceDiscovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [
            .microphone,
            .builtInWideAngleCamera,
            .continuityCamera,
            .deskViewCamera,
            .external,
        ],
        mediaType: .video,
        position: .unspecified
    )
    #else
    let videoDeviceDiscovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [
            .microphone,
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera,
            // ignore these cameras as they duplicate the more specific ones above
            // .builtInDualCamera,
            // .builtInDualWideCamera,
            // .builtInTripleCamera,
            .continuityCamera,
            .external,
        ],
        mediaType: .video,
        position: .unspecified
    )
    #endif
    var videoDevice: AVCaptureDevice? = deviceFromDefaults(
        forKey: "selectedVideoDeviceID",
        mediaType: .video
    )
    {
        didSet {
            CameraServer.persistDevice(videoDevice, forKey: "selectedVideoDeviceID")
            replaceInput(oldValue: oldValue, newValue: videoDevice)
        }
    }
    private var rotationManager: AVCaptureDevice.RotationCoordinator? = nil
    private var videoOutput: AVCaptureVideoDataOutput? = nil
    private var captureQueue: DispatchQueue? = nil
    private var audioEncoder: AACEncoder? = nil
    private var videoEncoder: VideoEncoder? = nil
    var rtsp: RTSPServer? = nil

    // Use CIContext with metal for better performance
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    
    private let audioSampleRate: Int = 44100

    private static func deviceFromDefaults(
        forKey key: String,
        mediaType: AVMediaType
    ) -> AVCaptureDevice? {
        if let id = UserDefaults.standard.string(forKey: key),
            let device = AVCaptureDevice(uniqueID: id)
        {
            return device
        }
        return .default(for: mediaType)
    }

    private static func persistDevice(_ device: AVCaptureDevice?, forKey key: String) {
        if let device {
            UserDefaults.standard.set(device.uniqueID, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func replaceInput(
        oldValue oldDevice: AVCaptureDevice?,
        newValue newDevice: AVCaptureDevice?
    ) {
        guard let session else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let oldDevice {
            for input in session.inputs {
                if let deviceInput = input as? AVCaptureDeviceInput,
                    deviceInput.device.uniqueID == oldDevice.uniqueID
                {
                    session.removeInput(deviceInput)
                }
            }
        }
        if let newDevice, let newInput = try? AVCaptureDeviceInput(device: newDevice) {
            session.addInput(newInput)
        }
    }

    // TODO: observe device discovery changes using KV

    func startup() {
        guard session == nil else { return }

        print("Starting up camera server")

        setupRotationManager()

        // Create capture device with video input
        let session = AVCaptureSession()
        guard let videoDevice,
            let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
            session.canAddInput(videoInput)
        else { return }
        session.addInput(videoInput)

        if let audioDevice,
            let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
            session.canAddInput(audioInput)
        {
            session.addInput(audioInput)
        }

        // Create an output with self as delegate
        captureQueue = DispatchQueue(label: "\(Bundle.main.bundleIdentifier!).CameraServer.capture")
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
        videoOutput.videoSettings = [
            // TODO: I think this is inefficient since H264 doesn't support it directly and it's converting internally. Saw this in the docs somewhere.
            // I'm doing this now to share memory with a CGContext to draw directly into it
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_32BGRA
        ]
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            self.videoOutput = videoOutput
        }

        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }

        // TODO: update channels if audio input changes
        guard let channels = audioOutput.connection(with: .audio)?.audioChannels.count else {
            print("No audio channels found")
            return
        }

        let dimensions = videoDevice.activeFormat.formatDescription.presentationDimensions()
        let height: CGFloat
        let width: CGFloat
        if (Int(rotationManager?.videoRotationAngleForHorizonLevelCapture ?? 0) / 90) % 2 == 1 {
            // portrait
            height = dimensions.width
            width = dimensions.height
        } else {
            // landscape
            height = dimensions.height
            width = dimensions.width
        }

        self.audioEncoder = AACEncoder(sampleRate: audioSampleRate, inputChannels: UInt32(channels))

        let videoEncoder = VideoEncoder(height: Int(height), width: Int(width))
        videoEncoder.setup { [weak self] data, pts in
            guard let self else { return }
            if let rtsp {
                rtsp.bitrate = videoEncoder.bitspersecond
                rtsp.onVideoData(data, time: pts)
            }
        } onParams: { [weak self] data in
            guard let self else { return }
            rtsp = RTSPServer(configData: data, audioSampleRate: audioSampleRate)
        } outputSampleBuffer: { [weak self] buffer in
            guard let self else { return }
            pipeline.send(buffer)
        }
        self.videoEncoder = videoEncoder

        // Start capture
        session.startRunning()

        self.session = session
    }

    private var rotationObservation: NSKeyValueObservation? = nil

    private func setupRotationManager() {
        guard let videoDevice else { return }
        rotationManager = AVCaptureDevice.RotationCoordinator(
            device: videoDevice,
            previewLayer: nil
        )
        rotationObservation = rotationManager?
            .observe(\.videoRotationAngleForHorizonLevelCapture, options: .new) {
                [weak self] obj, change in
                guard
                    let encoder = self?.videoEncoder,
                    let device = obj.device,
                    let v = change.newValue
                else {
                    return
                }
                let dimensions = device.activeFormat.formatDescription.presentationDimensions()
                if (Int(v) / 90) % 2 == 1 {
                    // portrait
                    encoder.size = CGSize(
                        width: dimensions.height,
                        height: dimensions.width
                    )
                } else {
                    // landscape
                    encoder.size = dimensions
                }

                self?.rtsp?.announce()
            }
    }

    func shutdown() {
        print("Shutting down camera server")
        session?.stopRunning()
        self.session = nil
        rtsp?.shutdownServer()
        self.rtsp = nil
        videoEncoder?.shutdown()
        self.videoEncoder = nil
        self.videoOutput = nil
        self.captureQueue = nil
    }

    func getURL() -> String? {
        guard let rtsp else { return nil }
        return "rtsp://\(RTSPServer.getIPAddress() ?? "0.0.0.0"):\(rtsp.port)/"
    }
}

extension CameraServer: AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate
{
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
            if let rtsp, let audioData = audioEncoder?.encode(blockBuffer: blockBuffer) {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                rtsp.onAudioData(audioData, pts: CMTimeGetSeconds(pts))
            }
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let originalWidth = CVPixelBufferGetWidth(pixelBuffer)
        let originalHeight = CVPixelBufferGetHeight(pixelBuffer)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))

        // Calculate rotated dimensions
        let degrees = rotationManager?.videoRotationAngleForHorizonLevelCapture ?? 0
        let normalizedDegrees = Int(degrees) % 360
        let (width, height): (Int, Int)
        switch normalizedDegrees {
        case 90, 270:
            // 90° and 270° rotations swap dimensions
            width = originalHeight
            height = originalWidth
        default:
            // 180° rotation keeps same dimensions
            // TODO: don't rotate if it's already at 0°
            // 0° or other angles keeps same dimensions
            width = originalWidth
            height = originalHeight
        }

        let rotatedImage: CIImage
        switch normalizedDegrees {
        case 90:
            rotatedImage = ciImage.oriented(.right)
        case 180:
            rotatedImage = ciImage.oriented(.down)
        case 270:
            rotatedImage = ciImage.oriented(.left)
        default:
            rotatedImage = ciImage.oriented(.up)
        }

        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var outputBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes as CFDictionary,
            &outputBuffer
        )
        guard status == kCVReturnSuccess, let outputBuffer else { return }
        CVPixelBufferLockBaseAddress(outputBuffer, CVPixelBufferLockFlags(rawValue: 0))

        ciContext.render(
            rotatedImage,
            to: outputBuffer,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        guard let baseAddress = CVPixelBufferGetBaseAddress(outputBuffer) else {
            CVPixelBufferUnlockBaseAddress(outputBuffer, CVPixelBufferLockFlags(rawValue: 0))
            return
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(outputBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // For kCVPixelFormatType_32BGRA
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
        guard
            let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            )
        else {
            CVPixelBufferUnlockBaseAddress(outputBuffer, CVPixelBufferLockFlags(rawValue: 0))
            return
        }

        #if canImport(UIKit)
        UIGraphicsPushContext(context)
        // TODO: don't recreate, doing this because of concurrency warnings
        let font = UIFont.systemFont(ofSize: 36)
        let fontAttributes = [
            NSAttributedString.Key.font: font,
            NSAttributedString.Key.foregroundColor: UIColor.white,
            NSAttributedString.Key.backgroundColor: UIColor.black,
        ]
        let d = Date(
            timeInterval: sampleBuffer.presentationTimeStamp.seconds,
            since: .init(timeIntervalSinceNow: -CACurrentMediaTime())
        )
        let string = NSAttributedString(
            string: d.formatted(date: .abbreviated, time: .standard),
            attributes: fontAttributes
        )
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        string.draw(at: CGPoint(x: 20, y: 20))

        context.restoreGState()
        UIGraphicsPopContext()
        #endif

        var timingInfo = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timingInfo)

        var videoFormat: CMFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: outputBuffer,
            formatDescriptionOut: &videoFormat
        )
        guard formatStatus == noErr, let videoFormat else { return }

        var newSampleBuffer: CMSampleBuffer?
        let bufferStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: outputBuffer,
            formatDescription: videoFormat,
            sampleTiming: &timingInfo,
            sampleBufferOut: &newSampleBuffer
        )
        guard bufferStatus == noErr, let newSampleBuffer else { return }

        CVPixelBufferUnlockBaseAddress(outputBuffer, CVPixelBufferLockFlags(rawValue: 0))

        videoEncoder?.encodeVideo(frame: newSampleBuffer)
    }
}
