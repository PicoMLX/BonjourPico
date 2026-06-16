import Foundation
import Network

/// Decodes `NWBrowser.Result.Metadata` Bonjour TXT records into typed dictionaries.
/// Stateless and `Sendable` so it can be shared across the discovery actor and tests.
public struct BonjourTXTDecoder: Sendable {
    public static let shared = BonjourTXTDecoder()

    public init() {}

    /// Returns the raw TXT entries as `Data` values.
    public func decodeTXTRecord(from metadata: NWBrowser.Result.Metadata) throws -> [String: Data] {
        guard case let .bonjour(record) = metadata else {
            throw BonjourDiscoveryError.missingTXTRecord
        }

        var dictionary: [String: Data] = [:]
        for entry in record {
            switch entry.value {
            case .string(let string):
                dictionary[entry.key] = Data(string.utf8)
            case .data(let data):
                dictionary[entry.key] = data
            case .empty:
                dictionary[entry.key] = Data()
            case .none:
                continue
            @unknown default:
                continue
            }
        }
        return dictionary
    }

    /// Returns the TXT entries decoded as strings.
    public func decodeStrings(from metadata: NWBrowser.Result.Metadata, encoding: String.Encoding = .utf8) throws -> [String: String] {
        guard case let .bonjour(record) = metadata else {
            throw BonjourDiscoveryError.missingTXTRecord
        }

        var dictionary: [String: String] = [:]
        for entry in record {
            switch entry.value {
            case .string(let string):
                dictionary[entry.key] = string
            case .data(let data):
                dictionary[entry.key] = String(data: data, encoding: encoding)
            case .empty:
                dictionary[entry.key] = ""
            case .none:
                continue
            @unknown default:
                continue
            }
        }
        return dictionary
    }
}
