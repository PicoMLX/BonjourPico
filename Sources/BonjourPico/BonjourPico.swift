import Foundation
import Network

/**
 Make sure to add these settings to your project. If you skip these, your app won't be able to scan for Pico AI Homelab.
 - Add a [NSBonjourServices property](https://developer.apple.com/documentation/bundleresources/information_property_list/nsbonjourservices) to your Info.plist to declare what service types you’re using (`_pico._tcp`).
 - Add a [NSLocalNetworkUsageDescription property](https://developer.apple.com/documentation/bundleresources/information_property_list/nslocalnetworkusagedescription) to your Info.plist to explain what you’re doing with the local network.
 - For sandboxed macOS app, enable`Signing & Capabilities` -> `App Sandbox` -> `Network:` `Outgoing Connections (Client)`

 This code is based on this example: https://developer.apple.com/forums/thread/735862
 */
@Observable
open class BonjourPico: @unchecked Sendable {

    private var browserQ: NWBrowser? = nil
    private var connectionQ: NWConnection? = nil
    
    /// List of discovered Pico AI Homelab servers
    public private(set) var servers = [PicoHomelabModel]()
    
    /// State of the browser. Is nil if browser isn't running
    public private(set) var state: NWBrowser.State? = nil
    
    /// True if BonjourPico is scanning for Pico AI Homelab servers
    public var isScanning: Bool {
        guard let browserQ else { return false }
        return browserQ.state == .ready
    }
    
    public func startStop() {
        if let browser = self.browserQ {
            self.browserQ = nil
            self.stop(browser: browser)
        } else {
            self.browserQ = self.start()
        }
    }
    
    private func start() -> NWBrowser {
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_pico._tcp", domain: "local.")
        let browser = NWBrowser(for: descriptor, using: .tcp)
        browser.stateUpdateHandler = { newState in
            self.state = newState
        }
        browser.browseResultsChangedHandler = { updated, changes in
            for change in changes {
                switch change {
                case .added(let result):
                    
                    print("+ \(result.endpoint)")
                    Task {
                        do {
                            let server = try await self.createModel(result: result)
                            Task { @MainActor in
                                self.servers.append(server)
                            }
                        } catch {
                            print(error)
                        }
                    }
                    
                case .removed(let result):
                    
                    print("- \(result.endpoint)")
                    Task {
                        do {
                            try await self.removeServer(result: result)
                        } catch {
                            print(error)
                        }
                    }
                    
                case .changed(old: let old, new: let new, flags: _):
                    
                    Task {
                        do {
                            try await self.removeServer(result: old)
                            let server = try await self.createModel(result: new)
                            Task { @MainActor in
                                self.servers.append(server)
                            }
                        } catch {
                            print(error)
                        }
                    }
                    
                case .identical:
                    fallthrough
                @unknown default:
                    print("?")
                }
            }
        }
        browser.start(queue: .main)
        return browser
    }
    
    private func stop(browser: NWBrowser) {
        self.connectionQ?.cancel()
        self.connectionQ?.stateUpdateHandler = nil
        self.connectionQ = nil
        self.state = nil
        browser.stateUpdateHandler = nil
        browser.cancel()
    }
    
    @MainActor
    private func removeServer(result: NWBrowser.Result) throws {
        guard case .service(let name, let type, let domain, let interface) = result.endpoint else {
            throw BonjourPicoError.invalidEndpoint
        }
        Task { @MainActor in
            self.servers.removeAll { $0.name == name && $0.type == type  }
        }
    }
    
    private func createModel(result: NWBrowser.Result) async throws -> PicoHomelabModel {
        
        guard case .service(let name, let type, let domain, let interface) = result.endpoint else {
            throw BonjourPicoError.invalidEndpoint
        }
        
        self.connectionQ = NWConnection(to: result.endpoint, using: .tcp)
        
        return try await withCheckedThrowingContinuation { continuation in
                        
            self.connectionQ?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Connection is ready; retrieve the remote endpoint
                    if let remoteEndpoint = self.connectionQ?.currentPath?.remoteEndpoint {
                        self.connectionQ?.cancel()
                        switch remoteEndpoint {
                        case .hostPort(let host, let port):
                            
                            let ipAddress: String
                            switch host {
                            case .ipv4(let address):
                                ipAddress = address.debugDescription
                            case .ipv6(let address):
                                ipAddress = address.debugDescription
                            case .name(let name, let interface):
                                ipAddress = name
                            }
                            
                            let model = PicoHomelabModel(
                                name: name,
                                type: type,
                                domain: result.endpoint.debugDescription,
                                ipAddress: ipAddress,
                                port: Int(port.rawValue)
                            )
                            continuation.resume(returning: model)
                        default:
                            continuation.resume(throwing: BonjourPicoError.invalidEndpoint)
                        }
                    }
                default:
                    break
                }
            }
            self.connectionQ?.start(queue: .global())
        }
    }
    
    public init() {}
    deinit {
        if let browserQ {
            stop(browser: browserQ)
        }
    }
}
