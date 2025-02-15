//
//  PicoHomelabModel.swift
//  BonjourPico
//
//  Created by Ronald Mannak on 2/13/25.
//

import Foundation
import Network

public struct PicoHomelabModel: Hashable, Sendable, Identifiable {
    
    /// Persistent identifier of the server
    /// Use this identifier to recognize servers even their name, hostname or ip address changes
    public let id: String
    
    /// Human readable name, e.g. `Ronald's Homelab`
    public let name: String
    
    /// Bonjour service type. Should always be `_pico._tcp`
    public let type: String

    /// Local domain name
    public let hostName: String
    
    /// IP address of Pico AI Homelab
    public let ipAddress: String

    /// Port used by Pico AI Homelab
    public let port: Int
    
    public init(serverId: String, name: String, type: String, domain: String, ipAddress: String, port: Int) {
        self.id = serverId
        self.name = name
        self.type = type
        self.hostName = domain
        self.ipAddress = ipAddress
        self.port = port
    }
    
    public init(result: NWBrowser.Result) throws {
        guard
            case .service(let name, let type, let domain, let interface) = result.endpoint,
            case let NWBrowser.Result.Metadata.bonjour(txtRecord) = result.metadata else {
            throw BonjourPicoError.invalidEndpoint
        }
        guard
            let id = txtRecord["ServerIdentifier"],
            let ipAddress = txtRecord["IPAddress"],
            let localHostName = txtRecord["LocalHostName"],
            let portString = txtRecord["Port"],
            let port = Int(portString) else {
            throw BonjourPicoError.noTxtRecord
        }
        self.id = id
        self.name = name
        self.type = type
        self.hostName = localHostName
        self.ipAddress = ipAddress
        self.port = port
    }
}

extension PicoHomelabModel: Equatable {}
