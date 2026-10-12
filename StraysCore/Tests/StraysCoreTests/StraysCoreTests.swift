import XCTest
@testable import StraysCore

final class StraysCoreTests: XCTestCase {
    func testVersionIsSemantic() {
        let parts = StraysCore.version.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { Int($0) != nil })
    }
}
