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
    }

    func testSidebarOnlyWorktreeSelectionsChangeCurrentReview() {
        let current = "/worktrees/current"
        XCTAssertNotEqual(
            SidebarSelection.worktree(current),
            SidebarSelection.project(current)
        )
        XCTAssertNotEqual(
            SidebarSelection.worktree(current),
            SidebarSelection.worktreeDisclosure(current)
        )
        XCTAssertEqual(
            acceptedSidebarWorktreeSelection(
                current: current,
                requested: nil
            ),
            current
        )
        XCTAssertEqual(
            acceptedSidebarWorktreeSelection(
                current: current,
                requested: .worktree("/worktrees/next")
            ),
            "/worktrees/next"
        )
        XCTAssertEqual(
            acceptedSidebarWorktreeSelection(
                current: current,
                requested: .project(current)
            ),
            current
        )
        XCTAssertEqual(
            acceptedSidebarWorktreeSelection(
                current: current,
                requested: .worktreeDisclosure(current)
            ),
            current
        )
        XCTAssertNil(
            acceptedSidebarWorktreeSelection(
                current: nil,
                requested: nil
            )
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
            size: NSSize(width: 1_200, height: 680),
            fileName: "AgentGitContent-minimum.png"
        )
        try await render(
            ContentView().environment(model),
            size: NSSize(width: 1_440, height: 840),
            fileName: "AgentGitContent-default.png"
        )
        try await render(
            ContentView().environment(model),
            size: NSSize(width: 1_440, height: 840),
            fileName: "AgentGitContent-default-dark.png",
            appearanceName: .darkAqua
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
        try await render(
            WorktreeReviewView(snapshot: selectedSnapshot)
                .environment(activePendingModel),
            size: NSSize(width: 1_200, height: 680),
            fileName: "AgentGitContent-pending-active.png",
            expectsEnabledPendingActions: true,
            expectedLabels: ["Pending Changes"]
        )
        try await render(
            WorktreeReviewView(snapshot: selectedSnapshot)
                .environment(activePendingModel),
            size: NSSize(width: 1_200, height: 680),
            fileName: "AgentGitContent-pending-active-dark.png",
            appearanceName: .darkAqua,
            expectsEnabledPendingActions: true,
            expectedLabels: ["Pending Changes"]
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
            expectsEnabledPendingActions: true,
            expectedLabels: ["Pending Changes"]
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
        try await reviewStore.saveHistoricalDetails(
            HistoricalReviewDetails(
                message: "Restored commit review\n\nCached historical review",
                changes: [selectedChange]
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
            expectedLabels: ["Restored commit review"]
        )
        try await render(
            WorktreeReviewView(snapshot: selectedSnapshot)
                .environment(restoredModel),
            size: NSSize(width: 1_200, height: 680),
            fileName: "AgentGitContent-restored-commit-dark.png",
            appearanceName: .darkAqua,
            requiresPendingActions: false,
            expectedLabels: ["Restored commit review"]
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
        }.filter { !$0.isHidden }
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
