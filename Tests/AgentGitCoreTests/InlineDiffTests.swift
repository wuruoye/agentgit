import Foundation
import XCTest
@testable import AgentGitCore

final class InlineDiffTests: XCTestCase {
    private func text(_ source: String, _ range: GitDiffInlineRange) -> String {
        let ns = source as NSString
        return ns.substring(with: NSRange(location: range.location, length: range.length))
    }

    func testHighlightsOnlyTheChangedToken() {
        let old = "let value = compute(first, second)"
        let new = "let value = compute(third, second)"

        let (oldRanges, newRanges) = InlineDiffCalculator.ranges(old: old, new: new)

        XCTAssertEqual(oldRanges.map { text(old, $0) }, ["first"])
        XCTAssertEqual(newRanges.map { text(new, $0) }, ["third"])
    }

    /// 前后缀裁剪只能给出一个粗区间，token 级 LCS 才能把中间没变的部分留白。
    func testSplitsMultipleEditsIntoSeparateRanges() {
        let old = "foo(alpha, keep, beta)"
        let new = "foo(gamma, keep, delta)"

        let (oldRanges, newRanges) = InlineDiffCalculator.ranges(old: old, new: new)

        XCTAssertEqual(oldRanges.map { text(old, $0) }, ["alpha", "beta"])
        XCTAssertEqual(newRanges.map { text(new, $0) }, ["gamma", "delta"])
    }

    func testReportsNoRangesWhenWholeLineDiffers() {
        let (oldRanges, newRanges) = InlineDiffCalculator.ranges(
            old: "completely different",
            new: "nothing alike here"
        )

        XCTAssertTrue(oldRanges.isEmpty)
        XCTAssertTrue(newRanges.isEmpty)
    }

    func testUsesUTF16OffsetsForNonASCIIContent() {
        let old = "名称：旧值 // 尾注"
        let new = "名称：新值 // 尾注"

        let (oldRanges, newRanges) = InlineDiffCalculator.ranges(old: old, new: new)

        XCTAssertEqual(oldRanges.map { text(old, $0) }, ["旧"])
        XCTAssertEqual(newRanges.map { text(new, $0) }, ["新"])
    }

    func testPairsDeletionAndAdditionRunsByIndex() {
        func line(_ id: Int, _ kind: GitDiffLineKind, _ content: String) -> GitDiffLine {
            GitDiffLine(
                id: id,
                kind: kind,
                oldLineNumber: nil,
                newLineNumber: nil,
                content: content
            )
        }

        let annotated = InlineDiffCalculator.annotate([
            line(0, .context, "unchanged"),
            line(1, .deletion, "let a = 1"),
            line(2, .deletion, "let b = 2"),
            line(3, .addition, "let a = 9"),
            line(4, .addition, "let b = 8")
        ])

        XCTAssertTrue(annotated[0].inlineRanges.isEmpty)
        XCTAssertEqual(annotated[1].inlineRanges.map { text("let a = 1", $0) }, ["1"])
        XCTAssertEqual(annotated[3].inlineRanges.map { text("let a = 9", $0) }, ["9"])
        XCTAssertEqual(annotated[2].inlineRanges.map { text("let b = 2", $0) }, ["2"])
        XCTAssertEqual(annotated[4].inlineRanges.map { text("let b = 8", $0) }, ["8"])
    }
}
