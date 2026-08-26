import XCTest
@testable import AgentGitCore

final class DiffSyntaxHighlighterTests: XCTestCase {
    func testHighlightsSwiftTokensWithoutTreatingCommentTextAsCode() {
        let line = #"let value = "if 42" // return 7"#
        let spans = DiffSyntaxHighlighter.spans(in: line, language: .swift)

        XCTAssertEqual(tokens(in: line, spans: spans, kind: .keyword), ["let"])
        XCTAssertEqual(tokens(in: line, spans: spans, kind: .string), [#""if 42""#])
        XCTAssertEqual(tokens(in: line, spans: spans, kind: .comment), ["// return 7"])
        XCTAssertTrue(tokens(in: line, spans: spans, kind: .number).isEmpty)
    }

    func testPythonCommentMarkerInsideStringDoesNotStartComment() {
        let line = "value = \"#still-string\"  # actual comment"
        let spans = DiffSyntaxHighlighter.spans(in: line, language: .python)

        XCTAssertEqual(tokens(in: line, spans: spans, kind: .string), ["\"#still-string\""])
        XCTAssertEqual(tokens(in: line, spans: spans, kind: .comment), ["# actual comment"])
    }

    func testUsesUTF16OffsetsForUnicodeBeforeComment() throws {
        let line = "名称 = 1 // 注释"
        let spans = DiffSyntaxHighlighter.spans(in: line, language: .swift)
        let comment = try XCTUnwrap(spans.first { $0.kind == .comment })

        XCTAssertEqual((line as NSString).substring(with: comment.range), "// 注释")
    }

    func testHighlightsMarkdownHeadingAsOneSpan() {
        let line = "  ## Review changes"
        let spans = DiffSyntaxHighlighter.spans(in: line, language: .markdown)

        XCTAssertEqual(spans, [GitSyntaxSpan(location: 2, length: 17, kind: .heading)])
    }

    func testDetectsLanguageFromPath() {
        XCTAssertEqual(GitSyntaxLanguage(path: "Sources/App.swift"), .swift)
        XCTAssertEqual(GitSyntaxLanguage(path: "scripts/build.sh"), .shell)
        XCTAssertEqual(GitSyntaxLanguage(path: "README.md"), .markdown)
        XCTAssertEqual(GitSyntaxLanguage(path: "asset.bin"), .plain)
    }

    private func tokens(
        in line: String,
        spans: [GitSyntaxSpan],
        kind: GitSyntaxTokenKind
    ) -> [String] {
        spans.filter { $0.kind == kind }.map {
            (line as NSString).substring(with: $0.range)
        }
    }
}

private extension GitSyntaxSpan {
    var range: NSRange {
        NSRange(location: location, length: length)
    }
}
