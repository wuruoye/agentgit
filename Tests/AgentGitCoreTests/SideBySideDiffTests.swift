import XCTest
@testable import AgentGitCore

final class SideBySideDiffTests: XCTestCase {
    func testPairsDeletionAndAdditionRunsAndKeepsUnevenTail() {
        let lines = [
            line(0, .context, "before", old: 1, new: 1),
            line(1, .deletion, "old one", old: 2),
            line(2, .deletion, "old two", old: 3),
            line(3, .addition, "new one", new: 2),
            line(4, .context, "after", old: 4, new: 3)
        ]

        let pairs = SideBySideDiffBuilder.pairs(lines)

        XCTAssertEqual(pairs.count, 4)
        XCTAssertEqual(pairs[0].old?.content, "before")
        XCTAssertEqual(pairs[0].new?.content, "before")
        XCTAssertEqual(pairs[1].old?.content, "old one")
        XCTAssertEqual(pairs[1].new?.content, "new one")
        XCTAssertEqual(pairs[2].old?.content, "old two")
        XCTAssertNil(pairs[2].new)
        XCTAssertEqual(pairs[3].old?.content, "after")
        XCTAssertEqual(pairs[3].new?.content, "after")
    }

    func testKeepsStandaloneAdditionOnNewSide() {
        let addition = line(0, .addition, "new", new: 1)

        XCTAssertEqual(
            SideBySideDiffBuilder.pairs([addition]),
            [GitDiffLinePair(old: nil, new: addition)]
        )
    }

    private func line(
        _ id: Int,
        _ kind: GitDiffLineKind,
        _ content: String,
        old: Int? = nil,
        new: Int? = nil
    ) -> GitDiffLine {
        GitDiffLine(
            id: id,
            kind: kind,
            oldLineNumber: old,
            newLineNumber: new,
            content: content
        )
    }
}
