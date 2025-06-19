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
        NavigationStack {
            VStack {
                if let session = cameraServer.session {
                    CameraPreview(session: session)
                        .ignoresSafeArea()
                } else {
                    ProgressView("Starting camera…")
                }
            }
            .toolbar {
                ToolbarItem {
                    if let urlString = cameraServer.getURL(),
                        let url = URL(string: urlString)
                    {
                        ShareLink(item: url, preview: SharePreview("RTSP Server URL")) {
                            Label("Copy URL", systemImage: "network")
                        }
                    } else {
                        Button {
                        } label: {
                            Label("Copy URL", systemImage: "network.slash")
                        }
                        .disabled(true)
                    }
                }
                ToolbarItem {
                    Button {
                        UIScreen.main.brightness = 0
                    } label: {
                        Label("Battery Saver", systemImage: "powersleep")
                    }
                }
                ToolbarItem {
                    Menu {
                        Picker(
                            "Camera",
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
                            ForEach(cameraServer.deviceDiscovery.devices, id: \.uniqueID) {
                                device in
                                Text(device.localizedName).tag(device.uniqueID)
                                    .selectionDisabled(!device.isConnected)
                            }
                        }
                    } label: {
                        Label(
                            "Camera",
                            systemImage: "arrow.trianglehead.2.clockwise.rotate.90.camera.fill"
                        )
                    }
                }
            }
        }
        .task {
            Task(priority: .background) {
                cameraServer.startup()
                UIApplication.shared.isIdleTimerDisabled = true
            }
        }
    }
}

#Preview {
    ContentView()
}
