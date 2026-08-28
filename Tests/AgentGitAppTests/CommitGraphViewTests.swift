import AgentGitCore
import Foundation
import XCTest
@testable import AgentGitApp

final class CommitGraphViewTests: XCTestCase {
    func testLinearHistoryUsesOneContinuousLane() throws {
        let commits = [
            commit("c3", parents: ["c2"]),
            commit("c2", parents: ["c1"]),
            commit("c1", parents: [])
        ]

        let layout = CommitGraphLayout(commits: commits)

        XCTAssertEqual(layout.laneCount, 1)
        XCTAssertEqual(try row("c3", in: layout).nodeLane, 0)
        XCTAssertEqual(try row("c2", in: layout).nodeLane, 0)
        XCTAssertEqual(try row("c1", in: layout).nodeLane, 0)
        XCTAssertTrue(
            try row("c2", in: layout).segments.contains {
                $0.startPosition == .top
                    && $0.endPosition == .node
                    && $0.startLane == 0
                    && $0.endLane == 0
            }
        )
    }

    func testMergeHistoryDrawsTwoParentLanesAndConverges() throws {
        let commits = mergeHistory()
        let layout = CommitGraphLayout(commits: commits)

        XCTAssertEqual(layout.laneCount, 2)
        XCTAssertEqual(try row("merge", in: layout).nodeLane, 0)
        XCTAssertEqual(try row("main", in: layout).nodeLane, 0)
        XCTAssertEqual(try row("topic", in: layout).nodeLane, 1)
        XCTAssertEqual(try row("base", in: layout).nodeLane, 0)

        let merge = try row("merge", in: layout)
        let outgoing = merge.segments.filter {
            $0.startPosition == .node && $0.endPosition == .bottom
        }
        XCTAssertEqual(outgoing.count, 2)
        XCTAssertEqual(Set(outgoing.map(\.endLane)), [0, 1])

        let topic = try row("topic", in: layout)
        XCTAssertTrue(
            topic.segments.contains {
                $0.startPosition == .node
                    && $0.endPosition == .bottom
                    && $0.startLane == 1
                    && $0.endLane == 0
            }
        )
    }

    func testAppendingOlderPageKeepsExistingGraphRowsStable() throws {
        let commits = mergeHistory()
        let firstPage = CommitGraphLayout(commits: Array(commits.prefix(3)))
        let expanded = firstPage.appending(Array(commits.dropFirst(3)))
        let rebuilt = CommitGraphLayout(commits: commits)

        for commit in commits.prefix(3) {
            XCTAssertEqual(
                try row(commit.id, in: firstPage),
                try row(commit.id, in: expanded)
            )
        }
        XCTAssertEqual(expanded, rebuilt)
    }

    func testLargeMergeFoldsAdditionalLanesIntoFifthTrack() {
        let parents = (0..<8).map { "parent-\($0)" }
        let commits = [commit("merge", parents: parents)]
            + parents.map { commit($0, parents: []) }

        let layout = CommitGraphLayout(commits: commits)

        XCTAssertEqual(layout.laneCount, 8)
        XCTAssertEqual(layout.renderedLaneCount, 5)
        XCTAssertEqual(layout.displayWidth, 50)
    }

    func testAppendingTenThousandCommitHistoryWithinOneSecond() {
        let commits = (0..<10_000).map { index in
            commit(
                "commit-\(index)",
                parents: index + 1 < 10_000 ? ["commit-\(index + 1)"] : []
            )
        }
        var layout = CommitGraphLayout(commits: [])

        let elapsed = ContinuousClock().measure {
            for offset in stride(from: 0, to: commits.count, by: 100) {
                layout = layout.appending(
                    Array(commits[offset..<min(offset + 100, commits.count)])
                )
            }
        }

        XCTAssertEqual(layout.rowsByCommitID.count, commits.count)
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    private func mergeHistory() -> [GitCommit] {
        [
            commit("merge", parents: ["main", "topic"], refs: ["main"]),
            commit("main", parents: ["base"]),
            commit("topic", parents: ["base"]),
            commit("base", parents: [])
        ]
    }

    private func row(_ id: String, in layout: CommitGraphLayout) throws -> CommitGraphRow {
        try XCTUnwrap(layout.rowsByCommitID[id])
    }

    private func commit(
        _ oid: String,
        parents: [String],
        refs: [String] = []
    ) -> GitCommit {
        GitCommit(
            oid: oid,
            shortOID: oid,
            authorName: "Author",
            authoredAt: Date(timeIntervalSince1970: 0),
            parentOIDs: parents,
            refNames: refs,
            subject: oid
        )
    }
}
