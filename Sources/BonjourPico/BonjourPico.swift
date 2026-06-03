import Foundation
import Network
import Darwin

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
//    private var connectionQ: NWConnection? = nil
    
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

    /// Sends a Wake-on-LAN magic packet to the given peer.
    /// The peer must have a non-nil `macAddress` (advertised via the `MACAddress` TXT record key).
    /// Because the peer is likely offline when this is called, callers must cache the peer's
    /// `macAddress` (keyed by `peer.id`) before the peer disappears from `servers`.
    public func wake(peer: PicoHomelabModel) async throws {
        guard let mac = peer.macAddress else { throw BonjourPicoError.noMACAddress }
        let packet = try Self.magicPacket(for: mac)
        try Self.sendMagicPacket(packet)
    }

    private static func magicPacket(for macString: String) throws -> Data {
        let components = macString.replacingOccurrences(of: "-", with: ":").split(separator: ":")
        guard components.count == 6 else { throw BonjourPicoError.invalidMACAddress }
        let bytes: [UInt8] = try components.map { component in
            guard component.count == 2, let byte = UInt8(component, radix: 16) else {
                throw BonjourPicoError.invalidMACAddress
            }
            return byte
        }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }
        return packet
    }

    // NWConnection does not support UDP broadcast (Apple TN3151). Use BSD sockets with
    // SO_BROADCAST so the magic packet reaches 255.255.255.255 on all Apple platforms.
    private static func sendMagicPacket(_ data: Data) throws {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { throw BonjourPicoError.internalError }
        defer { Darwin.close(sock) }

        var broadcast: Int32 = 1
        guard setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw BonjourPicoError.internalError
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(9).bigEndian
        addr.sin_addr.s_addr = INADDR_BROADCAST

        let sent = data.withUnsafeBytes { buf in
            withUnsafeMutablePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    sendto(sock, buf.baseAddress, data.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == data.count else { throw BonjourPicoError.internalError }
    }
    
    private func start() -> NWBrowser {
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: "_pico._tcp", domain: "local.")
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
                            let server = try PicoHomelabModel(result: result)
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
                            let server = try PicoHomelabModel(result: new)
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

    public init() {}
    
    deinit {
        if let browserQ {
            stop(browser: browserQ)
        }
    }
}
