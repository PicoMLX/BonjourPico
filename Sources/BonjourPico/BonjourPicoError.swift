import Foundation
import BonjourDiscoveryCore

/// Errors surfaced by the public `BonjourPico` API, covering both discovery and Wake-on-LAN.
public enum BonjourPicoError: Error, Sendable, Equatable, LocalizedError {
    // Discovery
    case invalidEndpoint
    case missingTXTRecord
    case browserFailed(String)
    case alreadyRunning
    case notRunning
    case cancelled
    case underlying(String)

    // Wake-on-LAN
    case noMACAddress
    case invalidMACAddress
    /// The OS refused to send the broadcast packet. On iOS this typically means the
    /// `com.apple.developer.networking.multicast` entitlement is missing.
    case broadcastNotPermitted
    /// Sending the magic packet failed. The associated value is the underlying system error.
    case sendFailed(String)

    /// Bridges lower-level errors (e.g. `BonjourDiscoveryError`) to the public error type.
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
            return String(localized: "Unexpected Bonjour endpoint payload.")
        case .missingTXTRecord:
            return String(localized: "Received incomplete Bonjour packet.")
        case .browserFailed(let message):
            return String(localized: "Bonjour browser failed: \(message).")
        case .alreadyRunning:
            return String(localized: "Bonjour scanning is already active.")
        case .notRunning:
            return String(localized: "Bonjour scanning is not active.")
        case .cancelled:
            return String(localized: "Bonjour scanning was cancelled.")
        case .underlying(let message):
            return message
        case .noMACAddress:
            return String(localized: "No MAC address available for Wake-on-LAN.")
        case .invalidMACAddress:
            return String(localized: "Invalid MAC address format.")
        case .broadcastNotPermitted:
            return String(localized: "Broadcasting is not permitted. iOS apps require the multicast networking entitlement to send Wake-on-LAN packets.")
        case .sendFailed(let message):
            return String(localized: "Failed to send Wake-on-LAN packet: \(message).")
        }
    }
}
