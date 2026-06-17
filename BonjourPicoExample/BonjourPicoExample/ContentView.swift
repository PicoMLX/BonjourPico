//
//  ContentView.swift
//  BonjourPicoExample
//
//  Created by Ronald Mannak on 2/13/25.
//

import SwiftUI
import BonjourPico

struct ContentView: View {

    @State private var bonjourPico = BonjourPico()

    var body: some View {
        VStack {
            List(bonjourPico.endpoints) { endpoint in
                let host = endpoint.hostName ?? endpoint.ipAddresses.first ?? "—"
                Text("\(endpoint.displayName): \(host):\(endpoint.port)")
            }

            Button(bonjourPico.isScanning ? "Stop scanning" : "Scan for Pico AI Homelab servers") {
                Task {
                    if bonjourPico.isScanning {
                        await bonjourPico.stopScanning()
                    } else {
                        try? await bonjourPico.startScanning()
                    }
                }
            }
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
