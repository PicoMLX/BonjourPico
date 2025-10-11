import Foundation
import BonjourDiscoveryCore

public enum BonjourPicoError: Error, Sendable, Equatable, LocalizedError {
    case invalidEndpoint
    case missingTXTRecord
    case browserFailed(String)
    case alreadyRunning
    case notRunning
    case cancelled
    case underlying(String)

    public init(from error: Error) {
        if let picoError = error as? BonjourPicoError {
            self = picoError
            return
        }
        if let discoveryError = error as? BonjourDiscoveryError {
            switch discoveryError {
            case .invalidEndpoint:
                self = .invalidEndpoint
            case .missingTXTRecord:
                self = .missingTXTRecord
            case .browserFailed(let nwError):
                self = .browserFailed(nwError.localizedDescription)
            case .alreadyRunning:
                self = .alreadyRunning
            case .notRunning:
                self = .notRunning
            }
            return
        }
        if (error as NSError).code == NSUserCancelledError {
            self = .cancelled
            return
        }
        self = .underlying(String(describing: error))
    }

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Unexpected Bonjour endpoint payload."
        case .missingTXTRecord:
            return "Bonjour TXT record is missing required keys."
        case .browserFailed(let message):
            return "Bonjour browser failed: \(message)."
        case .alreadyRunning:
            return "Bonjour scanning is already active."
        case .notRunning:
            return "Bonjour scanning is not active."
        case .cancelled:
            return "Bonjour scanning was cancelled."
        case .underlying(let message):
            return message
        }
    }
}
