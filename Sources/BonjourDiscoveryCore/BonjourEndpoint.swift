import Foundation
import Network

/// An immutable, `Sendable` snapshot of a discovered Bonjour service.
///
/// The pico-specific TXT keys (`ServerIdentifier`, `LocalHostName`, `IPAddress`, `Port`)
/// are mapped to typed fields; the full TXT record is retained in `txtRecord` so callers
/// can read additional keys (for example `MACAddress` for Wake-on-LAN).
public struct BonjourEndpoint: Identifiable, Hashable, Sendable {
    /// Stable identifier (the `ServerIdentifier` TXT value), consistent across IP/host changes.
    public let id: String
    public let name: String
    public let type: String
    public let domain: String
    public let interfaceName: String?
    public let hostName: String?
    public let ipAddresses: [String]
    public let port: UInt16
    public let txtRecord: [String: Data]

    public init(result: NWBrowser.Result, decoder: BonjourTXTDecoder = .shared) throws {
        guard case let .service(name, type, domain, interface) = result.endpoint else {
            throw BonjourDiscoveryError.invalidEndpoint
        }

        let txtRecord = try decoder.decodeTXTRecord(from: result.metadata)
        let strings = try decoder.decodeStrings(from: result.metadata)

        // Reject incomplete advertisements, matching the previous model which discarded
        // packets missing the fields clients rely on. A usable Pico endpoint needs:
        //  - a stable ServerIdentifier (the documented `id` contract),
        //  - a valid non-zero port, and
        //  - at least one way to reach it: a non-empty host name or an IP.
        guard let id = strings[Keys.serverIdentifier], !id.isEmpty else {
            throw BonjourDiscoveryError.missingTXTRecord
        }
        guard let port = Self.parsePort(from: strings[Keys.port]), port != 0 else {
            throw BonjourDiscoveryError.missingTXTRecord
        }
        let hostName = Self.normalizedHost(strings[Keys.localHostName] ?? strings[Keys.hostName])
        let ipAddresses = Self.parseAddresses(from: strings[Keys.ipAddress])
        guard hostName != nil || !ipAddresses.isEmpty else {
            throw BonjourDiscoveryError.missingTXTRecord
        }

        self.id = id
        self.name = strings[Keys.displayName] ?? name
        self.type = type
        self.domain = domain
        self.interfaceName = interface?.name
        self.hostName = hostName
        self.ipAddresses = ipAddresses
        self.port = port
        self.txtRecord = txtRecord
    }

    public init(
        id: String,
        name: String,
        type: String,
        domain: String,
        interfaceName: String?,
        hostName: String?,
        ipAddresses: [String],
        port: UInt16,
        txtRecord: [String: Data]
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.domain = domain
        self.interfaceName = interfaceName
        self.hostName = hostName
        self.ipAddresses = ipAddresses
        self.port = port
        self.txtRecord = txtRecord
    }

    /// A human-readable label, falling back to the host name or identifier.
    public var displayName: String {
        if !name.isEmpty {
            return name
        }
        if let hostName {
            return hostName
        }
        return id
    }

    /// The advertised MAC address (`MACAddress` TXT key), used for Wake-on-LAN.
    /// Nil when the server does not advertise it.
    public var macAddress: String? {
        guard let data = txtRecord[Keys.macAddress] else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private enum Keys {
        static let serverIdentifier = "ServerIdentifier"
        static let displayName = "DisplayName"
        static let localHostName = "LocalHostName"
        static let hostName = "HostName"
        static let ipAddress = "IPAddress"
        static let port = "Port"
        static let macAddress = "MACAddress"
    }

    private static func parseAddresses(from value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func parsePort(from value: String?) -> UInt16? {
        guard let value else { return nil }
        return UInt16(value)
    }

    /// Trims whitespace and returns nil for an empty/whitespace-only host so a blank
    /// LocalHostName/HostName isn't treated as a reachable address.
    private static func normalizedHost(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
