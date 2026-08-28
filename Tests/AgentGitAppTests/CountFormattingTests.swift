import XCTest
@testable import AgentGitApp

final class CountFormattingTests: XCTestCase {
    func testFormatsSingularPluralAndExplicitPlural() {
        XCTAssertEqual(countedLabel(0, singular: "file"), "0 files")
        XCTAssertEqual(countedLabel(1, singular: "file"), "1 file")
        XCTAssertEqual(countedLabel(2, singular: "file"), "2 files")
        XCTAssertEqual(
            countedLabel(2, singular: "branch", plural: "branches"),
            "2 branches"
        )
    }
}
