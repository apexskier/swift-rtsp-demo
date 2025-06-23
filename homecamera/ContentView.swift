//
//  ContentView.swift
//  homecamera
//
//  Created by Cameron Little on 2025-06-10.
//

import AVFoundation
import SwiftUI

struct RTPView: View {
    var rtpSession: RTPSession

    @State
    private var jitter: Double? = nil
    @State
    private var packetLoss: Double? = nil

    var body: some View {
        VStack {
            Text("\(rtpSession.sourceDescription ?? "Unknown")")
            VStack {
                if let jitter {
                    Text("Jitter: \(String(format: "%.2f", jitter * 1000)) ms")
                }
                if let packetLoss {
                    Text("Packet Loss: \(String(format: "%.2f", packetLoss))%")
                }
            }
            .font(.footnote)
        }
        .onReceive(rtpSession.receiverReports) { block in
            jitter = block.jitter
            packetLoss = block.fractionLost
        }
    }
}

struct ConnectionView: View {
    var connection: RTSPClientConnection

    var body: some View {
        ForEach(connection.sessions.sorted(by: { $0.key > $1.key }), id: \.key) { sessionId, session in
            ForEach(session.rtpSessions.sorted(by: { $0.key > $1.key }), id: \.value.ssrc) { rtpStreamId, rtpSession in
                RTPView(rtpSession: rtpSession)
            }
        }
    }
}

struct BatterySaverToolbarItem: ToolbarContent {
    @State
    private var lastBrightness: CGFloat? = nil

    var body: some ToolbarContent {
        ToolbarItem {
            Button {
                if let lastBrightness {
                    UIScreen.main.brightness = lastBrightness
                    self.lastBrightness = nil
                } else {
                    self.lastBrightness = UIScreen.main.brightness
                    UIScreen.main.brightness = 0
                }
            } label: {
                Label("Battery Saver", systemImage: "powersleep")
            }
        }
    }
}

struct CameraPickerToolbarItem: ToolbarContent {
    var cameraServer: CameraServer

    var body: some ToolbarContent {
        ToolbarItem {
            Menu {
                Picker(
                    "Camera",
                    selection: .init(
                        get: {
                            cameraServer.videoDevice?.uniqueID
                        },
                        set: { newValue in
                            if let newValue {
                                cameraServer.videoDevice = AVCaptureDevice(
                                    uniqueID: newValue
                                )
                            } else {
                                cameraServer.videoDevice = nil
                            }
                        }
                    )
                ) {
                    Text("Select Camera").tag(nil as String?)
                        .selectionDisabled()
                    ForEach(cameraServer.videoDeviceDiscovery.devices, id: \.uniqueID) {
                        device in
                        Text(device.localizedName)
                            .tag(device.uniqueID)
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

struct MicrophonePickerToolbarItem: ToolbarContent {
    var cameraServer: CameraServer

    var body: some ToolbarContent {
        ToolbarItem {
            Menu {
                Picker(
                    "Microphone",
                    selection: .init(
                        get: {
                            cameraServer.audioDevice?.uniqueID
                        },
                        set: { newValue in
                            if let newValue {
                                cameraServer.audioDevice = AVCaptureDevice(
                                    uniqueID: newValue
                                )
                            } else {
                                cameraServer.audioDevice = nil
                            }
                        }
                    )
                ) {
                    Text("Select Microphone").tag(nil as String?)
                        .selectionDisabled()
                    ForEach(cameraServer.audioDeviceDiscovery.devices, id: \.uniqueID) {
                        device in
                        Text(device.localizedName)
                            .tag(device.uniqueID)
                            .selectionDisabled(!device.isConnected)
                    }
                }
            } label: {
                Label(
                    "Microphone",
                    systemImage: "microphone.fill"
                )
            }
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
                        ForEach(rtsp.connections, id: \.socketInbound) { connection in
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
                        ShareLink(item: url) {
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
                BatterySaverToolbarItem()
                if cameraServer.videoDeviceDiscovery.devices.count > 1 {
                    CameraPickerToolbarItem(cameraServer: cameraServer)
                }
                if cameraServer.audioDeviceDiscovery.devices.count > 1 {
                    MicrophonePickerToolbarItem(cameraServer: cameraServer)
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
