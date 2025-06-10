//
//  CameraServer.swift
//  Encoder Demo
//
//  Created by Geraint Davies on 19/02/2013.
//  Copyright (c) 2013 GDCL http://www.gdcl.co.uk/license.htm
//

import SwiftUI
import Foundation
import AVFoundation

fileprivate final class CameraServer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    // Singleton instance
    static var shared: CameraServer = {
        let s = CameraServer()
        s.startup()
        return s
    }()

    // MARK: - Properties

    var session: AVCaptureSession?
    var preview: AVCaptureVideoPreviewLayer?
    private var output: AVCaptureVideoDataOutput?
    private var captureQueue: DispatchQueue?
    private var encoder: AVEncoder?
    private var rtsp: RTSPServer?

    // MARK: - Startup

    func startup() {
        guard session == nil else { return }

        print("Starting up server")

        // Create capture device with video input
        let session = AVCaptureSession()
        guard let dev = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input)
        else { return }
        session.addInput(input)

        // Create an output for YUV output with self as delegate
        captureQueue = DispatchQueue(label: "uk.co.gdcl.avencoder.capture")
        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: captureQueue)
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)

        // Create an encoder
        guard let encoder = AVEncoder(forHeight: 480, andWidth: 720) else {
            fatalError("Failed to create AVEncoder")
        }
        encoder.encode { [weak self] data, pts in
            guard let self, let data else { return 0 }
            if let rtsp = self.rtsp {
                rtsp.bitrate = Int(encoder.bitspersecond)
                rtsp.onVideoData(data, time: pts)
            }
            return 0
        } onParams: { [weak self] data in
            guard let self, let data else { return 0 }
            self.rtsp = RTSPServer.setupListener(data)
            return 0
        }

        self.encoder = encoder

        // Start capture and a preview layer
        session.startRunning()
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        self.preview = preview

        self.session = session
        self.output = output
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        encoder?.encodeFrame(sampleBuffer)
    }

    // MARK: - Shutdown

    func shutdown() {
        print("shutting down server")
        if let session = session {
            session.stopRunning()
            self.session = nil
        }
        if let rtsp = rtsp {
            rtsp.shutdownServer()
            self.rtsp = nil
        }
        if let encoder = encoder {
            encoder.shutdown()
            self.encoder = nil
        }
        self.preview = nil
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
            return AVCaptureVideoPreviewLayer.self
        }

        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            return layer as! AVCaptureVideoPreviewLayer
        }
    }

    let session: AVCaptureSession

    public init() {
        self.session = CameraServer.shared.session!
    }

    public var view: VideoPreviewView = {
        let view = VideoPreviewView()
        view.backgroundColor = .black
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }()

    public func makeUIView(context: Context) -> VideoPreviewView {
        self.view.videoPreviewLayer.session = self.session
        return self.view
    }

    public func updateUIView(_ uiView: VideoPreviewView, context: Context) { }
}
