import Foundation
import Network

/// Errors surfaced by the low-level `BonjourDiscoveryActor`.
public enum BonjourDiscoveryError: Error, Sendable, Equatable {
    case invalidEndpoint
    case missingTXTRecord
    case browserFailed(NWError)
    case alreadyRunning
    case notRunning

    public static func == (lhs: BonjourDiscoveryError, rhs: BonjourDiscoveryError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidEndpoint, .invalidEndpoint),
             (.missingTXTRecord, .missingTXTRecord),
             (.alreadyRunning, .alreadyRunning),
             (.notRunning, .notRunning):
            return true
        case (.browserFailed(let left), .browserFailed(let right)):
            return left == right
        default:
            return false
        }
    }
}
