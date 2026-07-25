import XCTest
@testable import SwiftMindCore

final class SmokeTests: XCTestCase {
    func testNodeIDGenerateIsStableFormat() {
        let id = NodeID.generate()
        XCTAssertTrue(id.rawValue.hasPrefix("n_"))
        XCTAssertEqual(id.rawValue.count, 18) // "n_" + 16 hex chars
    }
}
