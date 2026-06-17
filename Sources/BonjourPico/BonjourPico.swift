import Foundation
import Network
import Darwin
import BonjourDiscoveryCore

/**
 Discovers Pico AI Homelab servers on the local network via Bonjour and (optionally)
 wakes a sleeping server with a Wake-on-LAN magic packet.

 `BonjourPico` is a `@MainActor`, `@Observable` facade: bind a SwiftUI view directly to
 `endpoints` / `isScanning`. The actual `NWBrowser` runs off the main thread inside an
 internal `BonjourDiscoveryActor`; this facade mirrors its output onto the main actor.

 Required project configuration:
 - Add `_pico._tcp` to the [NSBonjourServices](https://developer.apple.com/documentation/bundleresources/information_property_list/nsbonjourservices) Info.plist key.
 - Add an [NSLocalNetworkUsageDescription](https://developer.apple.com/documentation/bundleresources/information_property_list/nslocalnetworkusagedescription) Info.plist key.
 - For a sandboxed macOS app, enable `App Sandbox` -> `Outgoing Connections (Client)`.
 - For Wake-on-LAN on iOS, the restricted `com.apple.developer.networking.multicast` entitlement is required.
 */
@MainActor
@Observable
public final class BonjourPico {

    /// Discovered servers, sorted and de-duplicated. Updated automatically while scanning.
    public private(set) var endpoints: [BonjourEndpoint] = []

    /// The underlying browser state, or `nil` when not scanning.
    public private(set) var state: NWBrowser.State?

    /// True while the browser is actively scanning.
    public var isScanning: Bool {
        switch state {
        case .ready, .waiting:
            return true
        default:
            return false
        }
    }

    @ObservationIgnored private let discovery: BonjourDiscoveryActor
    @ObservationIgnored private var endpointTask: Task<Void, Never>?
    @ObservationIgnored private var stateTask: Task<Void, Never>?

    public init(configuration: BonjourDiscoveryActor.Configuration = .init()) {
        self.discovery = BonjourDiscoveryActor(configuration: configuration)
    }

    deinit {
        // No nonisolated(unsafe) needed: a nonisolated deinit may access Sendable stored
        // properties, and Task is Sendable. These are only mutated on the main actor.
        endpointTask?.cancel()
        stateTask?.cancel()
    }

    // MARK: - Scanning

    /// Starts scanning for Pico AI Homelab servers. Idempotent while already scanning.
    public func startScanning() async throws {
        guard endpointTask == nil else { return }
        startObserving()
        do {
            try await discovery.start()
        } catch {
            stopObserving()
            throw BonjourPicoError(from: error)
        }
    }

    /// Stops scanning and clears the discovered endpoints.
    public func stopScanning() async {
        stopObserving()
        await discovery.stop()
        endpoints = []
        state = nil
    }

    /// A direct async stream of endpoint snapshots, for callers that prefer async sequences
    /// over the observable `endpoints` property.
    public func endpointStream() async -> AsyncThrowingStream<[BonjourEndpoint], Error> {
        await discovery.serviceStream()
    }

    private func startObserving() {
        let discovery = self.discovery
        endpointTask = Task { [weak self] in
            // Re-subscribe across the actor's automatic restarts: the service stream
            // throws when the browser fails, after which the actor restarts itself.
            while !Task.isCancelled {
                let stream = await discovery.serviceStream()
                do {
                    for try await snapshot in stream {
                        self?.endpoints = snapshot
                    }
                    return // stream finished cleanly (scanning stopped)
                } catch {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
        stateTask = Task { [weak self] in
            let stream = await discovery.stateStream()
            for await newState in stream {
                self?.state = newState
            }
        }
    }

    private func stopObserving() {
        endpointTask?.cancel()
        endpointTask = nil
        stateTask?.cancel()
        stateTask = nil
    }

    // MARK: - Wake-on-LAN

    /// Sends a Wake-on-LAN magic packet to `endpoint`, which must advertise a `MACAddress`
    /// (the `macAddress` property). Because a sleeping server stops advertising and leaves
    /// `endpoints`, cache its `macAddress` (keyed by the stable `id`) before it disappears
    /// and reconstruct a `BonjourEndpoint` to wake it later.
    public func wake(_ endpoint: BonjourEndpoint) async throws {
        guard let mac = endpoint.macAddress else { throw BonjourPicoError.noMACAddress }
        let packet = try Self.magicPacket(for: mac)
        // sendMagicPacket performs a blocking BSD socket send; run it off the main actor.
        try await Task.detached { try Self.sendMagicPacket(packet) }.value
    }

    // Internal (not private) so tests can validate packet construction via @testable import.
    nonisolated static func magicPacket(for macString: String) throws -> Data {
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
        // Broadcast/entitlement denials surface as EPERM or EACCES (sendto to a
        // broadcast address commonly returns EACCES). Map both to the documented case.
        if err == EPERM || err == EACCES {
            return .broadcastNotPermitted
        }
        return .sendFailed(String(cString: strerror(err)))
    }
}
