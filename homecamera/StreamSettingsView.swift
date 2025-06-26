//
//  StreamSettingsView.swift
//  homecamera
//
//  Created by Cameron Little on 2025-06-26.
//

import SwiftUI

struct StreamSettingsView: View {
    @Binding
    var deviceName: String?
    @Binding
    var showDateTime: Bool
    
    @State
    private var lastDeviceName: String? = nil

    var body: some View {
        Section("Stream") {
            Toggle("Show Date/Time", isOn: $showDateTime)

            Section {
                Toggle(
                    "Show Device Name",
                    isOn: .init(
                        get: { deviceName != nil },
                        set: {
                            if $0 {
                                self.deviceName = lastDeviceName ?? UIDevice.current.name
                            } else {
                                self.deviceName = nil
                            }
                        }
                    )
                )
                if let deviceName {
                    TextField(
                        "Device Name",
                        text: .init(
                            get: {
                                deviceName
                            },
                            set: { newValue in
                                self.deviceName = newValue
                            }
                        )
                    )
                }
            }
        }
    }
}

