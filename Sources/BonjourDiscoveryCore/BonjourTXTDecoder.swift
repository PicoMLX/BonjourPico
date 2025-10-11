import Foundation
import Network

public struct BonjourTXTDecoder: Sendable {
    public static let shared = BonjourTXTDecoder()

    public init() {}

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

    public func value<T>(forKey key: String, in metadata: NWBrowser.Result.Metadata, transform: (String) -> T?) throws -> T? {
        let strings = try decodeStrings(from: metadata)
        guard let value = strings[key] else {
            return nil
        }
        return transform(value)
    }
}
