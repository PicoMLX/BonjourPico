//
//  File.swift
//  BonjourPico
//
//  Created by Ronald Mannak on 2/13/25.
//

import Foundation

public enum BonjourPicoError: Error, Equatable {
    case internalError
    case invalidEndpoint
    case couldNotConnect
    case connectionCancelled
    case noTxtRecord
    case noMACAddress
    case invalidMACAddress
    /// The OS refused to send the broadcast packet. On iOS this typically means the
    /// `com.apple.developer.networking.multicast` entitlement is missing.
    case broadcastNotPermitted
    /// Sending the magic packet failed. The associated value is the underlying system error.
    case sendFailed(String)
}

extension BonjourPicoError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .internalError:
            return String(localized: "Internal error")
        case .invalidEndpoint:
            return String(localized: "Invalid endpoint")
        case .couldNotConnect:
            return String(localized: "Could not connect to Pico AI Homelab server")
        case .connectionCancelled:
            return String(localized: "Connection cancelled")
        case .noTxtRecord:
            return String(localized: "Received incomplete Bonjour packet")
        case .noMACAddress:
            return String(localized: "No MAC address available for Wake-on-LAN")
        case .invalidMACAddress:
            return String(localized: "Invalid MAC address format")
        case .broadcastNotPermitted:
            return String(localized: "Broadcasting is not permitted. iOS apps require the multicast networking entitlement to send Wake-on-LAN packets.")
        case .sendFailed(let message):
            return String(localized: "Failed to send Wake-on-LAN packet: \(message)")
        }
    }
}
