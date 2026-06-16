import Testing
import Foundation
@testable import BonjourPico

@Suite struct BonjourPicoTests {

    // MARK: - Helpers

    private func makeModel(
        id: String,
        name: String = "Test Homelab",
        type: String = "_pico._tcp"
    ) -> PicoHomelabModel {
        PicoHomelabModel(
            serverId: id,
            name: name,
            type: type,
            domain: "\(id).local",
            ipAddress: "192.168.1.2",
            port: 11434,
            macAddress: nil
        )
    }

    // MARK: - Wake-on-LAN magic packet

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
        "AA:BB:CC:DD:EE",        // too few
        "AA:BB:CC:DD:EE:FF:11",  // too many
        ""                       // empty
    ])
    func magicPacketRejectsWrongComponentCount(mac: String) {
        #expect(throws: BonjourPicoError.invalidMACAddress) {
            try BonjourPico.magicPacket(for: mac)
        }
    }

    @Test("Rejects components that are not exactly two hex digits", arguments: [
        "A:BB:CC:DD:EE:FF",
        "AAA:BB:CC:DD:EE:FF"
    ])
    func magicPacketRejectsWrongComponentLength(mac: String) {
        #expect(throws: BonjourPicoError.invalidMACAddress) {
            try BonjourPico.magicPacket(for: mac)
        }
    }

    @Test("Rejects non-hex components, including the +/- leading-sign hole", arguments: [
        "AA:BB:CC:DD:EE:+F",
        "AA:BB:CC:DD:EE:-F",
        "GG:BB:CC:DD:EE:FF",
        "ZZ:ZZ:ZZ:ZZ:ZZ:ZZ"
    ])
    func magicPacketRejectsNonHexComponents(mac: String) {
        #expect(throws: BonjourPicoError.invalidMACAddress) {
            try BonjourPico.magicPacket(for: mac)
        }
    }

    // MARK: - Error type

    @Test func errorEquatable() {
        #expect(BonjourPicoError.broadcastNotPermitted == .broadcastNotPermitted)
        #expect(BonjourPicoError.sendFailed("boom") == .sendFailed("boom"))
        #expect(BonjourPicoError.sendFailed("a") != .sendFailed("b"))
        #expect(BonjourPicoError.invalidMACAddress != .noMACAddress)
    }

    @Test(arguments: [
        BonjourPicoError.internalError, .invalidEndpoint, .couldNotConnect, .connectionCancelled,
        .noTxtRecord, .noMACAddress, .invalidMACAddress, .broadcastNotPermitted,
        .sendFailed("underlying error")
    ])
    func errorHasLocalizedDescription(error: BonjourPicoError) throws {
        let description = try #require(error.errorDescription)
        #expect(!description.isEmpty)
    }

    @Test func sendFailedDescriptionIncludesUnderlyingMessage() {
        let description = BonjourPicoError.sendFailed("connection refused").errorDescription
        #expect(description?.contains("connection refused") == true)
    }

    // MARK: - Model

    @Test func modelMemberwiseInit() {
        // Pass a distinct value for every parameter to verify each maps to the
        // correct property, including serverId -> id and domain -> hostName.
        let model = PicoHomelabModel(
            serverId: "id-1",
            name: "Ronald's Homelab",
            type: "_pico._tcp",
            domain: "host.local",
            ipAddress: "192.168.1.2",
            port: 11434,
            macAddress: "AA:BB:CC:DD:EE:FF"
        )
        #expect(model.id == "id-1")
        #expect(model.name == "Ronald's Homelab")
        #expect(model.type == "_pico._tcp")
        #expect(model.hostName == "host.local")
        #expect(model.ipAddress == "192.168.1.2")
        #expect(model.port == 11434)
        #expect(model.macAddress == "AA:BB:CC:DD:EE:FF")
    }

    // MARK: - Server list dedup

    @Test @MainActor func upsertAppendsDistinctServers() {
        let pico = BonjourPico()
        pico.upsert(makeModel(id: "a"))
        pico.upsert(makeModel(id: "b"))
        #expect(pico.servers.map(\.id) == ["a", "b"])
    }

    @Test @MainActor func upsertReplacesSameIdentifier() {
        let pico = BonjourPico()
        pico.upsert(makeModel(id: "a", name: "Old Name"))
        pico.upsert(makeModel(id: "a", name: "New Name"))
        #expect(pico.servers.count == 1)
        #expect(pico.servers.first?.name == "New Name")
    }

    @Test @MainActor func upsertReplacesInPlacePreservingOrder() {
        let pico = BonjourPico()
        pico.upsert(makeModel(id: "a"))
        pico.upsert(makeModel(id: "b", name: "Old Name"))
        pico.upsert(makeModel(id: "c"))

        // Updating "b" must keep its position rather than moving it to the end.
        pico.upsert(makeModel(id: "b", name: "New Name"))

        #expect(pico.servers.map(\.id) == ["a", "b", "c"])
        #expect(pico.servers[1].name == "New Name")
    }

    @Test @MainActor func removeByIdentifier() {
        let pico = BonjourPico()
        pico.upsert(makeModel(id: "a"))
        pico.upsert(makeModel(id: "b"))
        pico.removeServer(id: "a")
        #expect(pico.servers.map(\.id) == ["b"])
    }

    @Test @MainActor func removeByNameAndType() {
        let pico = BonjourPico()
        pico.upsert(makeModel(id: "a", name: "Homelab", type: "_pico._tcp"))
        pico.upsert(makeModel(id: "b", name: "Other", type: "_pico._tcp"))
        pico.removeServer(name: "Homelab", type: "_pico._tcp")
        #expect(pico.servers.map(\.id) == ["b"])
    }

    /// Regression test for the bug fixed in #2: when a service's advertised
    /// ServerIdentifier changes, the `.changed` handler removes the old entry and adds
    /// the new one. Removing by `old` (not `new`) must leave no stale duplicate.
    @Test @MainActor func changedIdentifierLeavesNoStaleDuplicate() {
        let pico = BonjourPico()
        pico.upsert(makeModel(id: "old-id", name: "Server"))

        // Simulate the .changed handler: removeServer(result: old) then addServer(result: new).
        pico.removeServer(id: "old-id")
        pico.upsert(makeModel(id: "new-id", name: "Server"))

        #expect(pico.servers.map(\.id) == ["new-id"])
    }
}
