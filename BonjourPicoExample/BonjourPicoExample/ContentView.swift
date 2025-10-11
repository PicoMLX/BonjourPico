import SwiftUI
import BonjourPico

struct ContentView: View {
    @State private var viewModel = BonjourPicoViewModel()

    var body: some View {
        VStack(spacing: 16) {
            if viewModel.endpoints.isEmpty {
                ContentUnavailableView("No Pico servers", systemImage: "bonjour", description: Text(viewModel.isScanning ? "Scanning the local network…" : "Start a scan to discover servers."))
            } else {
                List(viewModel.endpoints) { endpoint in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(endpoint.displayName)
                            .font(.headline)
                        if let host = endpoint.hostName {
                            Text("Host: \(host)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if let address = endpoint.ipAddresses.first {
                            Text("IP: \(address):\(endpoint.port)")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                if let error = viewModel.error {
                    Text(error.localizedDescription)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Spacer()
                Button(viewModel.isScanning ? "Stop" : "Scan") {
                    if viewModel.isScanning {
                        viewModel.stopScanning()
                    } else {
                        viewModel.startScanning()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .task {
            viewModel.startScanning()
        }
        .onDisappear {
            viewModel.stopScanning()
        }
    }
}

#Preview {
    ContentView()
}
