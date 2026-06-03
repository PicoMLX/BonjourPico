//
//  File.swift
//  BonjourPico
//
//  Created by Ronald Mannak on 2/13/25.
//

import Foundation

enum BonjourPicoError: Error {
    case internalError
    case invalidEndpoint
    case couldNotConnect
    case connectionCancelled
    case noTxtRecord
    case noMACAddress
    case invalidMACAddress
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
        }
    }
}
