//
//  ContentView.swift
//  homecamera
//
//  Created by Cameron Little on 2025-06-10.
//

import AVFoundation
import SwiftUI

struct ConnectionView: View {
    var connection: RTSPClientConnection

    @State
    private var jitter: Double? = nil
    @State
    private var packetLoss: Double? = nil

    var body: some View {
        VStack {
            Text(connection.sourceDescription ?? "unnamed")
            VStack {
                if let jitter {
                    Text("Jitter: \(String(format: "%.2f", jitter)) ms")
                }
                if let packetLoss {
                    Text("Packet Loss: \(String(format: "%.2f", packetLoss))%")
                }
            }
            .font(.footnote)
        }
        .onReceive(connection.receiverReports) { block in
            jitter = block.jitter
            packetLoss = block.fractionLost
        }
    }
}

struct ContentView: View {
    @State
    private var cameraServer: CameraServer = .shared

    var body: some View {
        NavigationStack {
            HStack {
                VStack {
                    if let session = cameraServer.session {
                        CameraPreview(session: session)
                            .ignoresSafeArea()
                    } else {
                        ProgressView("Starting camera…")
                    }

                    CameraPreview2(pipeline: cameraServer.pipeline)
                }
                VStack {
                    if let rtsp = cameraServer.rtsp {
                        ForEach(rtsp.connections, id: \.socket) { connection in
                            ConnectionView(connection: connection)
                        }
                    }
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
            UIApplication.shared.isIdleTimerDisabled = true
            Task.detached {
                await cameraServer.startup()
            }
        }
    }
}

#Preview {
    ContentView()
}
