//
//  ContentView.swift
//  homecamera
//
//  Created by Cameron Little on 2025-06-10.
//

import AVFoundation
import SwiftUI

struct ContentView: View {
    @State
    private var cameraServer: CameraServer = .shared

    var body: some View {
        VStack {
            Text(cameraServer.getURL())

            Picker(
                selection: .init(
                    get: {
                        cameraServer.device?.uniqueID
                    },
                    set: { newValue in
                        if let newValue {
                            cameraServer.device = AVCaptureDevice(uniqueID: newValue)
                        } else {
                            cameraServer.device = nil
                        }
                    }
                )
            ) {
                Text("Select Camera").tag(nil as String?)
                    .selectionDisabled()
                ForEach(cameraServer.deviceDiscovery.devices, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(device.uniqueID)
                        .selectionDisabled(!device.isConnected)
                }
            } label: {
                Label("Camera", systemImage: "arrow.trianglehead.2.clockwise.rotate.90.camera.fill")
            }

            if let session = cameraServer.session {
                CameraPreview(session: session)
                    .edgesIgnoringSafeArea(.all)
            } else {
                ProgressView("Starting camera...")
            }
        }
        .task {
            Task(priority: .background) {
                cameraServer.startup()
            }
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
