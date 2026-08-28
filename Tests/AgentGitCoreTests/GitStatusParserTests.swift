import Foundation
import XCTest
@testable import AgentGitCore

final class GitStatusParserTests: XCTestCase {
    func testParsesAheadBehindCountCommand() throws {
        let branch = try GitAheadBehindParser.parse(
            Data("3\t2\n".utf8),
            upstreamRef: "origin/main"
        )

        XCTAssertEqual(branch.upstreamRef, "origin/main")
        XCTAssertEqual(branch.aheadCount, 3)
        XCTAssertEqual(branch.behindCount, 2)
    }

    func testParsesExpandedUntrackedPaths() throws {
        let changes = try GitUntrackedFilesParser.parse(
            Data("Generated/one.swift\0Generated/two.swift\0".utf8)
        )

        XCTAssertEqual(changes.map(\.path), ["Generated/one.swift", "Generated/two.swift"])
        XCTAssertTrue(changes.allSatisfy(\.isUntracked))
    }

    func testParsesSubmoduleCommitAndWorkingTreeFlags() throws {
        let data = Data(
            "1 .M SCMU 160000 160000 160000 aaaa bbbb Modules/Shared\0".utf8
        )

        let change = try XCTUnwrap(
            GitStatusParser.parsePorcelainV2(data).changes.first
        )

        XCTAssertTrue(change.submoduleStatus?.commitChanged == true)
        XCTAssertTrue(change.submoduleStatus?.hasTrackedChanges == true)
        XCTAssertTrue(change.submoduleStatus?.hasUntrackedChanges == true)
    }

    /// Pending 分组依赖这三个谓词互斥：untracked 不能同时算进 Working。
    func testUntrackedIsNotReportedAsUnstaged() throws {
        let records = [
            "1 .M N... 100644 100644 100644 aaaa bbbb changed.swift",
            "1 M. N... 100644 100644 100644 cccc dddd staged.swift",
            "? brand-new.swift"
        ]
        let snapshot = try GitStatusParser.parsePorcelainV2(
            Data(records.joined(separator: "\0").utf8)
        )

        let changed = try XCTUnwrap(snapshot.changes.first { $0.path == "changed.swift" })
        XCTAssertTrue(changed.isUnstaged)
        XCTAssertFalse(changed.isUntracked)
        XCTAssertFalse(changed.isStaged)

        let staged = try XCTUnwrap(snapshot.changes.first { $0.path == "staged.swift" })
        XCTAssertTrue(staged.isStaged)
        XCTAssertFalse(staged.isUnstaged)

        let untracked = try XCTUnwrap(snapshot.changes.first { $0.path == "brand-new.swift" })
        XCTAssertTrue(untracked.isUntracked)
        XCTAssertFalse(untracked.isUnstaged)
        XCTAssertFalse(untracked.isStaged)
    }

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

    func testParsesUpstreamAheadBehind() throws {
        let records = [
            "# branch.oid 99b88fa522fffec22a8420dec1e74f65c4d9d152",
            "# branch.head feature",
            "# branch.upstream origin/feature",
            "# branch.ab +3 -2",
            "1 M. N... 100644 100644 100644 aaaa bbbb README.md"
        ]
        let data = Data(records.joined(separator: "\0").utf8)

        let snapshot = try GitStatusParser.parsePorcelainV2(data)

        XCTAssertEqual(snapshot.branch?.upstreamRef, "origin/feature")
        XCTAssertEqual(snapshot.branch?.aheadCount, 3)
        XCTAssertEqual(snapshot.branch?.behindCount, 2)
        XCTAssertEqual(snapshot.headOID, "99b88fa522fffec22a8420dec1e74f65c4d9d152")
        XCTAssertEqual(snapshot.branchHead, "feature")
        XCTAssertFalse(snapshot.branch?.isSynced == true)
        XCTAssertEqual(snapshot.changedFileCount, 1)
    }

    func testAcceptsDeferredAheadBehindCounts() throws {
        let records = [
            "# branch.oid 99b88fa522fffec22a8420dec1e74f65c4d9d152",
            "# branch.head feature",
            "# branch.upstream origin/feature",
            "# branch.ab +? -?"
        ]
        let snapshot = try GitStatusParser.parsePorcelainV2(
            Data(records.joined(separator: "\0").utf8)
        )

        XCTAssertEqual(snapshot.branch?.upstreamRef, "origin/feature")
        XCTAssertEqual(snapshot.branch?.aheadCount, 0)
        XCTAssertEqual(snapshot.branch?.behindCount, 0)
    }

    func testBranchIsNilWithoutUpstream() throws {
        let records = [
            "# branch.oid 7b83776f8fab0f908a220bb0edf3cf4f1051f859",
            "# branch.head main",
            "? probe.txt"
        ]
        let data = Data(records.joined(separator: "\0").utf8)

        let snapshot = try GitStatusParser.parsePorcelainV2(data)

        XCTAssertNil(snapshot.branch)
        XCTAssertEqual(snapshot.headOID, "7b83776f8fab0f908a220bb0edf3cf4f1051f859")
        XCTAssertEqual(snapshot.branchHead, "main")
        XCTAssertEqual(snapshot.untrackedFileCount, 1)
    }

    func testParsesUnbornAndDetachedBranchHeaders() throws {
        let unborn = try GitStatusParser.parsePorcelainV2(
            Data("# branch.oid (initial)\0# branch.head main".utf8)
        )
        XCTAssertNil(unborn.headOID)
        XCTAssertEqual(unborn.branchHead, "main")

        let detachedOID = "99b88fa522fffec22a8420dec1e74f65c4d9d152"
        let detached = try GitStatusParser.parsePorcelainV2(
            Data("# branch.oid \(detachedOID)\0# branch.head (detached)".utf8)
        )
        XCTAssertEqual(detached.headOID, detachedOID)
        XCTAssertEqual(detached.branchHead, "(detached)")
    }
}
