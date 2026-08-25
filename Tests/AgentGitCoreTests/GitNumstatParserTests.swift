import Foundation
import XCTest
@testable import AgentGitCore

final class GitNumstatParserTests: XCTestCase {
    func testParsesTextBinaryAndRenameRecords() throws {
        let output = """
        12\t3\tSources/App/Main.swift
        -\t-\tAssets/icon.png
        4\t0\tDocs/{old => new}/README.md
        """
        let stat = try GitNumstatParser.parse(Data(output.utf8))

        XCTAssertEqual(stat.addedLineCount, 16)
        XCTAssertEqual(stat.deletedLineCount, 3)
    }

    func testEmptyOutputIsZero() throws {
        let stat = try GitNumstatParser.parse(Data())

        XCTAssertEqual(stat, .zero)
        XCTAssertTrue(stat.isEmpty)
    }

    func testRejectsMalformedRecord() {
        XCTAssertThrowsError(
            try GitNumstatParser.parse(Data("not numstat output\n".utf8))
        ) { error in
            XCTAssertEqual(
                error as? GitNumstatParseError,
                .malformedRecord("not numstat output")
            )
        }
    }
}
