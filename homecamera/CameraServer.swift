//
//  CameraServer.swift
//  Encoder Demo
//
//  Created by Geraint Davies on 19/02/2013.
//  Copyright (c) 2013 GDCL http://www.gdcl.co.uk/license.htm
//

import AVFoundation
import Foundation
import SwiftUI

let font = UIFont.systemFont(ofSize: 36)
let fontAttributes = [
    NSAttributedString.Key.font: font,
    NSAttributedString.Key.foregroundColor: UIColor.white,
    NSAttributedString.Key.backgroundColor: UIColor.black,
]

@Observable
final class CameraServer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    // Singleton instance
    static let shared = CameraServer()

    // MARK: - Properties

    var session: AVCaptureSession? = nil
    let deviceDiscovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera,
            .builtInDualCamera,
            .builtInDualWideCamera,
            .builtInTripleCamera,
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
        }
    }
    private var output: AVCaptureVideoDataOutput? = nil
    private var captureQueue: DispatchQueue? = nil
    private var encoder: AVEncoder? = nil
    private var rtsp: RTSPServer? = nil
    private var firstCaptureTimestamp: Date? = nil

    // TODO: observe device discovery changes using KV

    // MARK: - Startup

    func startup() {
        guard session == nil else { return }

        print("Starting up server")

        // Create capture device with video input
        let session = AVCaptureSession()
        guard let dev = device,
            let input = try? AVCaptureDeviceInput(device: dev),
            session.canAddInput(input)
        else { return }
        session.addInput(input)

        // Create an output for YUV output with self as delegate
        captureQueue = DispatchQueue(label: "\(Bundle.main.bundleIdentifier!).avencoder.capture")
        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: captureQueue)
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_32BGRA
        ]
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)

        // Create an encoder
        let encoder = AVEncoder(height: 480, width: 720)
        encoder.encode { [weak self] data, pts in
            guard let self else { return }
            if let rtsp {
                rtsp.bitrate = encoder.bitspersecond
                rtsp.onVideoData(data, time: pts)
            }
        } onParams: { [weak self] data in
            guard let self else { return }
            self.rtsp = RTSPServer(configData: data)
        }

        self.encoder = encoder

        // Start capture
        session.startRunning()

        self.session = session
        self.output = output
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

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
        CVPixelBufferLockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
            return
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
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
            CVPixelBufferUnlockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
            return
        }

        UIGraphicsPushContext(context)
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

        CVPixelBufferUnlockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))

        encoder?.encode(frame: sampleBuffer)
    }

    // MARK: - Shutdown

    func shutdown() {
        print("shutting down server")
        session?.stopRunning()
        self.session = nil
        rtsp?.shutdownServer()
        self.rtsp = nil
        encoder?.shutdown()
        self.encoder = nil
        self.output = nil
        self.captureQueue = nil
    }

    // MARK: - Utilities

    func getURL() -> String? {
        guard let rtsp else { return nil }
        return "rtsp://\(RTSPServer.getIPAddress() ?? "0.0.0.0"):\(rtsp.port)/"
    }
}

struct CameraPreview: UIViewRepresentable {
    class VideoPreviewView: UIView {
        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }

        var videoPreviewLayer: AVCaptureVideoPreviewLayer? {
            layer as? AVCaptureVideoPreviewLayer
        }
    }

    let session: AVCaptureSession?

    var view: VideoPreviewView = {
        let view = VideoPreviewView()
        view.backgroundColor = .black
        view.videoPreviewLayer?.videoGravity = .resizeAspectFill
        return view
    }()

    func makeUIView(context: Context) -> VideoPreviewView {
        self.view.videoPreviewLayer?.session = self.session
        return self.view
    }

    func updateUIView(_ uiView: VideoPreviewView, context: Context) {}
}
