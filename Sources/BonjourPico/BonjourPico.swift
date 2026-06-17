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

    /// True for the lifetime of a scan session — from `startScanning()` until
    /// `stopScanning()` — including while the browser is transiently `.failed` and
    /// automatically retrying. Drive a Scan/Stop button off this so users can always
    /// stop an active (or retrying) scan.
    public private(set) var isScanning = false

    @ObservationIgnored private let discovery: BonjourDiscoveryActor
    @ObservationIgnored private var endpointTask: Task<Void, Never>?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    // Bumped by stopScanning() so an in-flight startScanning() that resumes afterwards
    // doesn't flip isScanning back on for a scan that was already stopped.
    @ObservationIgnored private var scanGeneration = 0

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
        scanGeneration += 1
        let generation = scanGeneration
        startObserving()
        let startedGeneration: Int
        do {
            startedGeneration = try await discovery.start()
        } catch {
            // Only roll back if this start wasn't superseded by a stop/restart.
            if generation == scanGeneration { stopObserving() }
            throw BonjourPicoError(from: error)
        }
        // If stopScanning() ran while start() was suspended, the browser we just started is
        // orphaned — the facade isn't observing it and isScanning would be wrong. Tear down
        // exactly that browser (only if it hasn't already been replaced by a newer scan) and
        // bail, rather than leaving a browser running with no observer.
        guard generation == scanGeneration else {
            await discovery.stop(ifGeneration: startedGeneration)
            return
        }
        isScanning = true
    }

    /// Stops scanning and clears the discovered endpoints.
    public func stopScanning() async {
        scanGeneration += 1
        let generation = scanGeneration
        stopObserving()
        await discovery.stop()
        // If a newer startScanning() superseded this stop while it was suspended at
        // discovery.stop(), don't clobber the new scan's facade state — doing so would leave the
        // facade reporting a stopped, empty scan while the actor has an active browser.
        guard generation == scanGeneration else { return }
        isScanning = false
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
            // The actor keeps this stream open across automatic restarts and finishes it
            // only on stop(), so a single loop suffices.
            let stream = await discovery.serviceStream()
            do {
                for try await snapshot in stream {
                    self?.endpoints = snapshot
                }
            } catch {
                // Stream finished with an error; browser state is mirrored via stateTask.
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
