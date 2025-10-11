# Discover Pico AI Homelab Servers Using Bonjour

[Pico AI Homelab](https://apps.apple.com/us/app/pico-ai-homelab-powered-by-mlx/id6738607769?mt=12) is the fastest way to stand up a local LLM server on Apple Silicon. The BonjourPico Swift package lets your app discover those servers automatically using Bonjour with a modern Swift 6.2 architecture.

## Overview

BonjourPico now ships with two layers:

- `BonjourDiscoveryCore` — an actor-based wrapper around `NWBrowser` that surfaces async streams of endpoints, TXT metadata decoding, and automatic retry logic under strict concurrency.
- `BonjourPico` — a `@MainActor` façade and `BonjourPicoViewModel` powered by the Observation framework for SwiftUI apps.

The example project demonstrates both layers and mirrors the code snippets below.

> [!NOTE]
> Bonjour support is available in Pico AI Homelab version 1.1.1 (build 29) and newer.

## Architecture Highlights

- Swift 6.2 tools with strict concurrency warnings enabled by default.
- Actor-isolated discovery pipeline that deduplicates endpoints and streams browser state updates.
- SwiftUI-friendly view model exposing observable `endpoints`, `state`, `isScanning`, and `error` properties.
- Resilient TXT decoder that understands `NWTXTRecord.Entry` enum cases and preserves raw data when needed.

## Platform & Project Requirements

- Minimum deployment targets: macOS 14, iOS 17, tvOS 17, visionOS 1.
- Add the following keys to your app bundle:
  - `NSBonjourServices`: include `_pico._tcp`.
  - `NSLocalNetworkUsageDescription`: explain why Bonjour discovery is required.
- For sandboxed macOS builds, enable **Outgoing Connections (Client)** under Signing & Capabilities → App Sandbox.

## Installation (Swift Package Manager)

1. In Xcode, choose **File → Add Packages…**.
2. Enter `https://github.com/PicoMLX/BonjourPico` and select the `feature/Swift6` branch (or latest release).
3. Add the `BonjourPico` product to your target. The dependency automatically includes `BonjourDiscoveryCore` with strict concurrency flags.

## Quick Start: Async API

```swift
import BonjourPico

func discover() async {
    let pico = BonjourPico()
    do {
        try await pico.startScanning()
        for try await endpoints in await pico.streamEndpoints() {
            for endpoint in endpoints {
                print("Found", endpoint.displayName, endpoint.port)
            }
        }
    } catch {
        print("Bonjour scan failed:", error)
    }
}

Task { await discover() }
```

## SwiftUI Integration

```swift
import SwiftUI
import BonjourPico

struct ContentView: View {
    @State private var viewModel = BonjourPicoViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.endpoints.isEmpty {
                    ContentUnavailableView("No Pico servers", systemImage: "bonjour")
                } else {
                    List(viewModel.endpoints) { endpoint in
                        VStack(alignment: .leading) {
                            Text(endpoint.displayName)
                            if let host = endpoint.hostName {
                                Text("Host: \(host)").font(.footnote)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Discover")
            .toolbar {
                Button(viewModel.isScanning ? "Stop" : "Scan") {
                    viewModel.isScanning ? viewModel.stopScanning() : viewModel.startScanning()
                }
            }
            .task { viewModel.startScanning() }
        }
        .alert("Bonjour Error", isPresented: .constant(viewModel.error != nil)) {
            Button("OK") { viewModel.error = nil }
        } message: {
            Text(viewModel.error?.localizedDescription ?? "")
        }
    }
}
```

## API Snapshot

- `BonjourEndpoint`: Sendable model containing ID, display name, service type, hostname, IP addresses, port, and raw TXT record.
- `BonjourDiscoveryActor.Configuration`: Configure service type, domain, retry delays, and logging.
- `BonjourPico`: `@MainActor` wrapper exposing async `startScanning()`, `stopScanning()`, `endpoints`, and streaming helpers.
- `BonjourPicoViewModel`: Observable SwiftUI-ready façade managing scanning lifecycle and error propagation.
- `BonjourPicoError`: Public error enum that maps discovery failures, cancellation, and underlying errors into localized descriptions.

## Tips & Troubleshooting

- Administrators can disable Bonjour in Pico AI Homelab. Always provide a manual hostname/IP fallback.
- Multiple servers may appear; present the full list so users can choose their target.
- Prefer `endpoint.hostName` over raw IP addresses because DHCP can change addresses between sessions.
- Each server broadcasts a stable `ServerIdentifier` UUID so you can persist choices across restarts.

> [!TIP]
> The included `BonjourPicoExample` target shows how to incorporate the view model into a real SwiftUI app.