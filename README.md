# Discover Pico AI Homelab Servers Using Bonjour

[Pico AI Homelab](https://apps.apple.com/us/app/pico-ai-homelab-powered-by-mlx/id6738607769?mt=12) is the fastest and easiest way to set up a local LLM server on your Apple Silicon Mac, and it's free on the Mac App Store. For chat app developers, try adding BonjourPico to your project—it lets users easily connect to any Pico AI Homelab server on their local network without any hassle.

## Overview 

Pico AI Homelab broadcasts its hostname, IP address, and port using Bonjour by default. Chat applications can listen for these broadcasts to automatically connect to Pico AI Homelab.

Bonjour Pico is a Swift package—and includes an example app—that simplifies the process for chat app developers to set up automatic detection and connection to Pico AI Homelab servers.

`BonjourPico` is a `@MainActor`, `@Observable` facade you bind a SwiftUI view directly to. The `NWBrowser` runs off the main thread inside an internal actor, and the facade mirrors discovery results back onto the main actor for you—so there's no threading or `NWBrowser` boilerplate to manage.

> [!NOTE]  
> Bonjour support is available in Pico AI Homelab version 1.1.1 (build 29) and newer.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Using Bonjour to Discover Pico AI Homelab Servers](#using-bonjour-to-discover-pico-ai-homelab-servers)
- [User Walkthrough](#user-walkthrough)
- [Bonjour Broadcast Details](#bonjour-broadcast-details)
- [Usage](#usage)
- [Wake-on-LAN](#wake-on-lan)

------------------------------------------------------------

## Requirements

- **Swift 6** toolchain (Xcode 16 or newer). The package builds in the Swift 6 language mode with strict concurrency.
- **Platforms:** macOS 14+, iOS 17+, tvOS 17+, visionOS 1+.
- **Server side:** Pico AI Homelab 1.1.1 (build 29) or newer, with Bonjour enabled.

------------------------------------------------------------

## Installation

### Add the package

In Xcode, choose **File ▸ Add Package Dependencies…**, paste the repository URL, and add the **BonjourPico** library to your app target:

```
https://github.com/PicoMLX/BonjourPico
```

Or add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/PicoMLX/BonjourPico.git", branch: "main")
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "BonjourPico", package: "BonjourPico")
        ]
    )
]
```

Then `import BonjourPico`. The module re-exports the discovery types (`BonjourEndpoint`, `BonjourDiscoveryActor`, `BonjourTXTDecoder`, `BonjourDiscoveryError`), so a single import is all you need.

> [!NOTE]
> The v2 API is actor-based and `async`. Until a versioned release is tagged, depend on the `main` branch as shown above; once a release is published you can pin it instead (for example `.package(url: …, from: "2.0.0")`).

### Configure your Xcode project

Before running your app, update your project settings as follows:

1. Add an **NSBonjourServices** array to your `Info.plist` and include `_pico._tcp` as one of the items.  
2. Add an **NSLocalNetworkUsageDescription** string to your `Info.plist` to explain why your app needs local network access.  
3. If your app is sandboxed, enable **Outgoing Connections (Client)** in *Signing & Capabilities ▸ App Sandbox*.  
4. For Wake-on-LAN on **iOS**, add the restricted `com.apple.developer.networking.multicast` entitlement (see [Wake-on-LAN](#wake-on-lan)).

------------------------------------------------------------

## Using Bonjour to Discover Pico AI Homelab Servers

Enhance your chat app’s user experience by providing an option to automatically detect Pico AI Homelab servers on the local network via Bonjour. Pico AI Homelab broadcasts the following details:

• A human-readable instance name (e.g., “Ronald's AI Homelab”)  
• The server’s local hostname (e.g., macbook-pro.local)  
• The server’s IP address  
• The port on which Pico AI Homelab is running (e.g., 11434)

------------------------------------------------------------

## User Walkthrough

From a user’s perspective, integrating Bonjour minimizes the need for manual entry of IP addresses or hostnames. Here is how the process works:

1. In settings or during setup, the user taps the “Scan for Pico AI Homelab” button.  
2. The chat app listens for Bonjour packets broadcasted by all Pico AI Homelab instances on the local network.  
3. A list of available Pico AI Homelab instances is displayed (each identified by its human-readable name).  
4. The user selects one or more servers to connect to.  
5. The app stores the server name, port, IP address, and/or hostname and automatically connects to the selected server.

> [!WARNING]  
> Keep in mind that Pico AI Homelab administrators can disable Bonjour in the settings. Therefore, chat apps should not rely solely on Bonjour. Always provide an alternative method for users to manually enter the port, hostname, or IP address of the Pico AI Homelab server.

> [!NOTE]  
> Multiple Pico AI Homelab servers may be present on a local network. Ensure that your UI displays a list of all discovered servers.

> [!NOTE]  
> Because IP addresses on a local network can change over time, it is recommended to use the local hostname for connection rather than the IP address, despite the latter being included in the broadcast.

------------------------------------------------------------

## Bonjour Broadcast Details

Pico AI Homelab broadcasts a Bonjour service with the following characteristics:

- Service Type: _pico._tcp  
- Human-readable Service Name (e.g., “Ronald's AI Homelab”)  
- TXT Record Dictionary containing:
  - `IPAddress`: The IP address of the Pico AI Homelab server  
  - `Port`: The port number (as a string) to which the Pico AI Homelab HTTP server is bound (default is 11434)  
  - `LocalHostName`: The local hostname (e.g., ronalds-macbook.local)  
  - `ServerIdentifier`: A unique UUID string that uniquely identifies a Pico AI Homelab instance, even if its IP address, service name, or local hostname changes.
  - `MACAddress` *(optional)*: The MAC address of the server's network interface, included when Wake-on-LAN is enabled in Pico AI Homelab settings.

> [!NOTE]  
> Each Pico AI Homelab instance sends a unique UUID as its server identifier, which remains consistent between sessions. Even if the admin changes the computer’s hostname or IP address, this identifier ensures that the correct instance is recognized when scanning the network again. BonjourPico exposes it as `BonjourEndpoint.id`.

> [!NOTE]
> BonjourPico ignores incomplete advertisements: a service is only surfaced if it has a `ServerIdentifier`, a valid non-zero `Port`, and at least one way to reach it (a hostname or an IP address).

------------------------------------------------------------

## Usage

An example app for both iOS and macOS is included in the repository (`BonjourPicoExample`).

### Quick start (SwiftUI)

Bind a SwiftUI view directly to the observable `endpoints` and `isScanning` properties:

```swift
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
```

### The `BonjourPico` API

| Member | Signature | Description |
| --- | --- | --- |
| `endpoints` | `[BonjourEndpoint]` | Discovered servers, sorted by name and de-duplicated. Observable; updates while scanning. |
| `isScanning` | `Bool` | `true` for the whole scan session — from `startScanning()` until `stopScanning()`, *including* while the browser is transiently failing and auto-retrying. Drive a Scan/Stop button off this. Observable. |
| `state` | `NWBrowser.State?` | The live underlying browser state (`.ready`, `.waiting`, `.failed`, …), or `nil` when not scanning. Observable; useful for surfacing connection status. |
| `startScanning()` | `async throws` | Starts a scan. Idempotent while already scanning. Throws `BonjourPicoError` if the browser can't start. |
| `stopScanning()` | `async` | Stops scanning and clears `endpoints`. |
| `endpointStream()` | `async -> AsyncThrowingStream<[BonjourEndpoint], Error>` | An async-sequence alternative to the observable `endpoints` (see below). |
| `wake(_:)` | `async throws` | Sends a Wake-on-LAN magic packet to an endpoint (see [Wake-on-LAN](#wake-on-lan)). |
| `init(configuration:)` | — | Creates the facade, optionally with a custom discovery configuration (see [Advanced configuration](#advanced-configuration)). |

### `BonjourEndpoint`

Discovered servers are immutable, `Sendable` `BonjourEndpoint` values:

| Property | Type | Description |
| --- | --- | --- |
| `id` | `String` | Stable identifier (`ServerIdentifier`), consistent across IP/host changes. |
| `displayName` | `String` | Human-readable label, falling back to the host name or `id`. |
| `name` | `String` | The advertised service / instance name. |
| `hostName` | `String?` | The advertised local hostname (preferred for connecting). |
| `ipAddresses` | `[String]` | The advertised IP address(es). |
| `port` | `UInt16` | The server port (e.g. `11434`). |
| `type` | `String` | The service type (`_pico._tcp`). |
| `domain` | `String` | The service domain (`local.`). |
| `interfaceName` | `String?` | The network interface the service was seen on. |
| `txtRecord` | `[String: Data]` | The full raw TXT record, for reading any additional keys. |
| `macAddress` | `String?` | Convenience accessor for the `MACAddress` TXT key (Wake-on-LAN). |

### Consuming an async stream

If you prefer async sequences over the observable property, iterate `endpointStream()`. Each element is the latest full snapshot of discovered endpoints:

```swift
try await bonjourPico.startScanning()

let stream = await bonjourPico.endpointStream()
for try await endpoints in stream {
    print("Discovered \(endpoints.count) server(s)")
}
```

The stream stays open across automatic retries and finishes only when you call `stopScanning()`.

### Automatic retry and the `state` property

If the underlying `NWBrowser` enters a transient `.failed` state, BonjourPico automatically restarts it with a short backoff. During retry, `isScanning` stays `true` (so the user can always stop the scan) and the observable `endpoints` / `endpointStream()` subscriptions survive the restart. Observe `state` if you want to reflect the live `NWBrowser.State` in your UI.

### Advanced configuration

Discovery defaults to the `_pico._tcp` service in the `local.` domain. To customize the service type, domain, network parameters, or retry delay, pass a `BonjourDiscoveryActor.Configuration`:

```swift
let bonjourPico = BonjourPico(
    configuration: .init(
        serviceType: "_pico._tcp",
        domain: "local.",
        retryDelay: .seconds(2)
    )
)
```

### Errors

Discovery and Wake-on-LAN failures are reported as `BonjourPicoError`, a `Sendable`, `Equatable`, `LocalizedError`. Notable cases include `.broadcastNotPermitted` (missing multicast entitlement), `.sendFailed` (underlying socket error, with the system message attached), and `.invalidMACAddress` / `.noMACAddress`. Each case provides a user-readable `errorDescription`.

------------------------------------------------------------

## Wake-on-LAN

BonjourPico can send a Wake-on-LAN magic packet to wake a sleeping Pico AI Homelab server. This requires Pico AI Homelab to have Wake-on-LAN enabled so it advertises its `MACAddress` in the Bonjour TXT record.

```swift
try await bonjourPico.wake(endpoint)
```

> [!IMPORTANT]
> When a machine goes to sleep, its Bonjour advertisement stops and BonjourPico removes it from `endpoints`. You must **cache the `macAddress` before the endpoint disappears**, using the stable `id` (ServerIdentifier) as the key.

```swift
// When a server is discovered, persist its MAC address:
if let mac = endpoint.macAddress {
    UserDefaults.standard.set(mac, forKey: "mac-\(endpoint.id)")
}

// Later, to wake a known-but-offline server, reconstruct an endpoint with the cached MAC:
if let mac = UserDefaults.standard.string(forKey: "mac-\(known.id)") {
    let endpoint = BonjourEndpoint(
        id: known.id,
        name: known.name,
        type: known.type,
        domain: known.domain,
        interfaceName: nil,
        hostName: known.hostName,
        ipAddresses: known.ipAddresses,
        port: known.port,
        txtRecord: ["MACAddress": Data(mac.utf8)]
    )
    try await bonjourPico.wake(endpoint)
}
```

> [!NOTE]
> The magic packet is sent as a UDP broadcast (`255.255.255.255:9`) directly from the chat app. Both the chat app and the target machine must be on the same LAN subnet. WoL magic packets do not cross routers.

> [!WARNING]
> **iOS apps require the `com.apple.developer.networking.multicast` entitlement** to send UDP broadcast packets. This is a restricted entitlement that must be requested from Apple before it can be used in App Store submissions. macOS and macOS sandbox apps are not affected. See [Apple's documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast) for details on requesting this entitlement.

When the entitlement is missing, `wake(_:)` throws `BonjourPicoError.broadcastNotPermitted`. Other socket failures throw `BonjourPicoError.sendFailed`, whose associated value describes the underlying system error.
