import AgentGitCore
import AppKit
import SwiftUI
import XCTest
@testable import AgentGitApp

@MainActor
final class ContentViewLayoutTests: XCTestCase {
    func testWorktreeSwitcherFiltersProjectAndWorktreeMetadata() {
        let snapshot = makeProjectSnapshot()
        let states = [
            ProjectState(project: snapshot.project, snapshot: snapshot)
        ]

        XCTAssertEqual(
            worktreeSwitcherProjects(
                from: states,
                query: snapshot.project.displayName
            ).first?.worktrees.map(\.id),
            snapshot.worktrees.map(\.id)
        )
        XCTAssertEqual(
            worktreeSwitcherProjects(from: states, query: "main")
                .first?.worktrees.map(\.id),
            snapshot.worktrees.filter {
                worktreeMatchesSidebarFilter($0, query: "main")
            }.map(\.id)
        )
        XCTAssertTrue(
            worktreeSwitcherProjects(from: states, query: "missing-worktree")
                .isEmpty
        )
    }

    func testWorktreeSwitcherKeyboardSelectionMovesAcrossProjectSections() {
        let snapshot = makeProjectSnapshot()
        let projects = [
            WorktreeSwitcherProject(
                project: snapshot.project,
                worktrees: Array(snapshot.worktrees.prefix(2))
            ),
            WorktreeSwitcherProject(
                project: GitProject(
                    rootURL: URL(fileURLWithPath: "/projects/second")
                ),
                worktrees: Array(snapshot.worktrees.dropFirst(2))
            )
        ]
        let worktreeIDs = snapshot.worktrees.map(\.id)

        XCTAssertEqual(
            adjacentWorktreeSwitcherSelection(
                in: projects,
                current: nil,
                offset: 1
            ),
            worktreeIDs.first
        )
        XCTAssertEqual(
            adjacentWorktreeSwitcherSelection(
                in: projects,
                current: nil,
                offset: -1
            ),
            worktreeIDs.last
        )
        XCTAssertEqual(
            adjacentWorktreeSwitcherSelection(
                in: projects,
                current: worktreeIDs[1],
                offset: 1
            ),
            worktreeIDs[2]
        )
        XCTAssertEqual(
            adjacentWorktreeSwitcherSelection(
                in: projects,
                current: worktreeIDs.first,
                offset: -1
            ),
            worktreeIDs.first
        )
        XCTAssertEqual(
            adjacentWorktreeSwitcherSelection(
                in: projects,
                current: worktreeIDs.last,
                offset: 1
            ),
            worktreeIDs.last
        )
    }

    func testRendersRemoteOperationFeedbackOffscreen() async throws {
        let feedback = VStack(alignment: .leading, spacing: 10) {
            RemoteOperationFeedbackView(
                feedback: RemoteOperationFeedback(
                    action: .push,
                    outcome: .completed
                )
            )
            RemoteOperationFeedbackView(
                feedback: RemoteOperationFeedback(
                    action: .pull,
                    outcome: .cancelled
                )
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        try await render(
            feedback,
            size: NSSize(width: 220, height: 100),
            fileName: "AgentGitRemote-feedback.png",
            requiresPendingActions: false
        )
        try await render(
            feedback,
            size: NSSize(width: 220, height: 100),
            fileName: "AgentGitRemote-feedback-dark.png",
            appearanceName: .darkAqua,
            requiresPendingActions: false
        )
        let blockingError = BlockingGitRefreshErrorBar(
            message: "Git operation completed, but repository status could not be refreshed."
        ) {}
        try await render(
            blockingError,
            size: NSSize(width: 620, height: 44),
            fileName: "AgentGitBlocking-refresh-error.png",
            requiresPendingActions: false
        )
        try await render(
            blockingError,
            size: NSSize(width: 620, height: 44),
            fileName: "AgentGitBlocking-refresh-error-dark.png",
            appearanceName: .darkAqua,
            requiresPendingActions: false
        )
        try await render(
            BlockingGitRefreshErrorBar(
                message: "Git operation completed, but repository status could not be refreshed.",
                isRefreshing: true
            ) {},
            size: NSSize(width: 620, height: 44),
            fileName: "AgentGitBlocking-refresh-progress.png",
            requiresPendingActions: false
        )
    }

    func testRendersCompactFilterRecoveryStateOffscreen() async throws {
        try await render(
            NavigatorFilterEmptyState(
                title: "No Matching Files",
                query: "missing-worktree",
                clearFilter: {}
            ),
            size: NSSize(width: 260, height: 150),
            fileName: "AgentGitNavigator-filter-empty.png",
            requiresPendingActions: false
        )
        try await render(
            NavigatorFilterEmptyState(
                title: "No Matching Files",
                query: "missing-worktree",
                clearFilter: {}
            ),
            size: NSSize(width: 260, height: 150),
            fileName: "AgentGitNavigator-filter-empty-dark.png",
            appearanceName: .darkAqua,
            requiresPendingActions: false
        )
    }

    func testRendersHunkHistoryFilterBarOffscreen() async throws {
        let filter = HunkHistoryFilter(
            worktreeID: "/repo",
            revision: "head",
            fileID: "file",
            path: "Sources/AgentGitApp/IntegratedReviewWorkspace.swift",
            startLine: 420,
            endLine: 438
        )
        try await render(
            HunkHistoryFilterBar(filter: filter, clear: {}),
            size: NSSize(width: 360, height: 32),
            fileName: "AgentGitHunk-history-filter.png",
            requiresPendingActions: false
        )
        try await render(
            HunkHistoryFilterBar(filter: filter, clear: {}),
            size: NSSize(width: 360, height: 32),
            fileName: "AgentGitHunk-history-filter-dark.png",
            appearanceName: .darkAqua,
            requiresPendingActions: false
        )
    }

    func testRendersCommitNavigatorOffscreen() async throws {
        let now = Date()
        let commits = [
            GitCommit(
                oid: String(repeating: "a", count: 40),
                shortOID: "aaaaaaa",
                authorName: "Example Author",
                authoredAt: now.addingTimeInterval(-60 * 5),
                parentOIDs: [String(repeating: "b", count: 40)],
                refNames: ["HEAD -> refs/heads/feature/review-alignment"],
                subject: "feat(review): align hunk history with Sublime Merge",
                changedFileCount: 6
            ),
            GitCommit(
                oid: String(repeating: "b", count: 40),
                shortOID: "bbbbbbb",
                authorName: "terrytan",
                authoredAt: now.addingTimeInterval(-60 * 28),
                parentOIDs: [String(repeating: "c", count: 40)],
                refNames: ["refs/remotes/origin/main"],
                subject: "fix(diff): preserve code position while expanding context",
                changedFileCount: 3
            ),
            GitCommit(
                oid: String(repeating: "c", count: 40),
                shortOID: "ccccccc",
                authorName: "wechat_music_aicase",
                authoredAt: now.addingTimeInterval(-60 * 60 * 26),
                parentOIDs: [],
                refNames: [],
                subject: "Initial review workspace",
                changedFileCount: 18
            )
        ]
        let graph = CommitGraphLayout(commits: commits)
        let content = VStack(spacing: 0) {
            ReviewPaneTabBar(selection: .constant(.commits))
            Divider()
            PendingOverviewRow(
                workingCount: 12,
                untrackedCount: 2,
                stagedCount: 4,
                graphWidth: graph.displayWidth
            )
            ForEach(commits) { commit in
                IntegratedCommitRow(
                    commit: commit,
                    graphRow: graph.rowsByCommitID[commit.id],
                    graphLaneCount: graph.renderedLaneCount,
                    graphWidth: graph.displayWidth,
                    isSearchResult: false
                )
            }
            Spacer(minLength: 0)
        }
        .background(Color(nsColor: AgentGitPalette.reviewNavigationBackground))

        try await render(
            content,
            size: NSSize(width: 400, height: 408),
            fileName: "AgentGitCommit-navigator.png",
            requiresPendingActions: false
        )
        try await render(
            content,
            size: NSSize(width: 400, height: 408),
            fileName: "AgentGitCommit-navigator-dark.png",
            appearanceName: .darkAqua,
            requiresPendingActions: false
        )
    }

    func testRestoresFilteredCommitBeyondFirstHistoryPageOffscreen() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/deep-history-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent(
            "repository",
            isDirectory: true
        )
        let snapshotCacheURL = container.appendingPathComponent(
            "project-snapshots.json"
        )
        let reviewCacheURL = container.appendingPathComponent(
            "review-content",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        let runner = GitCommandRunner()
        _ = try await runner.run(
            arguments: ["init", "-b", "main"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["config", "user.name", "History Restore"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["config", "user.email", "history@example.invalid"],
            workingDirectory: repository
        )
        for index in 0..<125 {
            _ = try await runner.run(
                arguments: [
                    "commit", "--allow-empty", "-m", "Restore commit \(index)"
                ],
                workingDirectory: repository
            )
        }
        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let snapshot = try XCTUnwrap(project.worktrees.first)
        let firstPage = try await service.loadHistoryPage(
            worktree: snapshot.worktree,
            revision: snapshot.worktree.headOID,
            offset: 0,
            pageSize: StartupReviewContent.historyPageSize
        )
        let secondPage = try await service.searchHistoryPage(
            worktree: snapshot.worktree,
            revision: snapshot.worktree.headOID,
            query: try XCTUnwrap(GitHistorySearchQuery("author:History Restore")),
            offset: StartupReviewContent.historyPageSize,
            pageSize: StartupReviewContent.historyPageSize
        )
        let target = try XCTUnwrap(secondPage.commits.dropFirst(20).first)
        let snapshotStore = ProjectSnapshotStore(fileURL: snapshotCacheURL)
        try await snapshotStore.save(
            projectIDs: [project.id],
            snapshots: [project],
            eventID: FSEventsGetCurrentEventId(),
            completeProjectIDs: [project.id]
        )
        let reviewStore = ReviewContentStore(directoryURL: reviewCacheURL)
        try await reviewStore.saveHistoryPage(
            firstPage,
            for: HistoryReviewContentCacheKey(
                worktreeID: snapshot.id,
                revision: snapshot.worktree.headOID,
                pageSize: StartupReviewContent.historyPageSize
            )
        )
        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([repository.path], forKey: "agentgit.project-paths")
        defaults.set(1, forKey: "agentgit.project-identity-version")
        defaults.set(repository.path, forKey: "agentgit.selected-worktree-id")
        defaults.set(
            repository.path,
            forKey: "agentgit.selected-worktree-project-id"
        )
        let expectedNavigation = ReviewNavigationState(
            context: .commit(target.id),
            selectedCommitIDs: [target.id],
            pane: .commits,
            historyFilter: "author:History Restore"
        )
        let reviewStates = ReviewStateStore(defaults: defaults)
        reviewStates.saveLastContext(
            expectedNavigation.context,
            selectedCommitIDs: expectedNavigation.selectedCommitIDs,
            pane: expectedNavigation.pane,
            historyFilter: expectedNavigation.historyFilter,
            for: snapshot.id
        )
        reviewStates.flush()
        let inactiveModel = AppModel(
            defaults: defaults,
            repositoryService: service,
            snapshotStore: ProjectSnapshotStore(fileURL: snapshotCacheURL),
            reviewContentStore: ReviewContentStore(directoryURL: reviewCacheURL)
        )
        inactiveModel.setApplicationActive(false)
        try await render(
            WorktreeReviewView(snapshot: snapshot).environment(inactiveModel),
            size: NSSize(width: 1_200, height: 680),
            fileName: "AgentGitContent-restored-search-background.png",
            requiresPendingActions: false,
            expectedLabels: ["Commit \(target.shortOID)"]
        )

        let model = AppModel(
            defaults: defaults,
            repositoryService: service,
            snapshotStore: ProjectSnapshotStore(fileURL: snapshotCacheURL),
            reviewContentStore: ReviewContentStore(directoryURL: reviewCacheURL)
        )
        defer { model.setApplicationActive(false) }

        try await render(
            WorktreeReviewView(snapshot: snapshot).environment(model),
            size: NSSize(width: 1_200, height: 680),
            fileName: "AgentGitContent-restored-deep-search.png",
            settleDuration: .seconds(2),
            requiresPendingActions: false,
            expectedLabels: [target.subject]
        )

        XCTAssertEqual(
            model.reviewStates.lastContext(for: snapshot.id),
            expectedNavigation
        )
    }

    func testRendersMinimumAndDefaultWindowLayoutsOffscreen() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/content-layout-\(UUID().uuidString)",
            isDirectory: true
        )
        let cacheURL = container.appendingPathComponent("project-snapshots.json")
        let reviewCacheURL = container.appendingPathComponent(
            "review-content",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        let snapshot = makeProjectSnapshot()
        let writer = ProjectSnapshotStore(fileURL: cacheURL)
        try await writer.save(
            projectIDs: [snapshot.id],
            snapshots: [snapshot],
            eventID: 0,
            completeProjectIDs: [snapshot.id]
        )
        let selectedSnapshot = snapshot.worktrees[0]
        let selectedChange = try XCTUnwrap(selectedSnapshot.status.changes.first)
        let reviewStore = ReviewContentStore(directoryURL: reviewCacheURL)
        let diffOptions = GitDiffOptions(context: .lines(3), ignoresWhitespace: false)
        try await reviewStore.savePendingDiffs(
            [
                makeCachedDiff(
                    change: selectedChange,
                    scope: .working,
                    oldValue: "working before",
                    newValue: "working after"
                ),
                makeCachedDiff(
                    change: selectedChange,
                    scope: .staged,
                    oldValue: "staged before",
                    newValue: "staged after"
                )
            ],
            for: PendingReviewContentCacheKey(
                snapshot: selectedSnapshot,
                options: diffOptions
            )
        )
        let selectedHeadOID = try XCTUnwrap(selectedSnapshot.worktree.headOID)
        try await reviewStore.saveHistoryPage(
            GitHistoryPage(commits: [], nextOffset: 0, hasMore: false),
            for: HistoryReviewContentCacheKey(
                worktreeID: selectedSnapshot.id,
                revision: selectedHeadOID,
                pageSize: StartupReviewContent.historyPageSize
            )
        )
        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([snapshot.id], forKey: "agentgit.project-paths")
        defaults.set(1, forKey: "agentgit.project-identity-version")
        defaults.set(snapshot.worktrees[0].id, forKey: "agentgit.selected-worktree-id")
        defaults.set(snapshot.id, forKey: "agentgit.selected-worktree-project-id")
        let model = AppModel(
            defaults: defaults,
            snapshotStore: ProjectSnapshotStore(fileURL: cacheURL),
            reviewContentStore: ReviewContentStore(directoryURL: reviewCacheURL)
        )
        XCTAssertNil(snapshot.worktrees[0].refreshedAt)
        XCTAssertFalse(model.isRefreshing(worktreeID: snapshot.worktrees[0].id))
        model.setApplicationActive(false)
        XCTAssertFalse(model.isRefreshing(worktreeID: snapshot.worktrees[0].id))

        try await render(
            ContentView().environment(model),
            size: NSSize(
                width: AgentGitWindowMetrics.minimumWidth,
                height: AgentGitWindowMetrics.minimumHeight
            ),
            fileName: "AgentGitContent-minimum.png",
            requiresPendingActions: false
        )
        try await render(
            ContentView().environment(model),
            size: NSSize(
                width: AgentGitWindowMetrics.minimumWidth,
                height: AgentGitWindowMetrics.minimumHeight
            ),
            fileName: "AgentGitContent-minimum-dark.png",
            appearanceName: .darkAqua,
            requiresPendingActions: false
        )
        try await render(
            ContentView().environment(model),
            size: NSSize(
                width: AgentGitWindowMetrics.minimumWidth,
                height: AgentGitWindowMetrics.minimumHeight
            ),
            fileName: "AgentGitContent-minimum-high-contrast.png",
            appearanceName: .accessibilityHighContrastAqua,
            requiresPendingActions: false
        )
        try await render(
            ContentView().environment(model),
            size: NSSize(
                width: AgentGitWindowMetrics.defaultWidth,
                height: AgentGitWindowMetrics.defaultHeight
            ),
            fileName: "AgentGitContent-default.png",
            requiresPendingActions: false
        )
        try await render(
            ContentView().environment(model),
            size: NSSize(
                width: AgentGitWindowMetrics.defaultWidth,
                height: AgentGitWindowMetrics.defaultHeight
            ),
            fileName: "AgentGitContent-default-dark.png",
            appearanceName: .darkAqua,
            requiresPendingActions: false
        )
        try await render(
            SidebarNoResultsView(query: "missing-worktree", clearFilter: {}),
            size: NSSize(width: 240, height: 400),
            fileName: "AgentGitSidebar-no-results.png",
            requiresPendingActions: false
        )
        try await render(
            SidebarNoResultsView(query: "missing-worktree", clearFilter: {}),
            size: NSSize(width: 240, height: 400),
            fileName: "AgentGitSidebar-no-results-dark.png",
            appearanceName: .darkAqua,
            requiresPendingActions: false
        )
        try await render(
            WorktreeSwitcherView().environment(model),
            size: NSSize(width: 560, height: 440),
            fileName: "AgentGitWorktree-switcher.png",
            requiresPendingActions: false
        )
        try await render(
            WorktreeSwitcherView().environment(model),
            size: NSSize(width: 560, height: 440),
            fileName: "AgentGitWorktree-switcher-dark.png",
            appearanceName: .darkAqua,
            requiresPendingActions: false
        )
        try await render(
            WorktreeSwitcherView(initialQuery: "missing-worktree")
                .environment(model),
            size: NSSize(width: 560, height: 440),
            fileName: "AgentGitWorktree-switcher-empty.png",
            requiresPendingActions: false
        )

        let activePendingModel = AppModel(
            defaults: defaults,
            snapshotStore: ProjectSnapshotStore(fileURL: cacheURL),
            reviewContentStore: ReviewContentStore(directoryURL: reviewCacheURL)
        )
        let workingFileID = IntegratedFileID.pending(
            scope: .working,
            changeID: selectedChange.id
        ).stackID
        let stagedFileID = IntegratedFileID.pending(
            scope: .staged,
            changeID: selectedChange.id
        ).stackID
        activePendingModel.reviewStates.save(
            ReviewState(
                collapsedFileIDs: [stagedFileID],
                knownFileIDs: [workingFileID, stagedFileID],
                expandedNavigatorFolderIDs: [
                    "navigator-folder:working:Sources/Feature0",
                    "navigator-folder:staged:Sources/Feature0"
                ]
            ),
            for: ReviewStateKey(
                worktreeID: selectedSnapshot.id,
                context: .pending
            )
        )
        try await render(
            WorktreeReviewView(snapshot: selectedSnapshot)
                .environment(activePendingModel),
            size: NSSize(width: 1_200, height: 680),
            fileName: "AgentGitContent-pending-active.png",
            requiresPendingActions: false,
            expectedButtonTitles: ["Stage", "Discard"]
        )
        try await render(
            WorktreeReviewView(snapshot: selectedSnapshot)
                .environment(activePendingModel),
            size: NSSize(width: 1_200, height: 680),
            fileName: "AgentGitContent-pending-active-dark.png",
            appearanceName: .darkAqua,
            requiresPendingActions: false,
            expectedButtonTitles: ["Stage", "Discard"]
        )
        activePendingModel.reviewStates.saveLastContext(
            .pending,
            selectedCommitIDs: [],
            pane: .files,
            for: selectedSnapshot.id
        )
        activePendingModel.reviewStates.flush()
        try await render(
            WorktreeReviewView(snapshot: selectedSnapshot)
                .environment(activePendingModel),
            size: NSSize(width: 1_200, height: 680),
            fileName: "AgentGitContent-pending-files.png",
            requiresPendingActions: false,
            expectedButtonTitles: ["Stage", "Discard"]
        )
        activePendingModel.setApplicationActive(false)

        let commitOID = selectedHeadOID
        let parentOID = String(repeating: "a", count: 40)
        let commit = GitCommit(
            oid: commitOID,
            shortOID: String(commitOID.prefix(7)),
            authorName: "AgentGit Tests",
            authoredAt: Date(timeIntervalSince1970: 100),
            parentOIDs: [parentOID],
            refNames: ["HEAD -> refs/heads/main"],
            subject: "Restored commit review"
        )
        try await reviewStore.saveHistoryPage(
            GitHistoryPage(
                commits: [commit],
                nextOffset: 1,
                hasMore: false
            ),
            for: HistoryReviewContentCacheKey(
                worktreeID: selectedSnapshot.id,
                revision: commitOID,
                pageSize: StartupReviewContent.historyPageSize
            )
        )
        let commitContext = ReviewContext.commit(commitOID)
        let detailsKey = try XCTUnwrap(
            HistoricalReviewDetailsCacheKey(
                worktreeID: selectedSnapshot.id,
                context: commitContext
            )
        )
        let restoredCommitMessage = """
        Restored commit review

        Cached historical review keeps the summary concise.

        The complete body remains available for detailed inspection.

        Paragraph spacing and long explanations are preserved.
        """
        try await reviewStore.saveHistoricalDetails(
            HistoricalReviewDetails(
                message: restoredCommitMessage,
                changes: [selectedChange],
                commitMetadata: GitCommitMetadata(
                    treeOID: String(repeating: "b", count: 40),
                    authorEmail: "agentgit-tests@example.invalid"
                )
            ),
            for: detailsKey
        )
        let historicalKey = try XCTUnwrap(
            HistoricalReviewDiffCacheKey(
                worktreeID: selectedSnapshot.id,
                context: commitContext,
                options: diffOptions
            )
        )
        try await reviewStore.saveHistoricalDiffs(
            [
                makeCachedDiff(
                    change: selectedChange,
                    scope: .staged,
                    oldValue: "historical before",
                    newValue: "historical after"
                )
            ],
            for: historicalKey
        )
        model.reviewStates.saveLastContext(
            commitContext,
            selectedCommitIDs: [commitOID],
            pane: .files,
            for: selectedSnapshot.id
        )
        model.reviewStates.flush()
        let restoredModel = AppModel(
            defaults: defaults,
            snapshotStore: ProjectSnapshotStore(fileURL: cacheURL),
            reviewContentStore: ReviewContentStore(directoryURL: reviewCacheURL)
        )
        let restoredNavigationState = restoredModel.reviewStates.lastContext(
            for: selectedSnapshot.id
        )
        XCTAssertEqual(restoredNavigationState.context, commitContext)
        XCTAssertEqual(restoredNavigationState.selectedCommitIDs, [commitOID])
        XCTAssertEqual(restoredNavigationState.pane, .files)
        let restoredStartupContent = try XCTUnwrap(
            restoredModel.startupReviewContent(for: selectedSnapshot)
        )
        XCTAssertEqual(restoredStartupContent.historyPage?.commits, [commit])
        XCTAssertNotNil(
            restoredHistorySelection(
                restoredNavigationState,
                commits: [commit]
            )
        )
        try await render(
            WorktreeReviewView(snapshot: selectedSnapshot)
                .environment(restoredModel),
            size: NSSize(width: 1_200, height: 680),
            fileName: "AgentGitContent-restored-commit.png",
            requiresPendingActions: false,
            expectedLabels: [restoredCommitMessage]
        )
        try await render(
            WorktreeReviewView(snapshot: selectedSnapshot)
                .environment(restoredModel),
            size: NSSize(width: 1_200, height: 680),
            fileName: "AgentGitContent-restored-commit-dark.png",
            appearanceName: .darkAqua,
            requiresPendingActions: false,
            expectedLabels: [restoredCommitMessage]
        )
        restoredModel.reviewStates.saveLastContext(
            commitContext,
            selectedCommitIDs: [commitOID],
            pane: .commits,
            for: selectedSnapshot.id
        )
        try await render(
            WorktreeReviewView(snapshot: selectedSnapshot)
                .environment(restoredModel),
            size: NSSize(width: 1_200, height: 680),
            fileName: "AgentGitContent-restored-commit-history.png",
            requiresPendingActions: false,
            expectedLabels: [restoredCommitMessage]
        )
        restoredModel.setApplicationActive(false)
    }

    func testRendersCompactWorktreeWarningRowOffscreen() throws {
        let current = makeProjectSnapshot().worktrees[0]
        let warning = GitWorktreeSnapshot(
            worktree: current.worktree,
            status: current.status,
            diffStat: current.diffStat,
            lastActivityAt: current.lastActivityAt,
            refreshedAt: current.refreshedAt,
            errorMessage: "Ahead/behind: Upstream origin/feature-0 is unavailable.",
            hasUsableState: true,
            eventWatchURLs: current.eventWatchURLs
        )
        let hostingView = NSHostingView(
            rootView: WorktreeRow(snapshot: warning)
            .padding(.horizontal, 8)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 280, height: 52)
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        XCTAssertLessThanOrEqual(hostingView.fittingSize.height, 52)
        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000)
        let output = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/verification/AgentGitWorktreeWarning.png"
        )
        try png.write(to: output)
    }

    func testRendersApprovedSidebarComponentsOffscreen() async throws {
        let snapshot = makeProjectSnapshot()
        let selected = snapshot.worktrees[0]
        let dirty = snapshot.worktrees[1]
        let cleanSource = snapshot.worktrees[2]
        let clean = GitWorktreeSnapshot(
            worktree: cleanSource.worktree,
            status: GitStatusSnapshot(
                changes: [],
                branch: cleanSource.status.branch,
                headOID: cleanSource.status.headOID,
                branchHead: cleanSource.status.branchHead
            ),
            diffStat: GitDiffStat(addedLineCount: 0, deletedLineCount: 0),
            lastActivityAt: cleanSource.lastActivityAt,
            refreshedAt: cleanSource.refreshedAt,
            errorMessage: nil,
            eventWatchURLs: cleanSource.eventWatchURLs
        )
        let projectState = ProjectState(
            project: snapshot.project,
            snapshot: snapshot
        )
        let components = VStack(spacing: 0) {
            SidebarHeader(
                refreshDisabled: false,
                refresh: {},
                addProject: {}
            )
            SidebarSearchField(text: .constant(""))
            VStack(spacing: 0) {
                ProjectHeader(
                    projectState: projectState,
                    isCollapsed: false,
                    showsDivider: false,
                    toggle: {}
                )
                .padding(.horizontal, 7)
                WorktreeRow(snapshot: selected, isSelected: true)
                    .padding(.horizontal, 7)
                WorktreeRow(snapshot: dirty)
                    .padding(.horizontal, 7)
                WorktreeRow(snapshot: clean)
                    .padding(.horizontal, 7)
                ProjectHeader(
                    projectState: projectState,
                    isCollapsed: true,
                    showsDivider: true,
                    toggle: {}
                )
                .padding(.horizontal, 7)
            }
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: AgentGitPalette.sidebarBackground))

        try await render(
            components,
            size: NSSize(width: 360, height: 280),
            fileName: "AgentGitSidebar-components.png",
            requiresPendingActions: false
        )
        try await render(
            components,
            size: NSSize(width: 360, height: 280),
            fileName: "AgentGitSidebar-components-dark.png",
            appearanceName: .darkAqua,
            requiresPendingActions: false
        )
    }

    func testNavigationSidebarAppliesDesignWidthOffscreen() async throws {
        let widthRecorder = SidebarWidthRecorder()
        let content = NavigationSplitView {
            SidebarWidthProbe { widthRecorder.width = $0 }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: AgentGitPalette.sidebarBackground))
                .navigationSplitViewColumnWidth(
                    min: SidebarLayoutMetrics.navigationContentWidth,
                    ideal: SidebarLayoutMetrics.navigationContentWidth,
                    max: SidebarLayoutMetrics.navigationContentWidth
                )
        } detail: {
            Color(nsColor: AgentGitPalette.canvas)
        }
        .navigationSplitViewStyle(.balanced)

        let size = NSSize(width: 1_000, height: 600)
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = OffscreenRenderWindow(
            contentRect: hostingView.frame,
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = hostingView
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            hostingView.layoutSubtreeIfNeeded()
            if let width = widthRecorder.width,
               abs(width - SidebarLayoutMetrics.navigationContentWidth) <= 1 {
                break
            }
        }

        XCTAssertEqual(
            try XCTUnwrap(widthRecorder.width),
            SidebarLayoutMetrics.navigationContentWidth,
            accuracy: 1
        )
        let splitSubviewWidths = descendants(of: hostingView)
            .compactMap { $0 as? NSSplitView }
            .flatMap(\.subviews)
            .map(\.frame.width)
        XCTAssertTrue(
            splitSubviewWidths.contains {
                abs($0 - SidebarLayoutMetrics.visibleWidth) <= 1
            },
            "Expected a 360pt visible sidebar, got \(splitSubviewWidths)"
        )
    }

    func testRendersSidebarWindowChromeOffscreen() async throws {
        try await renderSidebarWindowChrome(
            appearanceName: .aqua,
            fileName: "AgentGitSidebar-window-chrome.png"
        )
        try await renderSidebarWindowChrome(
            appearanceName: .darkAqua,
            fileName: "AgentGitSidebar-window-chrome-dark.png"
        )
    }

    private func renderSidebarWindowChrome(
        appearanceName: NSAppearance.Name,
        fileName: String
    ) async throws {
        let content = SidebarWindowChromeHarness()

        let contentSize = NSSize(width: 360, height: 280)
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(origin: .zero, size: contentSize)
        let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
        hostingView.appearance = appearance
        let window = OffscreenRenderWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = hostingView
        window.setContentSize(contentSize)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        try await Task.sleep(for: .milliseconds(100))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        let frameView = try XCTUnwrap(hostingView.superview)
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        let bitmap = try XCTUnwrap(
            frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
        )
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000)
        let closeButton = try XCTUnwrap(window.standardWindowButton(.closeButton))
        XCTAssertNotNil(window.standardWindowButton(.miniaturizeButton))
        XCTAssertNotNil(window.standardWindowButton(.zoomButton))
        let headerView = try XCTUnwrap(
            descendants(of: frameView).first {
                $0.identifier == SidebarLayoutMetrics.headerIdentifier
            }
        )
        let headerFrame = frameView.convert(headerView.bounds, from: headerView)
        let closeButtonFrame = frameView.convert(
            closeButton.bounds,
            from: closeButton
        )
        XCTAssertEqual(
            headerFrame.width,
            SidebarLayoutMetrics.visibleWidth,
            accuracy: 1
        )
        XCTAssertEqual(
            headerFrame.height,
            SidebarLayoutMetrics.headerHeight,
            accuracy: 1
        )
        XCTAssertTrue(
            headerFrame.contains(
                NSPoint(x: closeButtonFrame.midX, y: closeButtonFrame.midY)
            )
        )
        let output = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(".build/verification/\(fileName)")
        try png.write(to: output)
    }

    private func render(
        _ content: some View,
        size: NSSize,
        fileName: String,
        appearanceName: NSAppearance.Name = .aqua,
        settleDuration: Duration = .seconds(2),
        requiresPendingActions: Bool = true,
        expectsEnabledPendingActions: Bool = false,
        expectedLabels: Set<String> = [],
        expectedButtonTitles: Set<String> = []
    ) async throws {
        let colorScheme: ColorScheme = appearanceName == .darkAqua
            ? .dark
            : .light
        let hostingView = NSHostingView(
            rootView: AnyView(content.environment(\.colorScheme, colorScheme))
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
        hostingView.appearance = appearance
        hostingView.wantsLayer = true
        var backgroundColor = NSColor.windowBackgroundColor.cgColor
        appearance.performAsCurrentDrawingAppearance {
            backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        hostingView.layer?.backgroundColor = backgroundColor
        let window = OffscreenRenderWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        appearance.performAsCurrentDrawingAppearance {
            window.backgroundColor = NSColor.windowBackgroundColor
        }
        window.contentView = hostingView
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        hostingView.frame = NSRect(origin: .zero, size: size)
        let settleDeadline = ContinuousClock.now.advanced(by: settleDuration)
        var labels: [String] = []
        repeat {
            try await Task.sleep(for: .milliseconds(50))
            window.setContentSize(size)
            hostingView.frame = NSRect(origin: .zero, size: size)
            hostingView.layoutSubtreeIfNeeded()
            hostingView.displayIfNeeded()
            labels = descendants(of: hostingView).compactMap {
                ($0 as? NSTextField)?.stringValue
            }
            let isLoading = labels.contains(where: {
                $0.hasPrefix("Loading diff")
                    || $0.hasPrefix("Waiting for repository update")
            })
            let hasExpectedLabels = expectedLabels.allSatisfy(labels.contains)
            if !isLoading && hasExpectedLabels {
                break
            }
        } while ContinuousClock.now < settleDeadline
        XCTAssertEqual(hostingView.bounds.size.width, size.width, accuracy: 0.5)
        XCTAssertEqual(hostingView.bounds.size.height, size.height, accuracy: 0.5)
        XCTAssertFalse(
            labels.contains(where: { $0.hasPrefix("Loading diff") }),
            "\(fileName) still shows Loading diff after settling"
        )
        XCTAssertFalse(labels.contains(where: {
            $0.hasPrefix("Waiting for repository update")
        }), "\(fileName) still waits for a repository update after settling")
        for expectedLabel in expectedLabels {
            XCTAssertTrue(
                labels.contains(expectedLabel),
                "Missing expected label: \(expectedLabel). Available: \(labels)"
            )
        }
        let visibleButtons = descendants(of: hostingView).compactMap {
            $0 as? NSButton
        }.filter { button in
            guard !button.isHidden,
                  button.alphaValue > 0,
                  button.bounds.width > 0,
                  button.bounds.height > 0 else {
                return false
            }
            let frame = hostingView.convert(button.bounds, from: button)
            return frame.intersects(hostingView.bounds)
        }
        for expectedTitle in expectedButtonTitles {
            XCTAssertTrue(
                visibleButtons.contains(where: {
                    $0.title == expectedTitle && $0.isEnabled
                }),
                "Missing enabled button: \(expectedTitle)"
            )
        }
        let actionTitles: Set<String> = [
            "Stage", "Discard", "Unstage",
            "Stage Hunk", "Unstage Hunk"
        ]
        let actionButtons = visibleButtons.filter {
            actionTitles.contains($0.title) && !$0.isHidden
        }
        if requiresPendingActions {
            XCTAssertTrue(actionButtons.contains(where: { $0.title == "Stage" }))
            XCTAssertTrue(actionButtons.contains(where: { $0.title == "Unstage" }))
        }
        if expectsEnabledPendingActions {
            for title in ["Stage", "Unstage", "Discard"] {
                XCTAssertTrue(
                    actionButtons.contains(where: {
                        $0.title == title && $0.isEnabled
                    }),
                    "Expected an enabled \(title) action"
                )
            }
        }
        for button in actionButtons {
            let frame = hostingView.convert(button.bounds, from: button)
            XCTAssertGreaterThanOrEqual(
                frame.minX,
                hostingView.bounds.minX - 0.5,
                "\(button.title) extends past the leading window edge"
            )
            XCTAssertLessThanOrEqual(
                frame.maxX,
                hostingView.bounds.maxX + 0.5,
                "\(button.title) extends past the trailing window edge"
            )
        }
        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000)
        let output = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(".build/verification/\(fileName)")
        try png.write(to: output)
    }

    private func makeProjectSnapshot() -> GitProjectSnapshot {
        let project = GitProject(rootURL: URL(fileURLWithPath: "/projects/agentgit"))
        let worktrees = (0..<5).map { index -> GitWorktreeSnapshot in
            let rootURL = index == 0
                ? project.rootURL
                : URL(fileURLWithPath: "/worktrees/feature-\(index)")
            let worktree = GitWorktree(
                rootURL: rootURL,
                headOID: String(repeating: String(index + 1), count: 40),
                branchRef: index == 0
                    ? "refs/heads/main"
                    : "refs/heads/feature/long-branch-name-\(index)",
                isBare: false,
                isDetached: false,
                lockedReason: nil,
                prunableReason: nil
            )
            let change = GitFileChange(
                path: "Sources/Feature\(index)/LongChangedFileName.swift",
                originalPath: nil,
                indexStatus: index.isMultiple(of: 2) ? "M" : ".",
                worktreeStatus: "M",
                kind: .ordinary
            )
            return GitWorktreeSnapshot(
                worktree: worktree,
                status: GitStatusSnapshot(
                    changes: [change],
                    branch: GitBranchStatus(
                        upstreamRef: "origin/feature-\(index)",
                        aheadCount: index,
                        behindCount: max(0, 4 - index)
                    ),
                    headOID: worktree.headOID,
                    branchHead: worktree.branchName
                ),
                diffStat: GitDiffStat(
                    addedLineCount: 100 + index,
                    deletedLineCount: 20 + index
                ),
                lastActivityAt: Date().addingTimeInterval(TimeInterval(-index * 3_600)),
                errorMessage: nil,
                eventWatchURLs: [rootURL]
            )
        }
        return GitProjectSnapshot(
            project: project,
            worktrees: worktrees,
            refreshedAt: Date()
        )
    }

    private func makeCachedDiff(
        change: GitFileChange,
        scope: GitDiffScope,
        oldValue: String,
        newValue: String
    ) -> GitFileDiff {
        GitFileDiff(
            change: change,
            scope: scope,
            hunks: [
                GitDiffHunk(
                    id: 0,
                    header: "@@ -1 +1 @@ cachedState",
                    sectionHeading: "cachedState",
                    oldStart: 1,
                    oldCount: 1,
                    newStart: 1,
                    newCount: 1,
                    lines: [
                        GitDiffLine(
                            id: 0,
                            kind: .deletion,
                            oldLineNumber: 1,
                            newLineNumber: nil,
                            content: oldValue
                        ),
                        GitDiffLine(
                            id: 1,
                            kind: .addition,
                            oldLineNumber: nil,
                            newLineNumber: 1,
                            content: newValue
                        )
                    ]
                )
            ],
            state: .textual
        )
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}

private final class OffscreenRenderWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private struct SidebarWindowChromeHarness: View {
    @State private var titlebarInset: CGFloat = 32

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(
                    height: max(
                        0,
                        SidebarLayoutMetrics.headerHeight - titlebarInset
                    )
                )
            SidebarSearchField(text: .constant(""))
            Spacer()
        }
        .background(Color(nsColor: AgentGitPalette.sidebarBackground))
        .background(
            WindowTitleVisibilityConfigurator(
                titlebarInset: $titlebarInset,
                refreshDisabled: false,
                refresh: {},
                addProject: {}
            )
        )
    }
}

@MainActor
private final class SidebarWidthRecorder {
    var width: CGFloat?
}

private struct SidebarWidthProbe: NSViewRepresentable {
    let widthDidChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> SidebarWidthProbeView {
        SidebarWidthProbeView(widthDidChange: widthDidChange)
    }

    func updateNSView(_ nsView: SidebarWidthProbeView, context: Context) {
        nsView.widthDidChange = widthDidChange
        nsView.reportWidth()
    }
}

private final class SidebarWidthProbeView: NSView {
    var widthDidChange: (CGFloat) -> Void

    init(widthDidChange: @escaping (CGFloat) -> Void) {
        self.widthDidChange = widthDidChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        reportWidth()
    }

    func reportWidth() {
        widthDidChange(bounds.width)
    }
}
