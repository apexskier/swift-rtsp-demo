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
import UIKit

@Observable
final class CameraServer: NSObject {
    // Singleton instance
    static let shared = CameraServer()

    let pipeline = PassthroughSubject<CMSampleBuffer, Never>()

    var session: AVCaptureSession? = nil
    let deviceDiscovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera,
            // .builtInDualCamera,
            // .builtInDualWideCamera,
            // .builtInTripleCamera,
            .continuityCamera,

            // #if os(macOS)
            // .deskViewCamera,
            // #endif
            .external,
        ],
        mediaType: .video,
        position: .unspecified
    )
    var device = AVCaptureDevice.default(for: .video) {
        didSet {
            guard
                let session,
                let device,
                let input = try? AVCaptureDeviceInput(device: device)
            else { return }
            session.beginConfiguration()
            defer {
                session.commitConfiguration()
            }
            session.inputs.forEach { input in
                session.removeInput(input)
            }
            session.addInput(input)
            setupRotationManager()
        }
    }
    private var rotationManager: AVCaptureDevice.RotationCoordinator? = nil
    private var output: AVCaptureVideoDataOutput? = nil
    private var captureQueue: DispatchQueue? = nil
    private var encoder: AVEncoder? = nil
    var rtsp: RTSPServer? = nil
    private var firstCaptureTimestamp: Date? = nil

    // TODO: observe device discovery changes using KV

    func startup() {
        guard session == nil else { return }

        print("Starting up camera server")

        setupRotationManager()

        // Create capture device with video input
        let session = AVCaptureSession()
        guard let device,
            let rotationManager,
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else { return }
        session.addInput(input)

        // Create an output with self as delegate
        captureQueue = DispatchQueue(label: "\(Bundle.main.bundleIdentifier!).avencoder.capture")
        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: captureQueue)
        output.videoSettings = [
            // TODO: I think this is inefficient since H246 doesn't support it directly and it's converting internally. Saw this in the docs somewhere.
            // I'm doing this now to share memory with a CGContext to draw directly into it
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_32BGRA
        ]
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)

        let dimensions = device.activeFormat.formatDescription.presentationDimensions()
        let height: CGFloat
        let width: CGFloat
        if (Int(rotationManager.videoRotationAngleForHorizonLevelCapture) / 90) % 2 == 1 {
            // portrait
            height = dimensions.width
            width = dimensions.height
        } else {
            // landscape
            height = dimensions.height
            width = dimensions.width
        }

        // Create an encoder
        let encoder = AVEncoder(height: Int(height), width: Int(width))
        encoder.encode { [weak self] data, pts in
            guard let self else { return }
            if let rtsp {
                rtsp.bitrate = encoder.bitspersecond
                rtsp.onVideoData(data, time: pts)
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
        self.output = output
    }

    private var rotationObservation: NSKeyValueObservation? = nil

    private func setupRotationManager() {
        guard let device else { return }
        rotationManager = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationObservation = rotationManager?
            .observe(\.videoRotationAngleForHorizonLevelCapture, options: .new) {
                [weak self] obj, change in
                guard let self,
                    let encoder,
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
        self.output = nil
        self.captureQueue = nil
    }

    func getURL() -> String? {
        guard let rtsp else { return nil }
        return "rtsp://\(RTSPServer.getIPAddress() ?? "0.0.0.0"):\(rtsp.port)/"
    }
}

extension CameraServer: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if firstCaptureTimestamp == nil {
            firstCaptureTimestamp = .init(timeIntervalSinceNow: -CACurrentMediaTime())
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let originalWidth = CVPixelBufferGetWidth(pixelBuffer)
        let originalHeight = CVPixelBufferGetHeight(pixelBuffer)

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

        // Use CIContext with metal for better performance
        CIContext(options: [.useSoftwareRenderer: false])
            .render(
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

        UIGraphicsPushContext(context)
        // TODO: don't recreate, doing this because of concurrency warnings
        let font = UIFont.systemFont(ofSize: 36)
        let fontAttributes = [
            NSAttributedString.Key.font: font,
            NSAttributedString.Key.foregroundColor: UIColor.white,
            NSAttributedString.Key.backgroundColor: UIColor.black,
        ]
        let timestamp = sampleBuffer.presentationTimeStamp
        let d = Date(timeInterval: timestamp.seconds, since: firstCaptureTimestamp!)
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

        encoder?.encode(frame: newSampleBuffer)
    }
}
