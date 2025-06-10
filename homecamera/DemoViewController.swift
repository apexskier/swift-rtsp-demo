//
//  EncoderDemoViewController.swift
//  Encoder Demo
//
//  Created by Geraint Davies on 11/01/2013.
//  Copyright (c) 2013 GDCL http://www.gdcl.co.uk/license.htm
//

import SwiftUI
import UIKit
import AVFoundation

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

    public init(session: AVCaptureSession) {
        self.session = session
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
