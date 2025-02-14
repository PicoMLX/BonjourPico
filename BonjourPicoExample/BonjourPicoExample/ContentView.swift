//
//  ContentView.swift
//  BonjourPicoExample
//
//  Created by Ronald Mannak on 2/13/25.
//

import SwiftUI
import BonjourPico

struct ContentView: View {
    
    @State var bonjourPico = BonjourPico()
    
    var body: some View {
        VStack {
            List(bonjourPico.servers, id: \.self) { server in
                let domain = "\(server.hostName):\(server.port)"
                let ip = "\(server.ipAddress):\(server.port)"
                Text("\(server.name): \(domain) \(ip)")
            }
            
            Button(bonjourPico.isScanning ? "Stop scanning" : "Scan for Pico AI Homelab servers") {
                bonjourPico.startStop()
            }
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
