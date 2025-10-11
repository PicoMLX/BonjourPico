import Foundation
import Network

public struct BonjourEndpoint: Identifiable, Hashable, Sendable {
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

        self.id = strings[Keys.serverIdentifier] ?? [name, type, domain].joined(separator: "-")
        self.name = strings[Keys.displayName] ?? name
        self.type = type
        self.domain = domain
        self.interfaceName = interface?.name
        self.hostName = strings[Keys.localHostName] ?? strings[Keys.hostName]
        self.ipAddresses = Self.parseAddresses(from: strings[Keys.ipAddress])
        self.port = Self.parsePort(from: strings[Keys.port])
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

    public var displayName: String {
        if !name.isEmpty {
            return name
        }
        if let hostName {
            return hostName
        }
        return id
    }

    private enum Keys {
        static let serverIdentifier = "ServerIdentifier"
        static let displayName = "DisplayName"
        static let localHostName = "LocalHostName"
        static let hostName = "HostName"
        static let ipAddress = "IPAddress"
        static let port = "Port"
    }

    private static func parseAddresses(from value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func parsePort(from value: String?) -> UInt16 {
        guard let value, let parsed = UInt16(value) else {
            return 0
        }
        return parsed
    }
}
