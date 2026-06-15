import Foundation
import Network
import Darwin
import os

/**
 Make sure to add these settings to your project. If you skip these, your app won't be able to scan for Pico AI Homelab.
 - Add a [NSBonjourServices property](https://developer.apple.com/documentation/bundleresources/information_property_list/nsbonjourservices) to your Info.plist to declare what service types you’re using (`_pico._tcp`).
 - Add a [NSLocalNetworkUsageDescription property](https://developer.apple.com/documentation/bundleresources/information_property_list/nslocalnetworkusagedescription) to your Info.plist to explain what you’re doing with the local network.
 - For sandboxed macOS app, enable`Signing & Capabilities` -> `App Sandbox` -> `Network:` `Outgoing Connections (Client)`

 This code is based on this example: https://developer.apple.com/forums/thread/735862

 - Note: `BonjourPico` is main-actor isolated. Create it and call its methods from the main actor.
 */
@MainActor
@Observable
open class BonjourPico {

    private var browserQ: NWBrowser? = nil

    private let logger = Logger(subsystem: "BonjourPico", category: "discovery")

    /// List of discovered Pico AI Homelab servers
    public private(set) var servers = [PicoHomelabModel]()

    /// State of the browser. Is nil if browser isn't running
    public private(set) var state: NWBrowser.State? = nil

    /// True if BonjourPico is scanning for Pico AI Homelab servers
    public var isScanning: Bool {
        state == .ready
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
        // sendMagicPacket performs a blocking BSD socket send. Run it off the
        // calling (main) actor so the async contract is honest.
        try await Task.detached { try Self.sendMagicPacket(packet) }.value
    }

    private nonisolated static func magicPacket(for macString: String) throws -> Data {
        let components = macString.replacingOccurrences(of: "-", with: ":").split(separator: ":")
        guard components.count == 6 else { throw BonjourPicoError.invalidMACAddress }
        let bytes: [UInt8] = try components.map { component in
            guard component.count == 2,
                  component.allSatisfy(\.isHexDigit),
                  let byte = UInt8(component, radix: 16) else {
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
    private nonisolated static func sendMagicPacket(_ data: Data) throws {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { throw socketError() }
        defer { Darwin.close(sock) }

        var broadcast: Int32 = 1
        guard setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw socketError()
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
        guard sent == data.count else { throw socketError() }
    }

    /// Maps the current `errno` to a descriptive error. Must be called immediately
    /// after the failing syscall, before any other call can overwrite `errno`.
    private nonisolated static func socketError() -> BonjourPicoError {
        let err = errno
        if err == EPERM {
            return .broadcastNotPermitted
        }
        return .sendFailed(String(cString: strerror(err)))
    }
    
    private func start() -> NWBrowser {
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: "_pico._tcp", domain: "local.")
        let browser = NWBrowser(for: descriptor, using: .tcp)
        // NWBrowser delivers callbacks on the queue passed to `start(queue:)`. We use
        // `.main`, so it is safe to assume main-actor isolation inside these handlers.
        browser.stateUpdateHandler = { [weak self] newState in
            MainActor.assumeIsolated {
                self?.state = newState
            }
        }
        browser.browseResultsChangedHandler = { [weak self] _, changes in
            MainActor.assumeIsolated {
                guard let self else { return }
                for change in changes {
                    switch change {
                    case .added(let result):
                        self.addServer(result: result)
                    case .removed(let result):
                        self.removeServer(result: result)
                    case .changed(old: let old, new: let new, flags: _):
                        // Remove the previous instance (keyed off `old`) so a changed
                        // ServerIdentifier can't leave a stale duplicate; addServer dedupes new.
                        self.removeServer(result: old)
                        self.addServer(result: new)
                    case .identical:
                        break
                    @unknown default:
                        break
                    }
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

    private func addServer(result: NWBrowser.Result) {
        do {
            let server = try PicoHomelabModel(result: result)
            // Replace any existing entry with the same stable identifier to avoid duplicates.
            servers.removeAll { $0.id == server.id }
            servers.append(server)
            logger.debug("Discovered server \(server.name, privacy: .public)")
        } catch {
            logger.error("Failed to add server: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func removeServer(result: NWBrowser.Result) {
        // Prefer the stable ServerIdentifier; fall back to name + type when unavailable.
        if case let .bonjour(txtRecord) = result.metadata,
           let id = txtRecord["ServerIdentifier"] {
            servers.removeAll { $0.id == id }
            return
        }
        guard case .service(let name, let type, _, _) = result.endpoint else { return }
        servers.removeAll { $0.name == name && $0.type == type }
    }

    public init() {}

    deinit {
        browserQ?.cancel()
    }
}
