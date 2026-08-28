import Foundation
import XCTest
@testable import AgentGitApp

final class RelativeTimeFormattingTests: XCTestCase {
    func testFormatsRecentActivityWithoutLiveSecondUpdates() {
        let now = Date(timeIntervalSince1970: 2_000_000)

        XCTAssertEqual(compactRelativeTime(now, relativeTo: now), "now")
        XCTAssertEqual(
            compactRelativeTime(now.addingTimeInterval(-59), relativeTo: now),
            "now"
        )
        XCTAssertEqual(
            compactRelativeTime(now.addingTimeInterval(-60), relativeTo: now),
            "1m"
        )
        XCTAssertEqual(
            compactRelativeTime(now.addingTimeInterval(-3_599), relativeTo: now),
            "59m"
        )
        XCTAssertEqual(
            compactRelativeTime(now.addingTimeInterval(-3_600), relativeTo: now),
            "1h"
        )
        XCTAssertEqual(
            compactRelativeTime(now.addingTimeInterval(-86_400), relativeTo: now),
            "1d"
        )
        XCTAssertEqual(
            compactRelativeTime(now.addingTimeInterval(60), relativeTo: now),
            "now"
        )
    }
}
