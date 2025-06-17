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

@Observable
final class CameraServer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    // Singleton instance
    static let shared = CameraServer()

    // MARK: - Properties

    var session: AVCaptureSession?
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
    private var output: AVCaptureVideoDataOutput?
    private var captureQueue: DispatchQueue?
    private var encoder: AVEncoder?
    private var rtsp: RTSPServer?

    init(
        session: AVCaptureSession? = nil,
        output: AVCaptureVideoDataOutput? = nil,
        captureQueue: DispatchQueue? = nil,
        encoder: AVEncoder? = nil,
        rtsp: RTSPServer? = nil
    ) {
        self.session = session
        self.output = output
        self.captureQueue = captureQueue
        self.encoder = encoder
        self.rtsp = rtsp

        // TODO: observe device discovery changes using KV
    }

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
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
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

    func getURL() -> String {
        "rtsp://\(RTSPServer.getIPAddress() ?? "0.0.0.0")/"
    }
}

public struct CameraPreview: UIViewRepresentable {
    public class VideoPreviewView: UIView {
        public override class var layerClass: AnyClass {
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

    public func makeUIView(context: Context) -> VideoPreviewView {
        self.view.videoPreviewLayer?.session = self.session
        return self.view
    }

    public func updateUIView(_ uiView: VideoPreviewView, context: Context) {
        print("update ui view")
    }
}
