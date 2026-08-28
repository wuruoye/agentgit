import Foundation
import XCTest
@testable import AgentGitCore

final class GitLogParserTests: XCTestCase {
    func testParsesCommitsWithRefsAndParents() throws {
        let records = [
            [
                "99b88fa522fffec22a8420dec1e74f65c4d9d152",
                "99b88fa",
                "Example Author",
                "2026-08-25T17:14:20+08:00",
                "03e4e003f1d3d9dd574d8adf0e11c5ca098fcb13",
                "HEAD -> refs/heads/feat/gate, refs/remotes/origin/feat/gate, tag: refs/tags/v1.2",
                "svc 只留凭据那道 gate"
            ].joined(separator: "\u{1f}"),
            [
                "03e4e003f1d3d9dd574d8adf0e11c5ca098fcb13",
                "03e4e00",
                "wechat_music_aicase",
                "2026-08-25T08:51:44Z",
                "d47331b02c333f6153be4cfba4196de6d898adc6 af6447bdee74006d16d429f86d164a883b17a583",
                "",
                "Merge branch 'sync' into 'exp'"
            ].joined(separator: "\u{1f}")
        ]
        let data = Data(records.joined(separator: "\0").utf8)

        let commits = try GitLogParser.parse(data)

        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].shortOID, "99b88fa")
        XCTAssertEqual(
            commits[0].refNames,
            [
                "HEAD -> refs/heads/feat/gate",
                "refs/remotes/origin/feat/gate",
                "tag: refs/tags/v1.2"
            ]
        )
        XCTAssertEqual(commits[0].references.map(\.kind), [.head, .tag, .remoteBranch])
        XCTAssertEqual(commits[0].references.map(\.label), ["feat/gate", "v1.2", "origin/feat/gate"])
        XCTAssertFalse(commits[0].isMerge)
        XCTAssertEqual(commits[1].parentOIDs.count, 2)
        XCTAssertTrue(commits[1].isMerge)
        XCTAssertTrue(commits[1].refNames.isEmpty)
        XCTAssertEqual(commits[1].subject, "Merge branch 'sync' into 'exp'")
    }

    func testSubjectKeepsSeparatorLookingText() throws {
        let record = [
            "a".repeated(40),
            "aaaaaaa",
            "author",
            "2026-08-25T08:51:44Z",
            "",
            "",
            "fix: keep a\u{1f}b intact"
        ].joined(separator: "\u{1f}")

        let commits = try GitLogParser.parse(Data(record.utf8))

        XCTAssertEqual(commits.first?.subject, "fix: keep a\u{1f}b intact")
        XCTAssertTrue(commits.first?.parentOIDs.isEmpty == true)
    }

    func testRejectsMalformedRecord() {
        XCTAssertThrowsError(try GitLogParser.parse(Data("oid\u{1f}short".utf8)))
    }

    func testParsesHistorySearchScope() throws {
        let message = try XCTUnwrap(GitHistorySearchQuery("  renderer fix  "))
        let author = try XCTUnwrap(GitHistorySearchQuery("AUTHOR: Bob Example"))

        XCTAssertEqual(message.field, .message)
        XCTAssertEqual(message.term, "renderer fix")
        XCTAssertEqual(author.field, .author)
        XCTAssertEqual(author.term, "Bob Example")
        XCTAssertNil(GitHistorySearchQuery("author:   "))
    }
}

final class GitNameStatusParserTests: XCTestCase {
    func testParsesModifyAddDeleteAndRename() throws {
        let records = [
            "M", "Sources/App/Main.swift",
            "A", "Docs/new.md",
            "D", "Docs/old.md",
            "R100", "Sources/Old.swift", "Sources/New.swift"
        ]
        let data = Data(records.joined(separator: "\0").utf8)

        let changes = try GitNameStatusParser.parse(data)

        XCTAssertEqual(changes.count, 4)
        XCTAssertEqual(changes[0].path, "Sources/App/Main.swift")
        XCTAssertEqual(changes[0].indexStatus, "M")
        XCTAssertEqual(changes[2].indexStatus, "D")
        XCTAssertEqual(changes[3].kind, .renamedOrCopied)
        XCTAssertEqual(changes[3].originalPath, "Sources/Old.swift")
        XCTAssertEqual(changes[3].path, "Sources/New.swift")
    }

    func testEmptyOutputForMergeWithoutDelta() throws {
        XCTAssertTrue(try GitNameStatusParser.parse(Data()).isEmpty)
    }

    func testRejectsRenameMissingTargetPath() {
        let data = Data(["R100", "Sources/Old.swift"].joined(separator: "\0").utf8)

        XCTAssertThrowsError(try GitNameStatusParser.parse(data))
    }
}

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
