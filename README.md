# Discover Pico AI Homelab Servers Using Bonjour

[Pico AI Homelab](https://apps.apple.com/us/app/pico-ai-homelab-powered-by-mlx/id6738607769?mt=12) is the fastest and easiest way to set up a local LLM server on your Apple Silicon Mac, and it's free on the Mac App Store. For chat app developers, try adding BonjourPico to your project—it lets users easily connect to any Pico AI Homelab server on their local network without any hassle.

## Overview 

Pico AI Homelab broadcasts its hostname, IP address, and port using Bonjour by default. Chat applications can listen for these broadcasts to automatically connect to Pico AI Homelab.

Bonjour Pico is a Swift package—and includes an example app—that simplifies the process for chat app developers to set up automatic detection and connection to Pico AI Homelab servers.

> [!NOTE]  
> Bonjour support is available in Pico AI Homelab version 1.1.1 (build 29) and newer.

------------------------------------------------------------

## Using Bonjour to Discover Pico AI Homelab Servers

Enhance your chat app’s user experience by providing an option to automatically detect Pico AI Homelab servers on the local network via Bonjour. Pico AI Homelab broadcasts the following details:

• A human-readable instance name (e.g., “Ronald's AI Homelab”)  
• The server’s local hostname (e.g., macbook-pro.local)  
• The server’s IP address  
• The port on which Pico AI Homelab is running (e.g., 11434)

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

> [!NOTE]  
> Each Pico AI Homelab instance sends a unique UUID as its server identifier, which remains consistent between sessions. Even if the admin changes the computer’s hostname or IP address, this identifier ensures that the correct instance is recognized when scanning the network again.

------------------------------------------------------------

## Installation

The easiest way to use Bonjour for Pico AI Homelab in your chat app is by adding the BonjourPico Swift package. You can find it here:  
https://github.com/PicoMLX/BonjourPico

------------------------------------------------------------

## Xcode Settings

Before running your app, update your Xcode project settings as follows:

1. Add an NSBonjourServices property to your Info.plist and include _pico._tcp as one of the items.  
2. Add an NSLocalNetworkUsageDescription property to your Info.plist to explain why your app requires network access.  
3. If your app is sandboxed, enable "Outgoing Connections (Client)" in Signing & Capabilities > App Sandbox.

------------------------------------------------------------

## Sample Client Code

An example app for both iOS and macOS is included in the repository.

```swift
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
```