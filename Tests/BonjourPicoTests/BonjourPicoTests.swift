import XCTest
@testable import BonjourPico

final class BonjourPicoTests: XCTestCase {

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

    func testMagicPacketForValidMAC() throws {
        let packet = try BonjourPico.magicPacket(for: "AA:BB:CC:DD:EE:FF")

        // 6 synchronization bytes (0xFF) followed by 16 repetitions of the MAC.
        XCTAssertEqual(packet.count, 6 + 16 * 6)

        let bytes = [UInt8](packet)
        XCTAssertEqual(Array(bytes.prefix(6)), [UInt8](repeating: 0xFF, count: 6))

        let mac: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        for repetition in 0..<16 {
            let start = 6 + repetition * 6
            XCTAssertEqual(Array(bytes[start..<start + 6]), mac)
        }
    }

    func testMagicPacketAcceptsHyphenSeparator() throws {
        let colon = try BonjourPico.magicPacket(for: "AA:BB:CC:DD:EE:FF")
        let hyphen = try BonjourPico.magicPacket(for: "AA-BB-CC-DD-EE-FF")
        XCTAssertEqual(colon, hyphen)
    }

    func testMagicPacketIsCaseInsensitive() throws {
        let upper = try BonjourPico.magicPacket(for: "AA:BB:CC:DD:EE:FF")
        let lower = try BonjourPico.magicPacket(for: "aa:bb:cc:dd:ee:ff")
        let mixed = try BonjourPico.magicPacket(for: "Aa:bB:Cc:dD:Ee:fF")
        XCTAssertEqual(upper, lower)
        XCTAssertEqual(upper, mixed)
    }

    func testMagicPacketRejectsWrongComponentCount() {
        for mac in ["AA:BB:CC:DD:EE", "AA:BB:CC:DD:EE:FF:11", ""] {
            XCTAssertThrowsError(try BonjourPico.magicPacket(for: mac)) { error in
                XCTAssertEqual(error as? BonjourPicoError, .invalidMACAddress, "mac: \(mac)")
            }
        }
    }

    func testMagicPacketRejectsWrongComponentLength() {
        // Components must be exactly two hex digits.
        for mac in ["A:BB:CC:DD:EE:FF", "AAA:BB:CC:DD:EE:FF"] {
            XCTAssertThrowsError(try BonjourPico.magicPacket(for: mac)) { error in
                XCTAssertEqual(error as? BonjourPicoError, .invalidMACAddress, "mac: \(mac)")
            }
        }
    }

    func testMagicPacketRejectsNonHexComponents() {
        // The leading-sign hole: UInt8("+F", radix: 16) parses successfully, so this
        // must be rejected explicitly by the isHexDigit check.
        for mac in ["AA:BB:CC:DD:EE:+F", "AA:BB:CC:DD:EE:-F", "GG:BB:CC:DD:EE:FF", "ZZ:ZZ:ZZ:ZZ:ZZ:ZZ"] {
            XCTAssertThrowsError(try BonjourPico.magicPacket(for: mac)) { error in
                XCTAssertEqual(error as? BonjourPicoError, .invalidMACAddress, "mac: \(mac)")
            }
        }
    }

    // MARK: - Error type

    func testErrorEquatable() {
        XCTAssertEqual(BonjourPicoError.broadcastNotPermitted, .broadcastNotPermitted)
        XCTAssertEqual(BonjourPicoError.sendFailed("boom"), .sendFailed("boom"))
        XCTAssertNotEqual(BonjourPicoError.sendFailed("a"), .sendFailed("b"))
        XCTAssertNotEqual(BonjourPicoError.invalidMACAddress, .noMACAddress)
    }

    func testAllErrorsHaveLocalizedDescriptions() {
        let errors: [BonjourPicoError] = [
            .internalError, .invalidEndpoint, .couldNotConnect, .connectionCancelled,
            .noTxtRecord, .noMACAddress, .invalidMACAddress, .broadcastNotPermitted,
            .sendFailed("underlying error")
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "\(error) should have a description")
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "\(error) description empty")
        }
    }

    func testSendFailedDescriptionIncludesUnderlyingMessage() {
        let description = BonjourPicoError.sendFailed("connection refused").errorDescription
        XCTAssertEqual(description?.contains("connection refused"), true)
    }

    // MARK: - Model

    func testModelMemberwiseInit() {
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
        XCTAssertEqual(model.id, "id-1")
        XCTAssertEqual(model.name, "Ronald's Homelab")
        XCTAssertEqual(model.type, "_pico._tcp")
        XCTAssertEqual(model.hostName, "host.local")
        XCTAssertEqual(model.ipAddress, "192.168.1.2")
        XCTAssertEqual(model.port, 11434)
        XCTAssertEqual(model.macAddress, "AA:BB:CC:DD:EE:FF")
    }

    // MARK: - Server list dedup

    @MainActor
    func testUpsertAppendsDistinctServers() {
        let pico = BonjourPico()
        pico.upsert(makeModel(id: "a"))
        pico.upsert(makeModel(id: "b"))
        XCTAssertEqual(pico.servers.map(\.id), ["a", "b"])
    }

    @MainActor
    func testUpsertReplacesSameIdentifier() {
        let pico = BonjourPico()
        pico.upsert(makeModel(id: "a", name: "Old Name"))
        pico.upsert(makeModel(id: "a", name: "New Name"))
        XCTAssertEqual(pico.servers.count, 1)
        XCTAssertEqual(pico.servers.first?.name, "New Name")
    }

    @MainActor
    func testRemoveByIdentifier() {
        let pico = BonjourPico()
        pico.upsert(makeModel(id: "a"))
        pico.upsert(makeModel(id: "b"))
        pico.removeServer(id: "a")
        XCTAssertEqual(pico.servers.map(\.id), ["b"])
    }

    @MainActor
    func testRemoveByNameAndType() {
        let pico = BonjourPico()
        pico.upsert(makeModel(id: "a", name: "Homelab", type: "_pico._tcp"))
        pico.upsert(makeModel(id: "b", name: "Other", type: "_pico._tcp"))
        pico.removeServer(name: "Homelab", type: "_pico._tcp")
        XCTAssertEqual(pico.servers.map(\.id), ["b"])
    }

    /// Reproduces the bug fixed in the original review: when a service's advertised
    /// ServerIdentifier changes, a `.changed` event removes the old entry and adds the
    /// new one. Removing by `old` (not `new`) must leave no stale duplicate.
    @MainActor
    func testChangedIdentifierLeavesNoStaleDuplicate() {
        let pico = BonjourPico()
        pico.upsert(makeModel(id: "old-id", name: "Server"))

        // Simulate the .changed handler: removeServer(result: old) then addServer(result: new).
        pico.removeServer(id: "old-id")
        pico.upsert(makeModel(id: "new-id", name: "Server"))

        XCTAssertEqual(pico.servers.map(\.id), ["new-id"])
    }
}
