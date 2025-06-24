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
    var audioDevice: AVCaptureDevice? {
        get {
            if let id = UserDefaults.standard.string(forKey: "selectedAudioDeviceID"),
                let device = AVCaptureDevice(uniqueID: id)
            {
                return device
            }
            return AVCaptureDevice.default(for: .audio)
        }
        set {
            guard let newValue else { return }
            UserDefaults.standard.set(newValue.uniqueID, forKey: "selectedAudioDeviceID")
            guard
                let session,
                let input = try? AVCaptureDeviceInput(device: newValue)
            else { return }
            session.beginConfiguration()
            defer {
                session.commitConfiguration()
            }
            session.inputs.forEach {
                session.removeInput($0)
            }
            session.addInput(input)
            if let videoDevice,
                let videoInput = try? AVCaptureDeviceInput(device: videoDevice)
            {
                session.addInput(videoInput)
            }
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
    var videoDevice: AVCaptureDevice? {
        get {
            if let id = UserDefaults.standard.string(forKey: "selectedVideoDeviceID"),
                let device = AVCaptureDevice(uniqueID: id)
            {
                return device
            }
            return AVCaptureDevice.default(for: .video)
        }
        set {
            guard let newValue else { return }
            UserDefaults.standard.set(newValue.uniqueID, forKey: "selectedVideoDeviceID")
            guard
                let session,
                let input = try? AVCaptureDeviceInput(device: newValue)
            else { return }
            session.beginConfiguration()
            defer {
                session.commitConfiguration()
            }
            session.inputs.forEach {
                session.removeInput($0)
            }
            session.addInput(input)
            if let audioDevice,
                let audioInput = try? AVCaptureDeviceInput(device: audioDevice)
            {
                session.addInput(audioInput)
            }
            setupRotationManager()
        }
    }
    private var rotationManager: AVCaptureDevice.RotationCoordinator? = nil
    private var videoOutput: AVCaptureVideoDataOutput? = nil
    private var captureQueue: DispatchQueue? = nil
    private var encoder: AVEncoder? = nil
    var rtsp: RTSPServer? = nil

    // Use CIContext with metal for better performance
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

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

        // Create an encoder
        let encoder = AVEncoder(height: Int(height), width: Int(width), audioChannels: channels)
        encoder.setup { [weak self] data, pts in
            guard let self else { return }
            if let rtsp, let bitrate = encoder.videoEncoder?.bitspersecond {
                rtsp.bitrate = bitrate
                rtsp.onVideoData(data, time: pts)
            }
        } audioBlock: { [weak self] (data, pts) in
            guard let self else { return }
            if let rtsp {
                rtsp.onAudioData(data, pts: pts)
            }
        } onParams: { [weak self] data in
            guard let self else { return }
            rtsp = RTSPServer(configData: data)
        } outputSampleBuffer: { [weak self] buffer in
            guard let self else { return }
            pipeline.send(buffer)
        }

        self.encoder = encoder

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
                    let encoder = self?.encoder?.videoEncoder,
                    let device = obj.device,
                    let v = change.newValue
                else {
                    return
                }
                let dimensions = device.activeFormat.formatDescription.presentationDimensions()
                if (Int(v) / 90) % 2 == 1 {
                    // portrait
                    encoder.height = Int(dimensions.width)
                    encoder.width = Int(dimensions.height)
                } else {
                    // landscape
                    encoder.height = Int(dimensions.height)
                    encoder.width = Int(dimensions.width)
                }
            }
    }

    func shutdown() {
        print("Shutting down camera server")
        session?.stopRunning()
        self.session = nil
        rtsp?.shutdownServer()
        self.rtsp = nil
        encoder?.shutdown()
        self.encoder = nil
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
            encoder?.encodeAudio(frame: sampleBuffer)
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let originalWidth = CVPixelBufferGetWidth(pixelBuffer)
        let originalHeight = CVPixelBufferGetHeight(pixelBuffer)

        // TODO: use RTSP ANNOUNCE to change dimensions on rotation?
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

        // Create pixel buffer with proper attributes
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
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
        CVPixelBufferUnlockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))

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

        encoder?.encodeVideo(frame: newSampleBuffer)
    }
}
