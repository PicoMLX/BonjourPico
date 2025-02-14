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
                            
                            var ipAddress = ""
                            switch host {
                            case .ipv4(let address):
                                ipAddress = address.debugDescription
                            case .ipv6(let address):
                                ipAddress = address.debugDescription
                            case .name(let name, let interface):
                                ipAddress = name
                            }
                            ipAddress = self.cleanIPAddress(ipAddress)
                            
                            // FIXME: for domain I would like to set the local DNS name of the
                            // server, e.g. macbook.local
                            let model = PicoHomelabModel(
                                name: name,
                                type: type,
                                domain: self.resolveLocalHostName(ipAddress: ipAddress) ?? "",
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
    
    /// Resolves the local hostname for a given IP address
    /// - Parameter ipAddress: The IP address to resolve (e.g. "192.168.1.100")
    /// - Returns: The local hostname if found (e.g. "my-macbook.local"), nil otherwise
    func resolveLocalHostName(ipAddress: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_NUMERICHOST
        
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ipAddress, nil, &hints, &result) == 0,
              let result = result else {
            return nil
        }
        defer { freeaddrinfo(result) }
        
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(result.pointee.ai_addr,
                       result.pointee.ai_addrlen,
                       &hostname,
                       socklen_t(hostname.count),
                       nil,
                       0,
                       NI_NAMEREQD) == 0 {
            return String(cString: hostname)
        }
        
        return nil
    }
    
    /// Remove interface identifier
    private func cleanIPAddress(_ ipAddress: String) -> String {
        if let percentRange = ipAddress.range(of: "%") {
            return String(ipAddress[..<percentRange.lowerBound])
        }
        return ipAddress
    }

    public init() {}
    
    deinit {
        if let browserQ {
            stop(browser: browserQ)
        }
    }
}
