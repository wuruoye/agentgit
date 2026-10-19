@testable import AgentGitApp
import AgentGitCore
import AgentGitIntegrationShared
import Foundation
import Testing

private func line(
    _ id: Int,
    _ kind: GitDiffLineKind,
    old: Int?,
    new: Int?,
    _ content: String
) -> GitDiffLine {
    GitDiffLine(id: id, kind: kind, oldLineNumber: old, newLineNumber: new, content: content)
}

private func context(
    scope: ReviewSelectionScope = .uncommitted(.unstaged, headOID: "a8d99b5"),
    filePath: String = "Sources/App/Main.swift",
    originalPath: String? = nil,
    lines: [GitDiffLine]
) -> ReviewSelectionContext {
    ReviewSelectionContext(
        repositoryPath: "/repo",
        worktreePath: "/repo/.claude/worktrees/feature",
        branchName: "claude/feature",
        scope: scope,
        filePath: filePath,
        originalPath: originalPath,
        lines: lines
    )
}

@Test func selectionLineRangesCoverBothSides() {
    let selection = context(lines: [
        line(1, .context, old: 10, new: 12, "let a = 1"),
        line(2, .deletion, old: 11, new: nil, "let b = 2"),
        line(3, .deletion, old: 12, new: nil, "let c = 3"),
        line(4, .addition, old: nil, new: 13, "let b = 20"),
        line(5, .context, old: 13, new: 14, "return a")
    ])
    #expect(selection.oldLineRange == 10...13)
    #expect(selection.newLineRange == 12...14)
    #expect(selection.lineRangeDescription == "old 10-13, new 12-14")
}

@Test func selectionLineRangesOmitMissingSide() {
    let additions = context(lines: [
        line(1, .addition, old: nil, new: 5, "a"),
        line(2, .addition, old: nil, new: 6, "b")
    ])
    #expect(additions.oldLineRange == nil)
    #expect(additions.lineRangeDescription == "new 5-6")

    let singleDeletion = context(lines: [line(1, .deletion, old: 42, new: nil, "gone")])
    #expect(singleDeletion.lineRangeDescription == "old 42")

    let metadataOnly = context(lines: [line(1, .metadata, old: nil, new: nil, "\\ No newline at end of file")])
    #expect(metadataOnly.lineRangeDescription == "none")
}

@Test func selectionQuotedCodeKeepsDiffMarkers() {
    let selection = context(lines: [
        line(1, .context, old: 1, new: 1, "func run() {"),
        line(2, .deletion, old: 2, new: nil, "    old()"),
        line(3, .addition, old: nil, new: 2, "    new()"),
        line(4, .context, old: 3, new: 3, ""),
        line(5, .metadata, old: nil, new: nil, "\\ No newline at end of file")
    ])
    #expect(selection.quotedCode == [
        " func run() {",
        "-    old()",
        "+    new()",
        " ",
        "\\ No newline at end of file"
    ].joined(separator: "\n"))
}

@Test func reviewScopeDescriptions() {
    #expect(
        ReviewSelectionScope.uncommitted(.unstaged, headOID: "abc123").description
            == "uncommitted changes (unstaged) on top of HEAD abc123"
    )
    #expect(
        ReviewSelectionScope.uncommitted(.staged, headOID: nil).description
            == "uncommitted changes (staged)"
    )
    #expect(
        ReviewSelectionScope.uncommitted(.untracked, headOID: "abc123").description
            == "uncommitted changes (untracked file) on top of HEAD abc123"
    )
    #expect(
        ReviewSelectionScope.commit(oid: "0123456789abcdef", subject: " Fix crash \n").description
            == "commit 0123456789abcdef \"Fix crash\""
    )
    #expect(ReviewSelectionScope.commit(oid: "0123", subject: nil).description == "commit 0123")
    #expect(
        ReviewSelectionScope.range(base: "base1", head: "head2").description
            == "commit range base1..head2 (changes after base1 up to and including head2)"
    )
}

@Test func selectionTextIncludesLocationScopeAndCode() {
    let selection = context(
        scope: .commit(oid: "feedface", subject: "Add feature"),
        filePath: "Sources/New.swift",
        originalPath: "Sources/Old.swift",
        lines: [
            line(1, .deletion, old: 7, new: nil, "a"),
            line(2, .addition, old: nil, new: 7, "b")
        ]
    )
    #expect(selection.text == """
    Selected code from an AgentGit review:

    - Repository: /repo
    - Worktree: /repo/.claude/worktrees/feature (branch claude/feature)
    - Review scope: commit feedface "Add feature"
    - File: Sources/New.swift (renamed from Sources/Old.swift)
    - Lines: old 7, new 7

    ```diff
    -a
    +b
    ```
    """)
}

@Test func selectionTextLengthensFenceAroundBackticks() {
    let selection = context(lines: [
        line(1, .addition, old: nil, new: 1, "```swift"),
        line(2, .addition, old: nil, new: 2, "````")
    ])
    #expect(selection.text.hasSuffix("""
    `````diff
    +```swift
    +````
    `````
    """))
}

@Test func sideBySideRowsFollowUnifiedOrder() {
    let context1 = line(1, .context, old: 1, new: 1, "start")
    let deleted1 = line(2, .deletion, old: 2, new: nil, "old 1")
    let deleted2 = line(3, .deletion, old: 3, new: nil, "old 2")
    let added1 = line(4, .addition, old: nil, new: 2, "new 1")
    let context2 = line(5, .context, old: 4, new: 3, "end")
    let distant = line(9, .addition, old: nil, new: 20, "later")
    let ordered = unifiedDiffSelectionOrder([
        (row: 14, old: nil, new: distant),
        (row: 10, old: context1, new: context1),
        (row: 11, old: deleted1, new: added1),
        (row: 12, old: deleted2, new: nil),
        (row: 13, old: context2, new: context2)
    ])
    #expect(ordered.map(\.id) == [1, 2, 3, 4, 5, 9])
}

@Test func sideBySideGapSplitsChangeBlocks() {
    let firstDeletion = line(1, .deletion, old: 1, new: nil, "a")
    let firstAddition = line(2, .addition, old: nil, new: 1, "b")
    let secondDeletion = line(7, .deletion, old: 9, new: nil, "c")
    let secondAddition = line(8, .addition, old: nil, new: 9, "d")
    let ordered = unifiedDiffSelectionOrder([
        (row: 3, old: firstDeletion, new: firstAddition),
        (row: 8, old: secondDeletion, new: secondAddition)
    ])
    #expect(ordered.map(\.id) == [1, 2, 7, 8])
}

@Test func codexHandoffPrefillsComposer() throws {
    let text = "Lines: old 1, new 1\n```diff\n-a + b\n+c&d=e #f\n```"
    let handoff = AgentSessionContextHandoff(
        provider: .codex,
        sessionURL: try #require(URL(string: "codex://threads/0199aa00-0000-7000-8000-000000000001")),
        context: text
    )
    #expect(!handoff.copiesContextToPasteboard)
    let components = try #require(URLComponents(url: handoff.url, resolvingAgainstBaseURL: false))
    #expect(components.scheme == "codex")
    #expect(components.host == "threads")
    #expect(components.path == "/0199aa00-0000-7000-8000-000000000001")
    // `+` 必须编码，否则网页端的 URLSearchParams 会把它读成空格。
    let query = try #require(components.percentEncodedQuery)
    #expect(query.hasPrefix("prompt="))
    #expect(!query.dropFirst("prompt=".count).contains("+"))
    #expect(query.contains("%2B"))
    #expect(components.queryItems == [URLQueryItem(name: "prompt", value: text)])
}

@Test func claudeHandoffCopiesContext() throws {
    let url = try #require(URL(string: "claude://claude.ai/claude-code-desktop/local_abc"))
    let handoff = AgentSessionContextHandoff(provider: .claude, sessionURL: url, context: "hello")
    #expect(handoff.copiesContextToPasteboard)
    #expect(handoff.url == url)
}

@Test func oversizedCodexContextFallsBackToPasteboard() throws {
    let url = try #require(URL(string: "codex://threads/0199aa00-0000-7000-8000-000000000001"))
    let text = String(repeating: "x", count: AgentSessionContextHandoff.maximumPrefillLength + 1)
    let handoff = AgentSessionContextHandoff(provider: .codex, sessionURL: url, context: text)
    #expect(handoff.copiesContextToPasteboard)
    #expect(handoff.url == url)
}
