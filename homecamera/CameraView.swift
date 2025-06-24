//
//  CameraView.swift
//  homecamera
//
//  Created by Cameron Little on 2025-06-20.
//

import SwiftUI
import AVFoundation
import Combine

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

    func makeUIView(context: Context) -> VideoPreviewView {
        let view = VideoPreviewView()
        view.videoPreviewLayer?.videoGravity = .resizeAspect
        view.videoPreviewLayer?.session = session
        return view
    }

    func updateUIView(_ view: VideoPreviewView, context: Context) {}
}

struct CameraPreview2: UIViewRepresentable {
    class VideoPreviewView: UIView {
        override class var layerClass: AnyClass {
            AVSampleBufferDisplayLayer.self
        }

        private var cancellable: AnyCancellable?

        @MainActor
        var sampleBufferLayer: AVSampleBufferDisplayLayer? {
            layer as? AVSampleBufferDisplayLayer
        }

        func setup(pipeline: PassthroughSubject<CMSampleBuffer, Never>) {
            cancellable?.cancel()
            cancellable = pipeline.receive(on: RunLoop.main)
                .sink { buffer in
                    self.sampleBufferLayer?.sampleBufferRenderer.enqueue(buffer)
                }
        }
    }

    let pipeline: PassthroughSubject<CMSampleBuffer, Never>

    func makeUIView(context: Context) -> VideoPreviewView {
        let view = VideoPreviewView()
        view.setup(pipeline: pipeline)
        view.sampleBufferLayer?.preventsDisplaySleepDuringVideoPlayback = true
        view.backgroundColor = .gray
        return view
    }

    func updateUIView(_ view: VideoPreviewView, context: Context) {
        view.setup(pipeline: pipeline)
    }
}
