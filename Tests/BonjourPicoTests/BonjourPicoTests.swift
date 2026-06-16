import XCTest
@testable import BonjourPico

final class BonjourPicoTests: XCTestCase {

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

    func testMagicPacketRejectsWrongComponentCount() {
        XCTAssertThrowsError(try BonjourPico.magicPacket(for: "AA:BB:CC:DD:EE")) { error in
            XCTAssertEqual(error as? BonjourPicoError, .invalidMACAddress)
        }
    }

    func testMagicPacketRejectsNonHexComponents() {
        // The leading-sign hole that the validation fix closes: UInt8("+F", radix: 16)
        // parses successfully, so this must be rejected explicitly.
        XCTAssertThrowsError(try BonjourPico.magicPacket(for: "AA:BB:CC:DD:EE:+F")) { error in
            XCTAssertEqual(error as? BonjourPicoError, .invalidMACAddress)
        }
        XCTAssertThrowsError(try BonjourPico.magicPacket(for: "GG:BB:CC:DD:EE:FF")) { error in
            XCTAssertEqual(error as? BonjourPicoError, .invalidMACAddress)
        }
    }

    // MARK: - Error descriptions

    func testErrorDescriptionsAreLocalized() {
        XCTAssertNotNil(BonjourPicoError.broadcastNotPermitted.errorDescription)
        let sendFailed = BonjourPicoError.sendFailed("connection refused")
        XCTAssertEqual(sendFailed.errorDescription?.contains("connection refused"), true)
    }

    // MARK: - Model

    func testModelMemberwiseInit() {
        let model = PicoHomelabModel(
            serverId: "id-1",
            name: "Test Homelab",
            type: "_pico._tcp",
            domain: "host.local",
            ipAddress: "192.168.1.2",
            port: 11434,
            macAddress: "AA:BB:CC:DD:EE:FF"
        )
        XCTAssertEqual(model.id, "id-1")
        XCTAssertEqual(model.hostName, "host.local")
        XCTAssertEqual(model.port, 11434)
        XCTAssertEqual(model.macAddress, "AA:BB:CC:DD:EE:FF")
    }
}
