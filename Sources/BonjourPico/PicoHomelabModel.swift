//
//  PicoHomelabModel.swift
//  BonjourPico
//
//  Created by Ronald Mannak on 2/13/25.
//

import Foundation
import Network

public struct PicoHomelabModel: Hashable, Sendable {
    
    /// Human readable name, e.g. `Ronald's Homelab`
    public let name: String
    
    /// Bonjour service type. Should always be `_pico._tcp`
    public let type: String

    /// Local domain name
    public let domain: String
    
    /// IP address of Pico AI Homelab
    public let ipAddress: String

    /// Port used by Pico AI Homelab
    public let port: Int
    
    public init(name: String, type: String, domain: String, ipAddress: String, port: Int) {
        self.name = name
        self.type = type
        self.domain = domain
        self.ipAddress = ipAddress
        self.port = port
    }
}

extension PicoHomelabModel: Equatable {}
