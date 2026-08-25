import Foundation
import XCTest
@testable import AgentGitCore

final class WorktreeListParserTests: XCTestCase {
    func testParsesBranchAndDetachedWorktrees() throws {
        let payload = [
            "worktree /tmp/repository",
            "HEAD 1111111111111111111111111111111111111111",
            "branch refs/heads/main",
            "",
            "worktree /tmp/repository-feature",
            "HEAD 2222222222222222222222222222222222222222",
            "detached",
            "locked in use",
            "",
            ""
        ].joined(separator: "\0")

        let worktrees = try WorktreeListParser.parse(Data(payload.utf8))

        XCTAssertEqual(worktrees.count, 2)
        XCTAssertEqual(worktrees[0].rootURL.path, "/tmp/repository")
        XCTAssertEqual(worktrees[0].branchName, "main")
        XCTAssertFalse(worktrees[0].isDetached)
        XCTAssertEqual(worktrees[1].rootURL.path, "/tmp/repository-feature")
        XCTAssertTrue(worktrees[1].isDetached)
        XCTAssertEqual(worktrees[1].lockedReason, "in use")
    }

    func testRejectsRecordWithoutWorktreePath() {
        let payload = Data("HEAD abc\0\0".utf8)

        XCTAssertThrowsError(try WorktreeListParser.parse(payload)) { error in
            XCTAssertEqual(error as? WorktreeListParseError, .missingWorktreePath)
        }
    }
}
