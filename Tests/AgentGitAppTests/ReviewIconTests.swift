import AppKit
import XCTest
@testable import AgentGitApp

@MainActor
final class ReviewIconTests: XCTestCase {
    func testEveryControlIconLoadsAndRendersFromTheResourceBundle() throws {
        for icon in ReviewIcon.allCases {
            let url = try XCTUnwrap(icon.resourceURL, "Missing SVG for \(icon.rawValue)")
            let source = try XCTUnwrap(NSImage(contentsOf: url))
            XCTAssertTrue(source.isValid)
            XCTAssertNotNil(source.tiffRepresentation)
            XCTAssertTrue(icon.image.isTemplate)
            XCTAssertTrue(icon.image === icon.image)
        }
    }
}
