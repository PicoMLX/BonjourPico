import XCTest
@testable import BonjourPico
import BonjourDiscoveryCore
import Network

final class BonjourPicoErrorTests: XCTestCase {
    func testMappingFromDiscoveryError() {
        let error = BonjourPicoError(from: BonjourDiscoveryError.invalidEndpoint)
        XCTAssertEqual(error, .invalidEndpoint)
    }

    func testBrowserFailedWrapsMessage() {
        let error = BonjourPicoError(from: BonjourDiscoveryError.browserFailed(NWError.posix(.ECONNABORTED)))
        if case .browserFailed(let message) = error {
            XCTAssertFalse(message.isEmpty)
        } else {
            XCTFail("Expected browserFailed")
        }
    }

    func testUnderlyingErrorFallback() {
        struct Dummy: Error {}
        let error = BonjourPicoError(from: Dummy())
        if case .underlying(let message) = error {
            XCTAssertTrue(message.contains("Dummy"))
        } else {
            XCTFail("Expected underlying")
        }
    }
}
