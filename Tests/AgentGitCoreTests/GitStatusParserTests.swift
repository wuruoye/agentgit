import Foundation
import XCTest
@testable import AgentGitCore

final class GitStatusParserTests: XCTestCase {
    func testParsesOrdinaryRenameAndUntrackedRecords() throws {
        let payload = [
            "1 .M N... 100644 100644 100644 aaaaaaa bbbbbbb Sources/File One.swift",
            "2 R. N... 100644 100644 100644 aaaaaaa bbbbbbb R100 Sources/New.swift",
            "Sources/Old.swift",
            "? Notes/new note.md",
            ""
        ].joined(separator: "\0")

        let status = try GitStatusParser.parsePorcelainV2(Data(payload.utf8))

        XCTAssertEqual(status.changedFileCount, 3)
        XCTAssertEqual(status.stagedFileCount, 1)
        XCTAssertEqual(status.unstagedFileCount, 1)
        XCTAssertEqual(status.untrackedFileCount, 1)
        XCTAssertEqual(status.changes[0].path, "Sources/File One.swift")
        XCTAssertEqual(status.changes[1].path, "Sources/New.swift")
        XCTAssertEqual(status.changes[1].originalPath, "Sources/Old.swift")
        XCTAssertEqual(status.changes[2].path, "Notes/new note.md")
    }

    func testRejectsRenameWithoutOriginalPath() {
        let payload = Data(
            "2 R. N... 100644 100644 100644 aaaaaaa bbbbbbb R100 New.swift\0".utf8
        )

        XCTAssertThrowsError(try GitStatusParser.parsePorcelainV2(payload)) { error in
            guard case .missingOriginalPath = error as? GitStatusParseError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testTreatsUnmergedEntryAsWorkingConflictInsteadOfStagedChange() throws {
        let payload = Data(
            "u UU N... 100644 100644 100644 100644 aaaaaaa bbbbbbb ccccccc conflicted.txt\0".utf8
        )

        let status = try GitStatusParser.parsePorcelainV2(payload)

        XCTAssertEqual(status.changes.first?.kind, .unmerged)
        XCTAssertEqual(status.stagedFileCount, 0)
        XCTAssertEqual(status.unstagedFileCount, 1)
    }
}
