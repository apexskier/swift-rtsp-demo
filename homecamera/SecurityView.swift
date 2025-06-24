//
//  SecurityView.swift
//  homecamera
//
//  Created by Cameron Little on 2025-06-24.
//

import SwiftUI

struct SecurityView: View {
    @Binding
    var auth: RTSPServer.Auth?

    @State
    private var showPassword = false

    // this mirrors auth state, which allows us to not lose the last auth when it's hidden accidentally
    @State
    private var lastAuth: RTSPServer.Auth? = nil

    var body: some View {
        Form {
            Section("Basic Authentication") {
                Toggle(
                    "Enabled",
                    isOn: .init(
                        get: {
                            auth != nil
                        },
                        set: {
                            if $0 {
                                if let lastAuth {
                                    auth = lastAuth
                                } else {
                                    let password =
                                        (SecCreateSharedWebCredentialPassword() as? String)
                                        ?? "password"
                                    auth = .init(username: "admin", password: password)
                                }
                                showPassword = true
                            } else {
                                auth = nil
                            }
                        }
                    )
                )
                if let auth {
                    TextField(
                        "Username",
                        text: .init(
                            get: { auth.username },
                            set: { self.auth = .init(username: $0, password: auth.password) }
                        )
                    )
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    HStack {
                        if showPassword {
                            TextField(
                                "Password",
                                text: .init(
                                    get: { auth.password },
                                    set: {
                                        self.auth = .init(username: auth.username, password: $0)
                                    }
                                )
                            )
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        } else {
                            SecureField(
                                "Password",
                                text: .init(
                                    get: { auth.password },
                                    set: {
                                        self.auth = .init(username: auth.username, password: $0)
                                    }
                                )
                            )
                        }
                        Button {
                            showPassword.toggle()
                        } label: {
                            Label(
                                showPassword ? "Hide Password" : "Show Password",
                                systemImage: showPassword ? "eye.slash" : "eye"
                            )
                        }
                    }
                    .labelStyle(.iconOnly)
                }
            }
            .onChange(
                of: auth,
                initial: true,
                { oldValue, newValue in
                    if let oldValue {
                        lastAuth = oldValue
                    }
                }
            )
            .onAppear {
                lastAuth = auth
            }
        }
    }
}
