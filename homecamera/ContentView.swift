//
//  ContentView.swift
//  homecamera
//
//  Created by Cameron Little on 2025-06-10.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Hello, world!")

            CameraPreview(session: CameraServer.shared.session!)
                .edgesIgnoringSafeArea(.all)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
