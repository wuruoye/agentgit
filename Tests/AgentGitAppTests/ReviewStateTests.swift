import AgentGitCore
import XCTest
@testable import AgentGitApp

final class ReviewStateTests: XCTestCase {
    func testSnapshotIDIsStableForSameDiff() {
        let first = makeDiff(content: "let value = 1")
        let second = makeDiff(content: "let value = 1")

        XCTAssertEqual(
            DiffReviewSnapshotID(diff: first),
            DiffReviewSnapshotID(diff: second)
        )
    }

    func testSnapshotIDChangesWithContentOrScope() {
        let original = makeDiff(content: "let value = 1")
        let changed = makeDiff(content: "let value = 2")
        let staged = makeDiff(content: "let value = 1", scope: .staged)

        XCTAssertNotEqual(
            DiffReviewSnapshotID(diff: original),
            DiffReviewSnapshotID(diff: changed)
        )
        XCTAssertNotEqual(
            DiffReviewSnapshotID(diff: original),
            DiffReviewSnapshotID(diff: staged)
        )
    }

    func testPresentationOnlyInlineRangesDoNotChangeSnapshotID() {
        let plain = makeDiff(content: "let value = 1")
        let highlighted = makeDiff(
            content: "let value = 1",
            inlineRanges: [GitDiffInlineRange(location: 4, length: 5)]
        )

        XCTAssertEqual(
            DiffReviewSnapshotID(diff: plain),
            DiffReviewSnapshotID(diff: highlighted)
        )
    }

    func testContextLinesAndHunkGroupingDoNotChangeSnapshotID() {
        let compact = makeDiff(
            hunks: [
                makeHunk(id: 0, header: "@@ -2 +2 @@", context: [], content: "let value = 1")
            ]
        )
        let expanded = makeDiff(
            hunks: [
                makeHunk(
                    id: 4,
                    header: "@@ -1,3 +1,3 @@",
                    context: ["struct Sample {", "}"],
                    content: "let value = 1"
                )
            ]
        )

        XCTAssertEqual(
            DiffReviewSnapshotID(diff: compact),
            DiffReviewSnapshotID(diff: expanded)
        )
    }

    func testExternalSeedInvalidatesNonTextualSnapshot() {
        let binary = GitFileDiff(
            change: makeChange(),
            scope: .working,
            hunks: [],
            state: .binary
        )

        XCTAssertNotEqual(
            DiffReviewSnapshotID(diff: binary, externalSeed: "first"),
            DiffReviewSnapshotID(diff: binary, externalSeed: "second")
        )
    }

    func testMetadataSummaryChangesReviewedSnapshotID() {
        let modeChange = GitFileDiff(
            change: makeChange(),
            scope: .working,
            hunks: [],
            state: .metadata("old mode 100644 · new mode 100755")
        )
        let renameChange = GitFileDiff(
            change: makeChange(),
            scope: .working,
            hunks: [],
            state: .metadata("rename from old.swift · rename to new.swift")
        )

        XCTAssertNotEqual(
            DiffReviewSnapshotID(diff: modeChange),
            DiffReviewSnapshotID(diff: renameChange)
        )
    }

    func testInvalidatingReviewedSnapshotsRemovesChangedAndMissingFiles() {
        let matching = DiffReviewSnapshotID(rawValue: 10)
        var state = ReviewState(
            reviewedSnapshotByFileID: [
                "matching": matching,
                "changed": DiffReviewSnapshotID(rawValue: 20),
                "missing": DiffReviewSnapshotID(rawValue: 30)
            ]
        )

        XCTAssertTrue(
            invalidateReviewedSnapshots(
                in: &state,
                currentByFileID: [
                    "matching": matching,
                    "changed": DiffReviewSnapshotID(rawValue: 21)
                ]
            )
        )
        XCTAssertEqual(state.reviewedSnapshotByFileID, ["matching": matching])
        XCTAssertFalse(
            invalidateReviewedSnapshots(
                in: &state,
                currentByFileID: ["matching": matching]
            )
        )
    }

    func testNewReviewFilesStartCollapsedAndExistingChoicesArePreserved() {
        var state = ReviewState()

        XCTAssertTrue(
            synchronizeReviewFileExpansion(
                in: &state,
                fileIDs: ["first", "second"]
            )
        )
        XCTAssertEqual(state.collapsedFileIDs, ["first", "second"])

        state.collapsedFileIDs.remove("first")
        XCTAssertFalse(
            synchronizeReviewFileExpansion(
                in: &state,
                fileIDs: ["first", "second"]
            )
        )
        XCTAssertEqual(state.collapsedFileIDs, ["second"])

        XCTAssertTrue(
            synchronizeReviewFileExpansion(
                in: &state,
                fileIDs: ["first", "second", "third"]
            )
        )
        XCTAssertEqual(state.collapsedFileIDs, ["second", "third"])

        XCTAssertTrue(
            synchronizeReviewFileExpansion(
                in: &state,
                fileIDs: ["first", "third"]
            )
        )
        XCTAssertEqual(state.collapsedFileIDs, ["third"])
        XCTAssertEqual(state.knownFileIDs, ["first", "third"])
    }

    func testUnseenReviewFilesRemainCollapsedUntilExplicitlyExpanded() {
        var state = ReviewState()

        XCTAssertFalse(isReviewFileExpanded("first", in: state))
        XCTAssertTrue(
            setReviewFileExpansion(
                in: &state,
                fileIDs: ["first"],
                isExpanded: true
            )
        )
        XCTAssertTrue(isReviewFileExpanded("first", in: state))
        XCTAssertFalse(
            synchronizeReviewFileExpansion(
                in: &state,
                fileIDs: ["first"]
            )
        )
        XCTAssertTrue(toggleReviewFileExpansion(in: &state, fileID: "first"))
        XCTAssertFalse(isReviewFileExpanded("first", in: state))

        XCTAssertTrue(
            setReviewFileExpansion(
                in: &state,
                fileIDs: ["first", "second"],
                isExpanded: true
            )
        )
        XCTAssertTrue(isReviewFileExpanded("first", in: state))
        XCTAssertTrue(isReviewFileExpanded("second", in: state))
    }

    func testNavigatorFolderExpansionDropsFoldersOutsideCurrentReview() {
        var state = ReviewState(
            expandedNavigatorFolderIDs: ["current", "removed"]
        )

        XCTAssertTrue(
            synchronizeNavigatorFolderExpansion(
                in: &state,
                validFolderIDs: ["current", "new"]
            )
        )
        XCTAssertEqual(state.expandedNavigatorFolderIDs, ["current"])
        XCTAssertFalse(
            synchronizeNavigatorFolderExpansion(
                in: &state,
                validFolderIDs: ["current", "new"]
            )
        )
    }

    func testNavigatorFoldersCanExpandAndCollapseAsOneSet() {
        var state = ReviewState(expandedNavigatorFolderIDs: ["preserved"])

        XCTAssertTrue(
            setNavigatorFolderExpansion(
                in: &state,
                folderIDs: ["first", "second"],
                isExpanded: true
            )
        )
        XCTAssertEqual(
            state.expandedNavigatorFolderIDs,
            ["first", "preserved", "second"]
        )
        XCTAssertFalse(
            setNavigatorFolderExpansion(
                in: &state,
                folderIDs: ["first", "second"],
                isExpanded: true
            )
        )
        XCTAssertTrue(
            setNavigatorFolderExpansion(
                in: &state,
                folderIDs: ["first", "second"],
                isExpanded: false
            )
        )
        XCTAssertEqual(state.expandedNavigatorFolderIDs, ["preserved"])
    }

    @MainActor
    func testReviewStateStoreRestoresPersistentReviewStateWithoutFilter() {
        let suiteName = "ReviewStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let key = ReviewStateKey(worktreeID: "worktree", context: .pending)
        let expectedSnapshot = DiffReviewSnapshotID(rawValue: 42)
        let state = ReviewState(
            collapsedFileIDs: ["working:file.swift"],
            knownFileIDs: ["working:file.swift"],
            expandedNavigatorFolderIDs: ["navigator-folder:working:Sources"],
            focusedFileID: "working:file.swift",
            filterText: "temporary filter",
            reviewedSnapshotByFileID: ["working:file.swift": expectedSnapshot],
            wholeFileIDs: ["working:file.swift"],
            revealedContextLineCountByGapID: ["working:file.swift:context:0->1": 20]
        )

        let original = ReviewStateStore(defaults: defaults)
        original.save(state, for: key)
        original.saveScrollOffset(321.5, for: key)
        let navigationState = ReviewNavigationState(
            context: .range(
                base: String(repeating: "a", count: 40),
                head: String(repeating: "b", count: 40)
            ),
            selectedCommitIDs: [
                String(repeating: "b", count: 40),
                String(repeating: "c", count: 40)
            ],
            pane: .files,
            historyFilter: "author:reviewer"
        )
        original.saveLastContext(
            navigationState.context,
            selectedCommitIDs: navigationState.selectedCommitIDs,
            pane: navigationState.pane,
            historyFilter: navigationState.historyFilter,
            for: key.worktreeID
        )
        original.flush()

        let restored = ReviewStateStore(defaults: defaults)
        let restoredState = restored.state(for: key)
        XCTAssertEqual(restoredState.collapsedFileIDs, state.collapsedFileIDs)
        XCTAssertEqual(restoredState.knownFileIDs, state.knownFileIDs)
        XCTAssertEqual(
            restoredState.expandedNavigatorFolderIDs,
            state.expandedNavigatorFolderIDs
        )
        XCTAssertEqual(restoredState.focusedFileID, state.focusedFileID)
        XCTAssertEqual(restoredState.filterText, "")
        XCTAssertEqual(
            restoredState.reviewedSnapshotByFileID,
            state.reviewedSnapshotByFileID
        )
        XCTAssertEqual(restoredState.wholeFileIDs, state.wholeFileIDs)
        XCTAssertEqual(
            restoredState.revealedContextLineCountByGapID,
            state.revealedContextLineCountByGapID
        )
        XCTAssertEqual(restored.scrollOffset(for: key), 321.5, accuracy: 0.01)
        XCTAssertEqual(
            restored.lastContext(for: key.worktreeID),
            navigationState
        )
    }

    @MainActor
    func testReviewStateStoreReadsPayloadWithoutLastContextField() throws {
        let suiteName = "ReviewStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyPayload = try JSONSerialization.data(
            withJSONObject: ["version": 1, "entries": []]
        )
        defaults.set(legacyPayload, forKey: "agentgit.review-state.v1")

        let restored = ReviewStateStore(defaults: defaults)

        XCTAssertEqual(restored.lastContext(for: "worktree"), .pending)
    }

    func testReviewNavigationStateDefaultsMissingPaneToCommits() throws {
        let legacy = LegacyReviewNavigationState(
            context: .commit("commit"),
            selectedCommitIDs: ["commit"]
        )
        let data = try JSONEncoder().encode(legacy)

        let restored = try JSONDecoder().decode(
            ReviewNavigationState.self,
            from: data
        )

        XCTAssertEqual(restored.context, legacy.context)
        XCTAssertEqual(restored.selectedCommitIDs, legacy.selectedCommitIDs)
        XCTAssertEqual(restored.pane, .commits)
        XCTAssertEqual(restored.historyFilter, "")
    }

    func testReviewNavigationStateRoundTripsHistoryFilter() throws {
        let expected = ReviewNavigationState(
            context: .commit("commit"),
            selectedCommitIDs: ["commit"],
            pane: .files,
            historyFilter: "author:AgentGit"
        )

        let restored = try JSONDecoder().decode(
            ReviewNavigationState.self,
            from: JSONEncoder().encode(expected)
        )

        XCTAssertEqual(restored, expected)
    }

    func testReviewNavigationHistorySupportsBackForwardAndBranching() {
        let pending = ReviewNavigationState.pending
        let first = ReviewNavigationState(
            context: .commit("first"),
            selectedCommitIDs: ["first"],
            pane: .commits,
            historyFilter: "message:first"
        )
        let range = ReviewNavigationState(
            context: .range(base: "base", head: "head"),
            selectedCommitIDs: ["head", "oldest"],
            pane: .files
        )
        let replacement = ReviewNavigationState(
            context: .commit("replacement"),
            selectedCommitIDs: ["replacement"],
            pane: .files
        )
        var history = ReviewNavigationHistory(maximumEntryCount: 2)

        history.recordTransition(from: pending, to: first)
        history.recordTransition(from: first, to: range)
        XCTAssertTrue(history.canNavigateBack)
        XCTAssertFalse(history.canNavigateForward)
        XCTAssertEqual(history.navigateBack(from: range), first)
        XCTAssertTrue(history.canNavigateForward)
        XCTAssertEqual(history.navigateBack(from: first), pending)
        XCTAssertFalse(history.canNavigateBack)
        XCTAssertEqual(history.navigateForward(from: pending), first)

        history.recordTransition(from: first, to: replacement)
        XCTAssertFalse(history.canNavigateForward)
        XCTAssertEqual(history.navigateBack(from: replacement), first)
        history.removeAll()
        XCTAssertFalse(history.canNavigateBack)
        XCTAssertFalse(history.canNavigateForward)
    }

    private func makeDiff(
        content: String,
        scope: GitDiffScope = .working,
        inlineRanges: [GitDiffInlineRange] = []
    ) -> GitFileDiff {
        makeDiff(
            scope: scope,
            hunks: [
                makeHunk(
                    id: 0,
                    header: "@@ -1 +1 @@",
                    context: [],
                    content: content,
                    inlineRanges: inlineRanges
                )
            ]
        )
    }

    private func makeDiff(
        scope: GitDiffScope = .working,
        hunks: [GitDiffHunk]
    ) -> GitFileDiff {
        GitFileDiff(
            change: makeChange(),
            scope: scope,
            hunks: hunks,
            state: .textual
        )
    }

    private func makeHunk(
        id: Int,
        header: String,
        context: [String],
        content: String,
        inlineRanges: [GitDiffInlineRange] = []
    ) -> GitDiffHunk {
        let leadingContext = context.first.map {
            GitDiffLine(
                id: id * 10,
                kind: .context,
                oldLineNumber: 1,
                newLineNumber: 1,
                content: $0
            )
        }
        let trailingContext = context.dropFirst().first.map {
            GitDiffLine(
                id: id * 10 + 2,
                kind: .context,
                oldLineNumber: 3,
                newLineNumber: 3,
                content: $0
            )
        }
        return GitDiffHunk(
            id: id,
            header: header,
            oldStart: 1,
            oldCount: max(1, context.count + 1),
            newStart: 1,
            newCount: max(1, context.count + 1),
            lines: [
                leadingContext,
                GitDiffLine(
                    id: id * 10 + 1,
                    kind: .addition,
                    oldLineNumber: nil,
                    newLineNumber: 2,
                    content: content,
                    inlineRanges: inlineRanges
                ),
                trailingContext
            ].compactMap { $0 }
        )
    }

    private func makeChange() -> GitFileChange {
        GitFileChange(
            path: "Sources/Sample.swift",
            originalPath: nil,
            indexStatus: ".",
            worktreeStatus: "M",
            kind: .ordinary
        )
    }
}

private struct LegacyReviewNavigationState: Encodable {
    let context: ReviewContext
    let selectedCommitIDs: Set<GitCommit.ID>
}
