import Testing
import Foundation
import Network
@testable import BonjourPico
import BonjourDiscoveryCore

@Suite struct WakeOnLANTests {

    @Test func magicPacketForValidMAC() throws {
        let packet = try BonjourPico.magicPacket(for: "AA:BB:CC:DD:EE:FF")

        // 6 synchronization bytes (0xFF) followed by 16 repetitions of the MAC.
        #expect(packet.count == 6 + 16 * 6)

        let bytes = [UInt8](packet)
        #expect(Array(bytes.prefix(6)) == [UInt8](repeating: 0xFF, count: 6))

        let mac: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        for repetition in 0..<16 {
            let start = 6 + repetition * 6
            #expect(Array(bytes[start..<start + 6]) == mac)
        }
    }

    @Test func magicPacketAcceptsHyphenSeparator() throws {
        let colon = try BonjourPico.magicPacket(for: "AA:BB:CC:DD:EE:FF")
        let hyphen = try BonjourPico.magicPacket(for: "AA-BB-CC-DD-EE-FF")
        #expect(colon == hyphen)
    }

    @Test func magicPacketIsCaseInsensitive() throws {
        let upper = try BonjourPico.magicPacket(for: "AA:BB:CC:DD:EE:FF")
        let lower = try BonjourPico.magicPacket(for: "aa:bb:cc:dd:ee:ff")
        let mixed = try BonjourPico.magicPacket(for: "Aa:bB:Cc:dD:Ee:fF")
        #expect(lower == upper)
        #expect(mixed == upper)
    }

    @Test("Rejects MACs with the wrong number of components", arguments: [
        "AA:BB:CC:DD:EE", "AA:BB:CC:DD:EE:FF:11", ""
    ])
    func rejectsWrongComponentCount(mac: String) {
        #expect(throws: BonjourPicoError.invalidMACAddress) {
            try BonjourPico.magicPacket(for: mac)
        }
    }

    @Test("Rejects components that are not exactly two hex digits", arguments: [
        "A:BB:CC:DD:EE:FF", "AAA:BB:CC:DD:EE:FF"
    ])
    func rejectsWrongComponentLength(mac: String) {
        #expect(throws: BonjourPicoError.invalidMACAddress) {
            try BonjourPico.magicPacket(for: mac)
        }
    }

    @Test("Rejects non-hex components, including the +/- leading-sign hole", arguments: [
        "AA:BB:CC:DD:EE:+F", "AA:BB:CC:DD:EE:-F", "GG:BB:CC:DD:EE:FF", "ZZ:ZZ:ZZ:ZZ:ZZ:ZZ"
    ])
    func rejectsNonHexComponents(mac: String) {
        #expect(throws: BonjourPicoError.invalidMACAddress) {
            try BonjourPico.magicPacket(for: mac)
        }
    }
}

@Suite struct BonjourPicoErrorTests {

    @Test func equatable() {
        #expect(BonjourPicoError.broadcastNotPermitted == .broadcastNotPermitted)
        #expect(BonjourPicoError.sendFailed("boom") == .sendFailed("boom"))
        #expect(BonjourPicoError.sendFailed("a") != .sendFailed("b"))
        #expect(BonjourPicoError.invalidMACAddress != .noMACAddress)
    }

    @Test(arguments: [
        BonjourPicoError.invalidEndpoint, .missingTXTRecord, .browserFailed("x"),
        .alreadyRunning, .notRunning, .cancelled, .underlying("x"),
        .noMACAddress, .invalidMACAddress, .broadcastNotPermitted, .sendFailed("x")
    ])
    func hasLocalizedDescription(error: BonjourPicoError) throws {
        let description = try #require(error.errorDescription)
        #expect(!description.isEmpty)
    }

    @Test func sendFailedDescriptionIncludesUnderlyingMessage() {
        let description = BonjourPicoError.sendFailed("connection refused").errorDescription
        #expect(description?.contains("connection refused") == true)
    }

    @Test func bridgesDiscoveryErrors() {
        #expect(BonjourPicoError(from: BonjourDiscoveryError.alreadyRunning) == .alreadyRunning)
        #expect(BonjourPicoError(from: BonjourDiscoveryError.invalidEndpoint) == .invalidEndpoint)
        #expect(BonjourPicoError(from: BonjourDiscoveryError.missingTXTRecord) == .missingTXTRecord)
        // A BonjourPicoError passes through unchanged.
        #expect(BonjourPicoError(from: BonjourPicoError.noMACAddress) == .noMACAddress)
    }
}

@Suite struct BonjourEndpointTests {

    private func makeEndpoint(txt: [String: Data] = [:]) -> BonjourEndpoint {
        BonjourEndpoint(
            id: "id-1",
            name: "Ronald's Homelab",
            type: "_pico._tcp",
            domain: "local.",
            interfaceName: "en0",
            hostName: "host.local",
            ipAddresses: ["192.168.1.2"],
            port: 11434,
            txtRecord: txt
        )
    }

    @Test func memberwiseInitMapsEveryField() {
        let endpoint = makeEndpoint()
        #expect(endpoint.id == "id-1")
        #expect(endpoint.name == "Ronald's Homelab")
        #expect(endpoint.type == "_pico._tcp")
        #expect(endpoint.domain == "local.")
        #expect(endpoint.interfaceName == "en0")
        #expect(endpoint.hostName == "host.local")
        #expect(endpoint.ipAddresses == ["192.168.1.2"])
        #expect(endpoint.port == 11434)
    }

    @Test func macAddressDecodesFromTXTRecord() {
        let endpoint = makeEndpoint(txt: ["MACAddress": Data("AA:BB:CC:DD:EE:FF".utf8)])
        #expect(endpoint.macAddress == "AA:BB:CC:DD:EE:FF")
    }

    @Test func macAddressIsNilWhenAbsent() {
        #expect(makeEndpoint().macAddress == nil)
    }

    @Test func displayNameFallsBackWhenNameEmpty() {
        let named = makeEndpoint()
        #expect(named.displayName == "Ronald's Homelab")

        let unnamed = BonjourEndpoint(
            id: "id-2", name: "", type: "_pico._tcp", domain: "local.",
            interfaceName: nil, hostName: "fallback.local", ipAddresses: [], port: 0, txtRecord: [:]
        )
        #expect(unnamed.displayName == "fallback.local")
    }
}

@Suite struct BonjourTXTDecoderTests {

    private func metadata(_ entries: [String: String]) -> NWBrowser.Result.Metadata {
        .bonjour(NWTXTRecord(entries))
    }

    @Test func decodesStrings() throws {
        let decoder = BonjourTXTDecoder()
        let strings = try decoder.decodeStrings(from: metadata([
            "ServerIdentifier": "abc", "Port": "11434"
        ]))
        #expect(strings["ServerIdentifier"] == "abc")
        #expect(strings["Port"] == "11434")
    }

    @Test func decodesRawData() throws {
        let decoder = BonjourTXTDecoder()
        let record = try decoder.decodeTXTRecord(from: metadata(["MACAddress": "AA:BB:CC:DD:EE:FF"]))
        #expect(record["MACAddress"] == Data("AA:BB:CC:DD:EE:FF".utf8))
    }

    @Test func throwsWhenNoBonjourMetadata() {
        let decoder = BonjourTXTDecoder()
        #expect(throws: BonjourDiscoveryError.missingTXTRecord) {
            try decoder.decodeStrings(from: .none)
        }
    }
}
