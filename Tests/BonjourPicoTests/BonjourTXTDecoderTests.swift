import XCTest
import Network
@testable import BonjourDiscoveryCore

final class BonjourTXTDecoderTests: XCTestCase {
    func testDecodeStrings() throws {
        var txt = NWTXTRecord()
        txt["ServerIdentifier"] = "abc123"
        txt["IPAddress"] = "192.168.1.4"
        let decoder = BonjourTXTDecoder()
        let metadata = NWBrowser.Result.Metadata.bonjour(txt)
        let values = try decoder.decodeStrings(from: metadata)
        XCTAssertEqual(values["ServerIdentifier"], "abc123")
        XCTAssertEqual(values["IPAddress"], "192.168.1.4")
    }

    func testValueTransform() throws {
        var txt = NWTXTRecord()
        txt["Port"] = "8080"
        let decoder = BonjourTXTDecoder()
        let metadata = NWBrowser.Result.Metadata.bonjour(txt)
        let port: Int? = try decoder.value(forKey: "Port", in: metadata) { Int($0) }
        XCTAssertEqual(port, 8080)
    }
}
