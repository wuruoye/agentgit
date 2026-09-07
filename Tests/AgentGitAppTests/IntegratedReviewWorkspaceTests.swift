import AgentGitCore
import XCTest
@testable import AgentGitApp

final class IntegratedReviewWorkspaceTests: XCTestCase {
    func testReviewWaitsForTheExactCompletedDiffLoad() {
        let requested = IntegratedDiffLoadKey(
            worktreeID: "/repo",
            activityDate: Date(timeIntervalSince1970: 1),
            context: .pending,
            options: GitDiffOptions(),
            fileIDs: [.pending(scope: .working, changeID: "file")]
        )
        let stale = IntegratedDiffLoadKey(
            worktreeID: requested.worktreeID,
            activityDate: Date(timeIntervalSince1970: 0),
            context: requested.context,
            options: requested.options,
            fileIDs: requested.fileIDs
        )

        XCTAssertFalse(
            reviewDiffsAreReady(
                fileCount: 1,
                requested: requested,
                completed: nil
            )
        )
        XCTAssertFalse(
            reviewDiffsAreReady(
                fileCount: 1,
                requested: requested,
                completed: stale
            )
        )
        XCTAssertTrue(
            reviewDiffsAreReady(
                fileCount: 1,
                requested: requested,
                completed: requested
            )
        )
    }

    func testSingleOverviewSelectionProducesAVisibilityTarget() {
        XCTAssertEqual(
            overviewVisibilityTargetID([.pending]),
            AnyHashable(IntegratedOverviewSelection.pending)
        )
        XCTAssertEqual(
            overviewVisibilityTargetID([.commit("abc123")]),
            AnyHashable("abc123")
        )
        XCTAssertNil(
            overviewVisibilityTargetID([.commit("abc123"), .commit("def456")])
        )
    }

    func testHunkHistoryFilterDescribesSingleAndMultipleLines() {
        let single = HunkHistoryFilter(
            worktreeID: "/repo",
            revision: "head",
            fileID: "file",
            path: "Sources/App.swift",
            startLine: 42,
            endLine: 42
        )
        let multiple = HunkHistoryFilter(
            worktreeID: "/repo",
            revision: "head",
            fileID: "file",
            path: "Sources/App.swift",
            startLine: 42,
            endLine: 49
        )

        XCTAssertEqual(single.lineLabel, "line 42")
        XCTAssertEqual(multiple.lineLabel, "lines 42–49")
    }

    func testCommitListTimestampStaysInSublimeEnglishFormat() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 9,
                    day: 1,
                    hour: 20,
                    minute: 0
                )
            )
        )
        let sameDay = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 9,
                    day: 1,
                    hour: 18,
                    minute: 5
                )
            )
        )
        let previousDay = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 31,
                    hour: 18,
                    minute: 5
                )
            )
        )

        XCTAssertEqual(
            commitListTimestamp(sameDay, relativeTo: now, calendar: calendar),
            "18:05"
        )
        XCTAssertEqual(
            commitListTimestamp(previousDay, relativeTo: now, calendar: calendar),
            "Mon, 18:05"
        )
        XCTAssertEqual(
            commitSummaryTimestamp(previousDay),
            "2026, Aug 31, Mon, 18:05"
        )
    }

    func testLongCommitMessagesOfferFullReader() {
        XCTAssertFalse(commitMessageNeedsFullReader("Short body"))
        XCTAssertFalse(commitMessageNeedsFullReader("One\nTwo\nThree"))
        XCTAssertTrue(commitMessageNeedsFullReader("One\nTwo\nThree\nFour"))
        XCTAssertTrue(
            commitMessageNeedsFullReader(String(repeating: "long message ", count: 24))
        )
    }

    func testExpandedReviewFolderChoosesItsFirstSortedFile() {
        let first = makeFileItem(path: "Sources/First.swift")
        let second = makeFileItem(path: "Sources/Second.swift")
        let test = makeFileItem(path: "Tests/FirstTests.swift")
        let nodes = navigatorTreeNodes(
            items: [second, test, first],
            namespace: "context"
        )

        XCTAssertEqual(
            firstNavigatorFileID(
                in: "navigator-folder:context:Sources",
                nodes: nodes
            ),
            first.id.stackID
        )
        XCTAssertNil(
            firstNavigatorFileID(
                in: "navigator-folder:context:Missing",
                nodes: nodes
            )
        )
    }

    func testOverviewRowsExposeConciseVoiceOverLabels() {
        XCTAssertEqual(
            pendingOverviewAccessibilityLabel(
                workingCount: 3,
                untrackedCount: 2,
                stagedCount: 1
            ),
            "Pending Changes, 3 working, 2 untracked, 1 staged"
        )
        let commit = GitCommit(
            oid: "1234567890abcdef",
            shortOID: "1234567",
            authorName: "Review Author",
            authoredAt: Date(timeIntervalSince1970: 100),
            parentOIDs: [],
            refNames: ["HEAD -> main"],
            subject: "Accessible commit"
        )
        let label = commitRowAccessibilityLabel(commit)
        XCTAssertTrue(label.contains("Accessible commit"))
        XCTAssertTrue(label.contains("1234567"))
        XCTAssertTrue(label.contains("Review Author"))
        XCTAssertTrue(label.contains("main"))
    }

    func testPendingAndCommitSelectionsRemainMutuallyExclusive() {
        let first = IntegratedOverviewSelection.commit("first")
        let second = IntegratedOverviewSelection.commit("second")

        XCTAssertEqual(
            normalizedOverviewSelection(
                previous: [.pending],
                current: [.pending, first]
            ),
            [first]
        )
        XCTAssertEqual(
            normalizedOverviewSelection(
                previous: [first, second],
                current: [.pending, first, second]
            ),
            [.pending]
        )
        XCTAssertEqual(
            normalizedOverviewSelection(previous: [first], current: []),
            [.pending]
        )
    }

    func testUnresolvedRestorationNeverHighlightsPendingForCommitReview() {
        XCTAssertEqual(
            unresolvedOverviewSelection(
                context: .pending,
                selectedCommitIDs: []
            ),
            [.pending]
        )
        XCTAssertEqual(
            unresolvedOverviewSelection(
                context: .commit("commit"),
                selectedCommitIDs: []
            ),
            [.commit("commit")]
        )
        XCTAssertEqual(
            unresolvedOverviewSelection(
                context: .range(base: "base", head: "head"),
                selectedCommitIDs: ["head", "oldest"]
            ),
            [.commit("head"), .commit("oldest")]
        )
    }

    func testHistoryRestorationOnlyAcceptsTheSavedSearchSource() throws {
        let requestedQuery = try XCTUnwrap(GitHistorySearchQuery("fix(Ultron)"))
        let otherQuery = try XCTUnwrap(GitHistorySearchQuery("author:someone"))
        let requested = ReviewNavigationState(
            context: .commit("commit"),
            selectedCommitIDs: ["commit"],
            pane: .commits,
            historyFilter: "fix(Ultron)"
        )

        XCTAssertEqual(
            expectedHistoryRestorationQuery(
                requestedRestoration: requested,
                activeQuery: otherQuery
            ),
            requestedQuery
        )
        XCTAssertEqual(
            expectedHistoryRestorationQuery(
                requestedRestoration: nil,
                activeQuery: otherQuery
            ),
            otherQuery
        )
        XCTAssertNotEqual(requestedQuery, otherQuery)
    }

    func testCommitRangeSelectionKeepsOnlyVisibleEndpoints() {
        let firstOID = String(repeating: "a", count: 40)
        let secondOID = String(repeating: "b", count: 40)
        let thirdOID = String(repeating: "c", count: 40)
        let fourthOID = String(repeating: "d", count: 40)
        let commits = [
            makeCommit(oid: firstOID, parentOIDs: [secondOID]),
            makeCommit(oid: secondOID, parentOIDs: [thirdOID]),
            makeCommit(oid: thirdOID, parentOIDs: [fourthOID]),
            makeCommit(oid: fourthOID, parentOIDs: [])
        ]

        XCTAssertEqual(
            normalizedCommitEndpointSelection(
                [.commit(firstOID), .commit(secondOID), .commit(fourthOID)],
                commits: commits
            ),
            [.commit(firstOID), .commit(fourthOID)]
        )
        XCTAssertEqual(
            normalizedCommitEndpointSelection(
                [.commit(secondOID), .commit(thirdOID)],
                commits: commits
            ),
            [.commit(secondOID), .commit(thirdOID)]
        )
        XCTAssertEqual(
            normalizedCommitEndpointSelection(
                [.commit(firstOID), .commit(secondOID), .commit("missing")],
                commits: commits
            ),
            [.commit(firstOID), .commit(secondOID)]
        )
        XCTAssertEqual(
            normalizedCommitEndpointSelection(
                [.pending, .commit(firstOID)],
                commits: commits
            ),
            [.pending]
        )
    }

    func testFilesNavigatorPrimaryActionMatchesScopeAndSubmoduleState() {
        let ordinary = GitFileChange(
            path: "Sources/App.swift",
            originalPath: nil,
            indexStatus: "M",
            worktreeStatus: "M",
            kind: .ordinary
        )
        let working = IntegratedFileItem(
            id: .pending(scope: .working, changeID: ordinary.id),
            change: ordinary,
            scope: .working
        )
        let staged = IntegratedFileItem(
            id: .pending(scope: .staged, changeID: ordinary.id),
            change: ordinary,
            scope: .staged
        )
        XCTAssertEqual(
            primaryPendingMutationMode(context: .pending, item: working),
            .working
        )
        XCTAssertEqual(
            primaryPendingMutationMode(context: .pending, item: staged),
            .staged
        )
        XCTAssertEqual(
            pendingFilePrimaryCommand(
                context: .pending,
                focusedFileID: working.id.stackID,
                items: [working, staged]
            ),
            PendingFilePrimaryCommand(
                fileID: working.id.stackID,
                action: .stage
            )
        )
        XCTAssertEqual(
            pendingFilePrimaryCommand(
                context: .pending,
                focusedFileID: staged.id.stackID,
                items: [working, staged]
            ),
            PendingFilePrimaryCommand(
                fileID: staged.id.stackID,
                action: .unstage
            )
        )
        XCTAssertEqual(
            pendingFileDiscardCommand(
                context: .pending,
                focusedFileID: working.id.stackID,
                items: [working, staged]
            ),
            PendingFilePrimaryCommand(
                fileID: working.id.stackID,
                action: .discard
            )
        )
        XCTAssertNil(
            pendingFileDiscardCommand(
                context: .pending,
                focusedFileID: staged.id.stackID,
                items: [working, staged]
            )
        )
        XCTAssertNil(
            pendingFilePrimaryCommand(
                context: .pending,
                focusedFileID: "missing",
                items: [working, staged]
            )
        )
        XCTAssertNil(
            primaryPendingMutationMode(
                context: .commit("commit"),
                item: working
            )
        )
        let voiceOverDiff = GitFileDiff(
            change: ordinary,
            scope: .working,
            hunks: [],
            state: .textual,
            addedLineCount: 3,
            deletedLineCount: 2
        )
        XCTAssertEqual(
            navigatorFileAccessibilityLabel(
                item: working,
                diff: voiceOverDiff,
                isReviewed: true
            ),
            "Sources/App.swift, modified, 3 additions, 2 deletions, reviewed"
        )
        XCTAssertEqual(
            navigatorFileHelpText(
                item: working,
                primaryActionTitle: "Stage",
                canDiscard: true
            ),
            "Sources/App.swift\n\nPress Space to stage this file. "
                + "Press Command-Shift-Delete twice to discard this file."
        )

        let dirtySubmodule = GitFileChange(
            path: "Dependencies/Module",
            originalPath: nil,
            indexStatus: ".",
            worktreeStatus: "M",
            kind: .ordinary,
            submoduleStatus: GitSubmoduleStatus(
                commitChanged: false,
                hasTrackedChanges: true,
                hasUntrackedChanges: false
            )
        )
        let dirtySubmoduleItem = IntegratedFileItem(
            id: .pending(scope: .working, changeID: dirtySubmodule.id),
            change: dirtySubmodule,
            scope: .working
        )
        XCTAssertNil(
            primaryPendingMutationMode(
                context: .pending,
                item: dirtySubmoduleItem
            )
        )
        XCTAssertNil(
            pendingFilePrimaryCommand(
                context: .pending,
                focusedFileID: dirtySubmoduleItem.id.stackID,
                items: [dirtySubmoduleItem]
            )
        )
        XCTAssertEqual(
            pendingFileDiscardCommand(
                context: .pending,
                focusedFileID: dirtySubmoduleItem.id.stackID,
                items: [dirtySubmoduleItem]
            ),
            PendingFilePrimaryCommand(
                fileID: dirtySubmoduleItem.id.stackID,
                action: .discard
            )
        )
    }

    func testFilesNavigatorSeparatesWorkingAndStagedCopiesOfSamePath() {
        let change = GitFileChange(
            path: "Sources/App.swift",
            originalPath: nil,
            indexStatus: "M",
            worktreeStatus: "M",
            kind: .ordinary
        )
        let working = IntegratedFileItem(
            id: .pending(scope: .working, changeID: change.id),
            change: change,
            scope: .working
        )
        let staged = IntegratedFileItem(
            id: .pending(scope: .staged, changeID: change.id),
            change: change,
            scope: .staged
        )

        let groups = pendingNavigatorFileGroups(
            workingItems: [working],
            untrackedItems: [],
            stagedItems: [staged]
        )

        XCTAssertEqual(groups.map(\.title), ["Working", "Staged"])
        XCTAssertEqual(groups[0].items, [working])
        XCTAssertEqual(groups[1].items, [staged])
        XCTAssertNotEqual(groups[0].items[0].id, groups[1].items[0].id)
    }

    func testFilesNavigatorBuildsCollapsedFolderTree() throws {
        let readme = makeFileItem(path: "README.md")
        let app = makeFileItem(path: "Sources/App.swift")
        let feature = makeFileItem(path: "Sources/Feature/Thing.swift")
        let nodes = navigatorTreeNodes(
            items: [feature, readme, app],
            namespace: "working"
        )

        XCTAssertEqual(nodes.count, 2)
        guard case let .folder(sourceID, sourceName, sourceCount, sourceChildren) = nodes[0]
        else {
            return XCTFail("Expected Sources folder")
        }
        XCTAssertEqual(sourceName, "Sources")
        XCTAssertEqual(sourceCount, 2)
        XCTAssertEqual(sourceChildren.count, 2)
        guard case let .file(rootFile) = nodes[1] else {
            return XCTFail("Expected root file")
        }
        XCTAssertEqual(rootFile, readme)

        XCTAssertEqual(
            flattenedNavigatorTreeRows(
                nodes: nodes,
                expandedFolderIDs: []
            ).map(\.id),
            [sourceID, "navigator-file:\(readme.id.stackID)"]
        )

        guard case let .folder(featureID, _, _, _) = sourceChildren[0] else {
            return XCTFail("Expected nested Feature folder")
        }
        let sourceExpanded = flattenedNavigatorTreeRows(
            nodes: nodes,
            expandedFolderIDs: [sourceID]
        )
        XCTAssertEqual(
            sourceExpanded.map(\.id),
            [
                sourceID,
                featureID,
                "navigator-file:\(app.id.stackID)",
                "navigator-file:\(readme.id.stackID)"
            ]
        )
        XCTAssertEqual(sourceExpanded.map(\.depth), [0, 1, 1, 0])

        let fullyExpanded = flattenedNavigatorTreeRows(
            nodes: nodes,
            expandedFolderIDs: [sourceID, featureID]
        )
        XCTAssertEqual(
            fullyExpanded.map(\.id),
            [
                sourceID,
                featureID,
                "navigator-file:\(feature.id.stackID)",
                "navigator-file:\(app.id.stackID)",
                "navigator-file:\(readme.id.stackID)"
            ]
        )
        XCTAssertEqual(fullyExpanded.map(\.depth), [0, 1, 2, 1, 0])
    }

    func testFilesNavigatorKeepsDuplicateNamesDistinctAcrossDeepPaths() {
        let first = makeFileItem(
            path: "Sources/Feature/VeryLongGeneratedDirectoryName/Config.swift"
        )
        let second = makeFileItem(
            path: "Tests/Fixtures/VeryLongGeneratedDirectoryName/Config.swift"
        )
        let nodes = navigatorTreeNodes(
            items: [second, first],
            namespace: "context"
        )
        let rows = flattenedNavigatorTreeRows(
            nodes: nodes,
            expandedFolderIDs: navigatorFolderIDs(in: nodes)
        )
        let files = rows.compactMap { row -> IntegratedFileItem? in
            guard case let .file(item) = row.content else {
                return nil
            }
            return item
        }

        XCTAssertEqual(files.map(\.change.path), [first.change.path, second.change.path])
        XCTAssertEqual(Set(files.map { $0.id.stackID }).count, 2)
        XCTAssertTrue(rows.contains { $0.depth >= 3 })
    }

    func testFilesNavigatorFolderIdentityIncludesChangeScope() throws {
        let item = makeFileItem(path: "Sources/App.swift")
        let working = navigatorTreeNodes(items: [item], namespace: "working")
        let staged = navigatorTreeNodes(items: [item], namespace: "staged")

        XCTAssertNotEqual(working.first?.id, staged.first?.id)
    }

    func testFilesNavigatorFilterKeepsMatchingAncestorsAndUpdatesCounts() {
        let feature = makeFileItem(path: "Sources/Feature/Thing.swift")
        let app = makeFileItem(path: "Sources/App.swift")
        let guide = makeFileItem(path: "Docs/Guide.md")
        let nodes = navigatorTreeNodes(
            items: [feature, app, guide],
            namespace: "working"
        )

        let filtered = filteredNavigatorTreeNodes(
            nodes,
            query: "feature/thing"
        )
        let folderIDs = navigatorFolderIDs(in: filtered)
        let rows = flattenedNavigatorTreeRows(
            nodes: filtered,
            expandedFolderIDs: folderIDs
        )
        let files = rows.compactMap { row -> IntegratedFileItem? in
            guard case let .file(item) = row.content else {
                return nil
            }
            return item
        }

        XCTAssertEqual(folderIDs.count, 2)
        XCTAssertEqual(files, [feature])
        guard case let .folder(_, _, fileCount, _) = filtered.first else {
            return XCTFail("Expected matching Sources folder")
        }
        XCTAssertEqual(fileCount, 1)
    }

    @MainActor
    func testFilesNavigatorTreeCacheReusesUnchangedInput() {
        let cache = NavigatorTreeCache()
        let first = makeFileItem(path: "Sources/App.swift")
        let second = makeFileItem(path: "Sources/Feature/Thing.swift")

        _ = cache.nodes(items: [first], namespace: "working")
        _ = cache.nodes(items: [first], namespace: "working")
        XCTAssertEqual(cache.buildCount, 1)

        _ = cache.nodes(items: [first, second], namespace: "working")
        XCTAssertEqual(cache.buildCount, 2)

        _ = cache.nodes(items: [first], namespace: "staged")
        XCTAssertEqual(cache.buildCount, 3)
    }

    func testFilesNavigatorBuildsFortyThousandFileTreeWithinOneSecond() {
        let items = (0..<40_000).map { index in
            makeFileItem(
                path: "Sources/Module\(index % 100)/File\(index).swift"
            )
        }
        var nodes: [NavigatorTreeNode] = []

        let elapsed = ContinuousClock().measure {
            nodes = navigatorTreeNodes(items: items, namespace: "performance")
        }

        XCTAssertEqual(navigatorFolderIDs(in: nodes).count, 101)
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testPendingItemsAndBothTreesBuildFortyThousandChangesWithinOneSecond() {
        let changes = (0..<40_000).map { index -> GitFileChange in
            let status: (index: Character, worktree: Character, kind: GitChangeKind) =
                switch index % 4 {
                case 0: ("M", "M", .ordinary)
                case 1: (".", "M", .ordinary)
                case 2: ("M", ".", .ordinary)
                default: ("?", "?", .untracked)
                }
            return GitFileChange(
                path: "Sources/Module\(index % 100)/File\(index).swift",
                originalPath: nil,
                indexStatus: status.index,
                worktreeStatus: status.worktree,
                kind: status.kind
            )
        }
        let snapshot = GitWorktreeSnapshot(
            worktree: GitWorktree(
                rootURL: URL(fileURLWithPath: "/worktrees/performance"),
                headOID: String(repeating: "a", count: 40),
                branchRef: "refs/heads/main",
                isBare: false,
                isDetached: false,
                lockedReason: nil,
                prunableReason: nil
            ),
            status: GitStatusSnapshot(changes: changes),
            diffStat: .zero,
            lastActivityAt: Date(),
            errorMessage: nil
        )
        var pending = PendingIntegratedFileItems(
            working: [],
            untracked: [],
            staged: []
        )
        var workingTree: [NavigatorTreeNode] = []
        var stagedTree: [NavigatorTreeNode] = []

        let elapsed = ContinuousClock().measure {
            pending = pendingIntegratedFileItems(in: snapshot)
            workingTree = navigatorTreeNodes(
                items: pending.working + pending.untracked,
                namespace: "working"
            )
            stagedTree = navigatorTreeNodes(
                items: pending.staged,
                namespace: "staged"
            )
        }

        XCTAssertEqual(pending.working.count, 20_000)
        XCTAssertEqual(pending.untracked.count, 10_000)
        XCTAssertEqual(pending.staged.count, 20_000)
        XCTAssertEqual(navigatorFolderIDs(in: workingTree).count, 76)
        XCTAssertEqual(navigatorFolderIDs(in: stagedTree).count, 51)
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testDiffFocusDoesNotRequestAFileHeaderScroll() {
        XCTAssertEqual(
            diffReviewScrollTarget(
                focusedFileID: "working:file",
                fileFocusedFromDiffID: nil
            ),
            "working:file"
        )
        XCTAssertNil(
            diffReviewScrollTarget(
                focusedFileID: "working:file",
                fileFocusedFromDiffID: "working:file"
            )
        )
        XCTAssertNil(
            diffReviewScrollTarget(
                focusedFileID: nil,
                fileFocusedFromDiffID: nil
            )
        )
    }

    func testRestoresExactCommitAndRangeSelectionsFromHistory() {
        let rootOID = String(repeating: "a", count: 40)
        let middleOID = String(repeating: "b", count: 40)
        let headOID = String(repeating: "c", count: 40)
        let commits = [
            makeCommit(oid: headOID, parentOIDs: [middleOID]),
            makeCommit(oid: middleOID, parentOIDs: [rootOID]),
            makeCommit(oid: rootOID, parentOIDs: [])
        ]
        let commitState = ReviewNavigationState(
            context: .commit(headOID),
            selectedCommitIDs: [headOID]
        )
        XCTAssertEqual(
            restoredHistorySelection(commitState, commits: commits),
            [.commit(headOID)]
        )

        let rangeState = ReviewNavigationState(
            context: .range(base: rootOID, head: headOID),
            selectedCommitIDs: [headOID, middleOID]
        )
        XCTAssertEqual(
            restoredHistorySelection(rangeState, commits: commits),
            [.commit(headOID), .commit(middleOID)]
        )
        let compatibleLegacyRange = ReviewNavigationState(
            context: rangeState.context,
            selectedCommitIDs: []
        )
        XCTAssertEqual(
            restoredHistorySelection(
                compatibleLegacyRange,
                commits: commits
            ),
            [.commit(headOID), .commit(middleOID)]
        )
        XCTAssertNil(
            restoredHistorySelection(
                ReviewNavigationState(
                    context: .commit("missing"),
                    selectedCommitIDs: ["missing"]
                ),
                commits: commits
            )
        )

        let legacyMultiSelection = ReviewNavigationState(
            context: .range(
                base: "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
                head: headOID
            ),
            selectedCommitIDs: [headOID, middleOID, rootOID]
        )
        XCTAssertEqual(
            restoredHistorySelection(
                legacyMultiSelection,
                commits: commits
            ),
            [.commit(headOID), .commit(rootOID)]
        )
        XCTAssertEqual(
            historyScrollTargetID(
                selection: [.commit(middleOID), .commit(rootOID)],
                commits: commits
            ),
            middleOID
        )
        XCTAssertNil(
            historyScrollTargetID(
                selection: [.pending],
                commits: commits
            )
        )
        XCTAssertEqual(
            historyRestorationCommitIDs(commitState),
            [headOID]
        )
        XCTAssertEqual(
            historyRestorationCommitIDs(rangeState),
            [headOID, middleOID]
        )
        XCTAssertEqual(
            historyRestorationCommitIDs(compatibleLegacyRange),
            [headOID, rootOID]
        )
    }

    func testRequestedHistoryContextRemainsActiveWhileSearchReloads() {
        let commitID = String(repeating: "a", count: 40)
        let commit = makeCommit(oid: commitID, parentOIDs: [])
        let requested = ReviewNavigationState(
            context: .commit(commitID),
            selectedCommitIDs: [commitID],
            pane: .files,
            historyFilter: "author:reviewer"
        )

        XCTAssertEqual(
            effectiveReviewContext(
                requestedRestoration: requested,
                selectedCommits: []
            ),
            .commit(commitID)
        )
        XCTAssertEqual(
            effectiveReviewContext(
                requestedRestoration: nil,
                selectedCommits: [commit]
            ),
            .commit(commitID)
        )
        XCTAssertEqual(
            effectiveReviewContext(
                requestedRestoration: nil,
                selectedCommits: []
            ),
            .pending
        )
    }

    func testHistoryFilterNavigationPreservesReachableCommitLocations() throws {
        let baseOID = String(repeating: "a", count: 40)
        let searchOID = String(repeating: "b", count: 40)
        let baseCommit = makeCommit(oid: baseOID, parentOIDs: [])
        let searchCommit = makeCommit(oid: searchOID, parentOIDs: [baseOID])

        let enteringSearch = try XCTUnwrap(
            historyFilterNavigationTransition(
                previousFilter: "",
                currentFilter: "message:search",
                selectedCommitIDs: [baseOID],
                pane: .commits,
                baseCommits: [baseCommit],
                searchedCommits: []
            )
        )
        XCTAssertEqual(enteringSearch.previous.context, .commit(baseOID))
        XCTAssertEqual(enteringSearch.current.context, .pending)
        XCTAssertEqual(enteringSearch.selection, [.pending])

        let equivalentSearch = try XCTUnwrap(
            historyFilterNavigationTransition(
                previousFilter: " message:search ",
                currentFilter: "message:search",
                selectedCommitIDs: [searchOID],
                pane: .files,
                baseCommits: [baseCommit],
                searchedCommits: [searchCommit]
            )
        )
        XCTAssertEqual(equivalentSearch.current.context, .commit(searchOID))
        XCTAssertEqual(equivalentSearch.current.pane, .files)
        XCTAssertEqual(
            equivalentSearch.selection,
            [.commit(searchOID)]
        )

        let clearingSearch = try XCTUnwrap(
            historyFilterNavigationTransition(
                previousFilter: "message:search",
                currentFilter: "",
                selectedCommitIDs: [searchOID],
                pane: .commits,
                baseCommits: [baseCommit],
                searchedCommits: [searchCommit]
            )
        )
        XCTAssertEqual(clearingSearch.previous.context, .commit(searchOID))
        XCTAssertEqual(clearingSearch.current.context, .pending)
        XCTAssertEqual(clearingSearch.selection, [.pending])
    }

    func testHistorySearchPageCacheUsesRecentQueriesAndKeepsPagination() throws {
        let worktreeID = "/worktrees/feature"
        let firstKey = HistorySearchLoadKey(
            worktreeID: worktreeID,
            revision: "head",
            query: try XCTUnwrap(GitHistorySearchQuery("first"))
        )
        let secondKey = HistorySearchLoadKey(
            worktreeID: worktreeID,
            revision: "head",
            query: try XCTUnwrap(GitHistorySearchQuery("second"))
        )
        let thirdKey = HistorySearchLoadKey(
            worktreeID: worktreeID,
            revision: "head",
            query: try XCTUnwrap(GitHistorySearchQuery("third"))
        )
        let firstPage = GitHistoryPage(
            commits: [makeCommit(oid: "first", parentOIDs: [])],
            nextOffset: 100,
            hasMore: true
        )
        let secondPage = GitHistoryPage(
            commits: [makeCommit(oid: "second", parentOIDs: [])],
            nextOffset: 20,
            hasMore: false
        )
        let thirdPage = GitHistoryPage(
            commits: [makeCommit(oid: "third", parentOIDs: [])],
            nextOffset: 30,
            hasMore: false
        )
        var cache = HistorySearchPageCache(maximumEntryCount: 2)

        cache.insert(firstPage, for: firstKey)
        cache.insert(secondPage, for: secondKey)
        XCTAssertEqual(cache.page(for: firstKey), firstPage)
        cache.insert(thirdPage, for: thirdKey)

        XCTAssertNil(cache.page(for: secondKey))
        XCTAssertEqual(cache.page(for: firstKey), firstPage)
        XCTAssertEqual(cache.page(for: thirdKey), thirdPage)
        cache.removeAll()
        XCTAssertNil(cache.page(for: firstKey))

        var commitLimitedCache = HistorySearchPageCache(
            maximumEntryCount: 2,
            maximumCommitCountPerEntry: 1,
            maximumEntryByteCount: .max,
            maximumTotalByteCount: .max
        )
        commitLimitedCache.insert(firstPage, for: firstKey)
        XCTAssertEqual(commitLimitedCache.page(for: firstKey), firstPage)
        commitLimitedCache.insert(
            GitHistoryPage(
                commits: firstPage.commits + secondPage.commits,
                nextOffset: 2,
                hasMore: true
            ),
            for: firstKey
        )
        XCTAssertNil(commitLimitedCache.page(for: firstKey))

        var byteLimitedCache = HistorySearchPageCache(
            maximumEntryCount: 2,
            maximumCommitCountPerEntry: 10,
            maximumEntryByteCount: 1,
            maximumTotalByteCount: .max
        )
        byteLimitedCache.insert(firstPage, for: firstKey)
        XCTAssertNil(byteLimitedCache.page(for: firstKey))

        var totalLimitedCache = HistorySearchPageCache(
            maximumEntryCount: 2,
            maximumCommitCountPerEntry: 10,
            maximumEntryByteCount: .max,
            maximumTotalByteCount: 1
        )
        totalLimitedCache.insert(firstPage, for: firstKey)
        XCTAssertNil(totalLimitedCache.page(for: firstKey))
    }

    func testCompletedHistorySearchDoesNotReloadWhenApplicationReactivates() throws {
        let query = try XCTUnwrap(GitHistorySearchQuery("author:reviewer"))
        let completed = HistorySearchLoadKey(
            worktreeID: "/worktrees/feature",
            revision: "head",
            query: query
        )

        XCTAssertFalse(
            shouldLoadHistorySearch(
                requested: completed,
                completed: completed
            )
        )
        XCTAssertTrue(
            shouldLoadHistorySearch(
                requested: HistorySearchLoadKey(
                    worktreeID: completed.worktreeID,
                    revision: "new-head",
                    query: query
                ),
                completed: completed
            )
        )
        XCTAssertFalse(
            shouldLoadHistorySearch(
                requested: HistorySearchLoadKey(
                    worktreeID: completed.worktreeID,
                    revision: completed.revision,
                    query: nil
                ),
                completed: completed
            )
        )
    }

    func testLaterDiffBatchKeepsFilesLoadedByEarlierBatch() {
        let firstChange = GitFileChange(
            path: "Sources/First.swift",
            originalPath: nil,
            indexStatus: "M",
            worktreeStatus: ".",
            kind: .ordinary
        )
        let secondChange = GitFileChange(
            path: "Sources/Second.swift",
            originalPath: nil,
            indexStatus: "M",
            worktreeStatus: ".",
            kind: .ordinary
        )
        let firstItem = IntegratedFileItem(
            id: .pending(scope: .staged, changeID: firstChange.id),
            change: firstChange,
            scope: .staged
        )
        let secondItem = IntegratedFileItem(
            id: .pending(scope: .staged, changeID: secondChange.id),
            change: secondChange,
            scope: .staged
        )
        let firstDiff = GitFileDiff(
            change: firstChange,
            scope: .staged,
            hunks: [],
            state: .textual
        )
        let secondDiff = GitFileDiff(
            change: secondChange,
            scope: .staged,
            hunks: [],
            state: .textual
        )
        var result: [IntegratedFileID: GitFileDiff] = [:]

        mergeIntegratedDiffBatch(
            diffs: [firstDiff],
            into: &result,
            items: [firstItem, secondItem]
        )
        mergeIntegratedDiffBatch(
            diffs: [secondDiff],
            into: &result,
            items: [firstItem, secondItem]
        )

        XCTAssertEqual(result[firstItem.id], firstDiff)
        XCTAssertEqual(result[secondItem.id], secondDiff)
        XCTAssertEqual(result.count, 2)
    }

    func testPendingDiffCacheRequiresEveryScopeAndFile() throws {
        let change = GitFileChange(
            path: "Sources/Shared.swift",
            originalPath: nil,
            indexStatus: "M",
            worktreeStatus: "M",
            kind: .ordinary
        )
        let workingItem = IntegratedFileItem(
            id: .pending(scope: .working, changeID: change.id),
            change: change,
            scope: .working
        )
        let stagedItem = IntegratedFileItem(
            id: .pending(scope: .staged, changeID: change.id),
            change: change,
            scope: .staged
        )
        let workingDiff = GitFileDiff(
            change: change,
            scope: .working,
            hunks: [],
            state: .textual
        )
        let stagedDiff = GitFileDiff(
            change: change,
            scope: .staged,
            hunks: [],
            state: .binary
        )

        let restored = try XCTUnwrap(
            completeIntegratedDiffCache(
                diffs: [workingDiff, stagedDiff],
                items: [workingItem, stagedItem]
            )
        )
        XCTAssertEqual(restored[workingItem.id], workingDiff)
        XCTAssertEqual(restored[stagedItem.id], stagedDiff)
        XCTAssertNil(
            completeIntegratedDiffCache(
                diffs: [workingDiff],
                items: [workingItem, stagedItem]
            )
        )
        let partial = integratedDiffCache(
            diffs: [workingDiff],
            items: [workingItem, stagedItem]
        )
        XCTAssertEqual(partial, [workingItem.id: workingDiff])
        XCTAssertEqual(
            integratedItemsMissingDiff(
                [workingItem, stagedItem],
                cached: partial
            ).map(\.id),
            [stagedItem.id]
        )
        XCTAssertEqual(
            sortedIntegratedDiffs(restored),
            [stagedDiff, workingDiff]
        )
        XCTAssertTrue(
            shouldFinalizeDiffCache(
                ReviewDiffCacheEntry(
                    diffs: [workingDiff, stagedDiff],
                    isComplete: false
                ),
                missingItemCount: 0
            )
        )
        XCTAssertFalse(
            shouldFinalizeDiffCache(
                ReviewDiffCacheEntry(
                    diffs: [workingDiff],
                    isComplete: false
                ),
                missingItemCount: 1
            )
        )
        XCTAssertFalse(
            shouldFinalizeDiffCache(
                ReviewDiffCacheEntry(
                    diffs: [workingDiff, stagedDiff],
                    isComplete: true
                ),
                missingItemCount: 0
            )
        )
    }

    func testWorkingFileAvailabilityIncludesOnlyExistingRegularFiles() throws {
        let root = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-files/file-availability-\(UUID().uuidString)",
            isDirectory: true
        )
        let file = root.appendingPathComponent("file.swift")
        let directory = root.appendingPathComponent("folder", isDirectory: true)
        let missing = root.appendingPathComponent("missing.swift")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("let value = 1\n".utf8).write(to: file)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        XCTAssertEqual(
            existingRegularFileIDs(
                for: [
                    WorkingFileCandidate(id: "file", path: file.path),
                    WorkingFileCandidate(id: "directory", path: directory.path),
                    WorkingFileCandidate(id: "missing", path: missing.path)
                ]
            ),
            ["file"]
        )
    }

    func testRemoteOperationsRequireAnIdleTrackedBranch() {
        let branch = GitWorktree(
            rootURL: URL(fileURLWithPath: "/worktrees/feature"),
            headOID: String(repeating: "a", count: 40),
            branchRef: "refs/heads/feature",
            isBare: false,
            isDetached: false,
            lockedReason: nil,
            prunableReason: nil
        )
        let upstream = GitBranchStatus(
            upstreamRef: "origin/feature",
            aheadCount: 0,
            behindCount: 0
        )

        XCTAssertNil(
            gitRemoteOperationUnavailableReason(
                worktree: branch,
                branchStatus: upstream,
                isApplyingMutation: false,
                runningAction: nil
            )
        )
        XCTAssertEqual(
            gitRemoteOperationUnavailableReason(
                worktree: branch,
                branchStatus: nil,
                isApplyingMutation: false,
                runningAction: nil
            ),
            "Pull requires an upstream branch."
        )
        XCTAssertNil(
            gitRemoteOperationUnavailableReason(
                action: .push,
                worktree: branch,
                branchStatus: nil,
                isApplyingMutation: false,
                runningAction: nil
            )
        )
        XCTAssertEqual(
            gitRemoteOperationUnavailableReason(
                worktree: branch,
                branchStatus: upstream,
                isApplyingMutation: true,
                runningAction: nil
            ),
            "Wait for the current Git change operation to finish."
        )
        XCTAssertEqual(
            gitRemoteOperationUnavailableReason(
                worktree: branch,
                branchStatus: upstream,
                isApplyingMutation: false,
                runningAction: nil,
                hasUnresolvedRefreshFailure: true
            ),
            "Refresh repository status before running another Git operation."
        )
        XCTAssertEqual(
            gitRemoteOperationUnavailableReason(
                worktree: branch,
                branchStatus: upstream,
                isApplyingMutation: false,
                runningAction: nil,
                isRefreshingRepository: true
            ),
            "Wait for the repository status update to finish."
        )
        let unavailableUpstream = GitBranchStatus(
            upstreamRef: "origin/feature",
            aheadCount: 0,
            behindCount: 0,
            upstreamError: "Ahead/behind: Upstream origin/feature is unavailable."
        )
        XCTAssertEqual(
            gitRemoteOperationUnavailableReason(
                worktree: branch,
                branchStatus: unavailableUpstream,
                isApplyingMutation: false,
                runningAction: nil
            ),
            nil
        )
        XCTAssertNil(
            gitRemoteOperationUnavailableReason(
                action: .push,
                worktree: branch,
                branchStatus: unavailableUpstream,
                isApplyingMutation: false,
                runningAction: nil
            )
        )
        XCTAssertEqual(
            gitRemoteOperationUnavailableReason(
                worktree: branch,
                branchStatus: upstream,
                isApplyingMutation: false,
                runningAction: .pull
            ),
            "Pull is already in progress."
        )

        let detached = GitWorktree(
            rootURL: branch.rootURL,
            headOID: branch.headOID,
            branchRef: nil,
            isBare: false,
            isDetached: true,
            lockedReason: nil,
            prunableReason: nil
        )
        XCTAssertEqual(
            gitRemoteOperationUnavailableReason(
                worktree: detached,
                branchStatus: upstream,
                isApplyingMutation: false,
                runningAction: nil
            ),
            "Pull requires a checked-out branch."
        )

        let unborn = GitWorktree(
            rootURL: branch.rootURL,
            headOID: String(repeating: "0", count: 40),
            branchRef: "refs/heads/new",
            isBare: false,
            isDetached: false,
            lockedReason: nil,
            prunableReason: nil
        )
        XCTAssertEqual(
            gitRemoteOperationUnavailableReason(
                worktree: unborn,
                branchStatus: upstream,
                isApplyingMutation: false,
                runningAction: nil
            ),
            "Pull requires an initial commit."
        )
        XCTAssertEqual(gitPushActionTitle(branchStatus: nil), "Publish")
        XCTAssertEqual(gitPushActionTitle(branchStatus: upstream), "Push")

        let behind = GitBranchStatus(
            upstreamRef: "origin/feature",
            aheadCount: 0,
            behindCount: 2
        )
        XCTAssertNil(
            gitRemoteOperationUnavailableReason(
                action: .pull,
                worktree: branch,
                branchStatus: behind,
                isApplyingMutation: false,
                runningAction: nil
            )
        )
        XCTAssertEqual(
            gitRemoteOperationUnavailableReason(
                action: .push,
                worktree: branch,
                branchStatus: behind,
                isApplyingMutation: false,
                runningAction: nil
            ),
            "Pull upstream changes before pushing."
        )

        let diverged = GitBranchStatus(
            upstreamRef: "origin/feature",
            aheadCount: 1,
            behindCount: 1
        )
        for action in [GitRemoteAction.pull, .push] {
            XCTAssertEqual(
                gitRemoteOperationUnavailableReason(
                    action: action,
                    worktree: branch,
                    branchStatus: diverged,
                    isApplyingMutation: false,
                    runningAction: nil
                ),
                "Local and upstream branches have diverged. Resolve the branch before "
                    + "pulling or pushing."
            )
        }
    }

    func testRemoteOperationFeedbackUsesTransientResultMeaning() {
        let completed = RemoteOperationFeedback(action: .push, outcome: .completed)
        let cancelled = RemoteOperationFeedback(action: .pull, outcome: .cancelled)

        XCTAssertEqual(completed.systemImage, "checkmark.circle.fill")
        XCTAssertEqual(completed.message, "Push completed")
        XCTAssertEqual(completed.compactTitle, "Push complete")
        XCTAssertEqual(cancelled.systemImage, "xmark.circle")
        XCTAssertEqual(cancelled.message, "Pull cancelled")
        XCTAssertEqual(cancelled.compactTitle, "Cancelled")
        XCTAssertEqual(
            gitRemoteOperationFailureMessage(
                action: .push,
                error: GitRemoteActionError.noRemote
            ),
            "Push failed: Add a Git remote before publishing this branch."
        )
        XCTAssertEqual(
            gitRemoteOperationFailureMessage(
                action: .pull,
                error: GitCommandFailure(
                    arguments: ["pull", "--ff-only"],
                    exitCode: 1,
                    stderr: "fatal: Not possible to fast-forward"
                )
            ),
            "Pull failed: fatal: Not possible to fast-forward"
        )
    }

    func testMutationRefreshFailureMessageOnlyExistsForFailedRefresh() {
        XCTAssertNil(mutationRefreshFailureMessage(.updated))
        XCTAssertNil(mutationRefreshFailureMessage(.superseded))
        XCTAssertEqual(
            mutationRefreshFailureMessage(.failed("status timed out")),
            "Git operation completed, but repository status could not be refreshed: "
                + "status timed out"
        )
    }

    @MainActor
    func testCancelledRemoteTaskStillRunsIndependentStatusRefresh() async {
        var didRefresh = false
        let parent = Task { @MainActor in
            while !Task.isCancelled {
                await Task.yield()
            }
            return await runIndependentWorktreeRefresh {
                didRefresh = true
                return .updated
            }
        }

        parent.cancel()
        let outcome = await parent.value

        XCTAssertEqual(outcome, .updated)
        XCTAssertTrue(didRefresh)
    }

    func testFilesNavigatorPreservesFocusAcrossTransientListRebuild() {
        XCTAssertEqual(
            acceptedNavigatorFileSelection(
                current: "working:Sources/App.swift",
                requested: nil,
                hasVisibleFiles: true
            ),
            "working:Sources/App.swift"
        )
        XCTAssertEqual(
            acceptedNavigatorFileSelection(
                current: "working:Sources/App.swift",
                requested: "staged:Sources/App.swift",
                hasVisibleFiles: true
            ),
            "staged:Sources/App.swift"
        )
        XCTAssertNil(
            acceptedNavigatorFileSelection(
                current: "working:Sources/App.swift",
                requested: nil,
                hasVisibleFiles: false
            )
        )
    }

    func testDiffLoadIdentityRejectsStaleWorktreeAndSnapshotResults() {
        let change = GitFileChange(
            path: "Sources/App.swift",
            originalPath: nil,
            indexStatus: ".",
            worktreeStatus: "M",
            kind: .ordinary
        )
        let fileID = IntegratedFileID.pending(
            scope: .working,
            changeID: change.id
        )
        let activityDate = Date(timeIntervalSince1970: 1_000)
        let options = GitDiffOptions(
            context: .lines(3),
            ignoresWhitespace: false
        )
        let requested = IntegratedDiffLoadKey(
            worktreeID: "/worktrees/first",
            activityDate: activityDate,
            context: .pending,
            options: options,
            fileIDs: [fileID]
        )

        XCTAssertTrue(
            acceptsIntegratedDiffLoad(
                currentWorktreeID: requested.worktreeID,
                currentActivityDate: activityDate,
                currentContext: .pending,
                currentOptions: options,
                currentFileIDs: [fileID],
                requested: requested
            )
        )
        XCTAssertFalse(
            acceptsIntegratedDiffLoad(
                currentWorktreeID: "/worktrees/second",
                currentActivityDate: activityDate,
                currentContext: .pending,
                currentOptions: options,
                currentFileIDs: [fileID],
                requested: requested
            )
        )
        XCTAssertFalse(
            acceptsIntegratedDiffLoad(
                currentWorktreeID: requested.worktreeID,
                currentActivityDate: activityDate.addingTimeInterval(1),
                currentContext: .pending,
                currentOptions: options,
                currentFileIDs: [fileID],
                requested: requested
            )
        )
        XCTAssertFalse(
            acceptsIntegratedDiffLoad(
                currentWorktreeID: requested.worktreeID,
                currentActivityDate: activityDate,
                currentContext: .pending,
                currentOptions: GitDiffOptions(
                    context: .lines(25),
                    ignoresWhitespace: false
                ),
                currentFileIDs: [fileID],
                requested: requested
            )
        )
        XCTAssertFalse(
            acceptsIntegratedDiffLoad(
                currentWorktreeID: requested.worktreeID,
                currentActivityDate: activityDate,
                currentContext: .pending,
                currentOptions: options,
                currentFileIDs: [],
                requested: requested
            )
        )

        let sharedCommit = ReviewContext.commit(
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )
        let requestedReview = ReviewStateKey(
            worktreeID: "/worktrees/first",
            context: sharedCommit
        )
        XCTAssertTrue(
            reviewStateRequestMatches(
                currentWorktreeID: "/worktrees/first",
                currentContext: sharedCommit,
                requested: requestedReview
            )
        )
        XCTAssertFalse(
            reviewStateRequestMatches(
                currentWorktreeID: "/worktrees/second",
                currentContext: sharedCommit,
                requested: requestedReview
            )
        )

        let availabilityRequest = WorkingFileAvailabilityKey(
            worktreeID: requested.worktreeID,
            activityDate: activityDate,
            context: .pending,
            fileIDs: [fileID]
        )
        XCTAssertTrue(
            workingFileAvailabilityRequestMatches(
                currentWorktreeID: requested.worktreeID,
                currentActivityDate: activityDate,
                currentContext: .pending,
                currentFileIDs: [fileID],
                requested: availabilityRequest
            )
        )
        XCTAssertFalse(
            workingFileAvailabilityRequestMatches(
                currentWorktreeID: "/worktrees/second",
                currentActivityDate: activityDate,
                currentContext: .pending,
                currentFileIDs: [fileID],
                requested: availabilityRequest
            )
        )
    }

    func testOperationResultOnlyUpdatesOriginatingWorktreeAndSequence() {
        let request = ReviewOperationRequest(
            worktreeID: "/worktrees/first",
            sequence: 7
        )
        XCTAssertTrue(
            reviewOperationRequestMatches(
                currentWorktreeID: "/worktrees/first",
                currentSequence: 7,
                requested: request
            )
        )
        XCTAssertFalse(
            reviewOperationRequestMatches(
                currentWorktreeID: "/worktrees/second",
                currentSequence: 7,
                requested: request
            )
        )
        XCTAssertFalse(
            reviewOperationRequestMatches(
                currentWorktreeID: "/worktrees/first",
                currentSequence: 8,
                requested: request
            )
        )
    }

    private func makeCommit(
        oid: String,
        parentOIDs: [String]
    ) -> GitCommit {
        GitCommit(
            oid: oid,
            shortOID: String(oid.prefix(7)),
            authorName: "AgentGit Tests",
            authoredAt: Date(timeIntervalSince1970: 100),
            parentOIDs: parentOIDs,
            refNames: [],
            subject: oid
        )
    }

    private func makeFileItem(path: String) -> IntegratedFileItem {
        let change = GitFileChange(
            path: path,
            originalPath: nil,
            indexStatus: ".",
            worktreeStatus: "M",
            kind: .ordinary
        )
        return IntegratedFileItem(
            id: .pending(scope: .working, changeID: change.id),
            change: change,
            scope: .working
        )
    }
}
