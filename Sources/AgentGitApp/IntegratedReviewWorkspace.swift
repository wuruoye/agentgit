import AgentGitCore
import AppKit
import SwiftUI

struct IntegratedReviewWorkspace: View {
    @Environment(AppModel.self) private var model

    private static let historyPageSize = StartupReviewContent.historyPageSize
    private static let historySearchPageSize = 100
    private static let visualStudioCodeURL = visualStudioCodeApplicationURL()

    let snapshot: GitWorktreeSnapshot
    let initialContext: ReviewContext
    let initialSelectedCommitIDs: Set<GitCommit.ID>
    let initialPane: ReviewPane
    let initialHistoryFilter: String
    private let snapshotWorkingItems: [IntegratedFileItem]
    private let snapshotUntrackedItems: [IntegratedFileItem]
    private let snapshotStagedItems: [IntegratedFileItem]

    @State private var commits: [GitCommit] = []
    @State private var commitGraphLayout = CommitGraphLayout(commits: [])
    @State private var selection: Set<IntegratedOverviewSelection> = [.pending]
    @State private var contextChanges: [GitFileChange] = []
    @State private var contextMessage = ""
    @State private var diffsByFileID: [IntegratedFileID: GitFileDiff] = [:]
    @State private var imageDiffsByFileID: [IntegratedFileID: GitImageDiff] = [:]
    @State private var wholeFileDiffsByFileID: [IntegratedFileID: GitFileDiff] = [:]
    @State private var loadingWholeFileIDs: Set<String> = []
    @State private var expandedContextDiffsByFileID: [IntegratedFileID: GitFileDiff] = [:]
    @State private var expandedContextLineCountByFileID: [IntegratedFileID: Int] = [:]
    @State private var loadingContextGapIDs: Set<String> = []
    @State private var existingWorkingFileIDs: Set<String> = []
    @State private var supplementalDiffFailures: [
        IntegratedFileID: SupplementalDiffFailure
    ] = [:]
    @State private var pane: ReviewPane = .commits
    @State private var selectedReviewDocument: ReviewDocumentSelection = .summary
    @State private var openReviewFileIDs: [String] = []
    @State private var review = ReviewState()
    @State private var navigatorSelection: NavigatorSelection?
    @State private var navigatorTreeCache = NavigatorTreeCache()
    @State private var commitFilterText = ""
    @State private var historyError: String?
    @State private var historyPaginationError: String?
    @State private var loadedHistoryKey: HistoryLoadKey?
    @State private var completedHistoryKey: HistoryLoadKey?
    @State private var historyNextOffset = 0
    @State private var hasMoreHistory = false
    @State private var searchedCommits: [GitCommit] = []
    @State private var loadedHistorySearchKey: HistorySearchLoadKey?
    @State private var completedHistorySearchKey: HistorySearchLoadKey?
    @State private var historySearchNextOffset = 0
    @State private var hasMoreHistorySearchResults = false
    @State private var historySearchError: String?
    @State private var historySearchPaginationError: String?
    @State private var historySearchPageCache = HistorySearchPageCache()
    @State private var contextDetailError: String?
    @State private var diffError: String?
    @State private var mutationError: String?
    @State private var isLoadingHistory = false
    @State private var isLoadingMoreHistory = false
    @State private var isSearchingHistory = false
    @State private var isLoadingMoreHistorySearchResults = false
    @State private var isLoadingContextDetail = false
    @State private var isLoadingDiffs = false
    @State private var isApplyingMutation = false
    @State private var mutationSequence: UInt64 = 0
    @State private var runningRemoteAction: GitRemoteAction?
    @State private var remoteOperationFeedback: RemoteOperationFeedback?
    @State private var isCancellingRemoteOperation = false
    @State private var remoteOperationTask: Task<Void, Never>?
    @State private var remoteOperationSequence: UInt64 = 0
    @State private var remoteFeedbackDismissTask: Task<Void, Never>?
    @State private var remoteOperationError: String?
    @State private var restoredBaseDiffLoadKey: IntegratedDiffLoadKey?
    @State private var completedDiffLoadKey: IntegratedDiffLoadKey?
    @State private var requestedRestoredContext: ReviewNavigationState?
    @State private var requestedHistoryScrollCommitID: GitCommit.ID? = nil
    @State private var navigationHistory = ReviewNavigationHistory()
    @State private var suppressedHistoryFilterValue: String?
    @State private var fileFocusedFromDiffID: String?
    @State private var navigationPaneWidth: CGFloat = 240
    @State private var navigationPaneDragStartWidth: CGFloat?
    @State private var diffCommandSequence: UInt64 = 0
    @State private var diffCommand: DiffStackCommand?
    @FocusState private var isFilterFocused: Bool
    @FocusState private var isFilesNavigatorFocused: Bool

    init(
        snapshot: GitWorktreeSnapshot,
        startupContent: StartupReviewContent? = nil,
        initialContext: ReviewContext = .pending,
        initialSelectedCommitIDs: Set<GitCommit.ID> = [],
        initialPane: ReviewPane = .commits,
        initialHistoryFilter: String = "",
        initialReviewState: ReviewState = ReviewState()
    ) {
        self.snapshot = snapshot
        self.initialContext = initialContext
        self.initialSelectedCommitIDs = initialSelectedCommitIDs
        self.initialPane = initialPane
        self.initialHistoryFilter = initialHistoryFilter
        let pendingItems = pendingIntegratedFileItems(in: snapshot)
        snapshotWorkingItems = pendingItems.working
        snapshotUntrackedItems = pendingItems.untracked
        snapshotStagedItems = pendingItems.staged
        _review = State(initialValue: initialReviewState)
        _navigatorSelection = State(
            initialValue: initialReviewState.focusedFileID.map(
                NavigatorSelection.file
            )
        )
        _pane = State(initialValue: initialPane)
        _commitFilterText = State(initialValue: initialHistoryFilter)
        _selection = State(
            initialValue: unresolvedOverviewSelection(
                context: initialContext,
                selectedCommitIDs: initialSelectedCommitIDs
            )
        )
        _requestedRestoredContext = State(
            initialValue: initialContext == .pending
                ? nil
                : ReviewNavigationState(
                    context: initialContext,
                    selectedCommitIDs: initialSelectedCommitIDs,
                    pane: initialPane,
                    historyFilter: initialHistoryFilter
                )
        )
        guard let startupContent,
              startupContent.matches(
                  snapshot: snapshot,
                  options: startupContent.pendingKey.options
              ) else {
            return
        }

        if let page = startupContent.historyPage {
            let key = HistoryLoadKey(
                worktreeID: snapshot.id,
                revision: snapshot.worktree.headOID
            )
            let navigationState = ReviewNavigationState(
                context: initialContext,
                selectedCommitIDs: initialSelectedCommitIDs,
                pane: initialPane,
                historyFilter: initialHistoryFilter
            )
            _commits = State(initialValue: page.commits)
            _commitGraphLayout = State(
                initialValue: CommitGraphLayout(commits: page.commits)
            )
            _loadedHistoryKey = State(initialValue: key)
            _completedHistoryKey = State(initialValue: key)
            _historyNextOffset = State(initialValue: page.nextOffset)
            _hasMoreHistory = State(initialValue: page.hasMore)
            if GitHistorySearchQuery(initialHistoryFilter) == nil,
               let restoredSelection = restoredHistorySelection(
                navigationState,
                commits: page.commits
            ) {
                _selection = State(initialValue: restoredSelection)
                _requestedRestoredContext = State(initialValue: nil)
                _requestedHistoryScrollCommitID = State(
                    initialValue: historyScrollTargetID(
                        selection: restoredSelection,
                        commits: page.commits
                    )
                )
            }
        }

        if let cachedDiffs = startupContent.pendingDiffs {
            let items = snapshotWorkingItems
                + snapshotUntrackedItems
                + snapshotStagedItems
            let restored = integratedDiffCache(
                diffs: cachedDiffs,
                items: items
            )
            if !restored.isEmpty || items.isEmpty {
                let key = IntegratedDiffLoadKey(
                    worktreeID: snapshot.id,
                    activityDate: snapshot.lastActivityAt,
                    context: .pending,
                    options: startupContent.pendingKey.options,
                    fileIDs: items.map(\.id)
                )
                _diffsByFileID = State(initialValue: restored)
                let expectedIDs = Set(items.map(\.id))
                if startupContent.pendingDiffsAreComplete,
                   Set(restored.keys) == expectedIDs {
                    _restoredBaseDiffLoadKey = State(initialValue: key)
                } else {
                    _isLoadingDiffs = State(initialValue: true)
                }
            }
        }

        if startupContent.historicalContext == initialContext,
           let historicalDetails = startupContent.historicalDetails {
            _contextMessage = State(initialValue: historicalDetails.message)
            _contextChanges = State(initialValue: historicalDetails.changes)
            if let cachedDiffs = startupContent.historicalDiffs {
                let contextID = Self.identifier(for: initialContext)
                let items = historicalDetails.changes.map { change in
                    IntegratedFileItem(
                        id: .context(
                            contextID: contextID,
                            changeID: change.id
                        ),
                        change: change,
                        scope: .staged
                    )
                }
                let restored = integratedDiffCache(
                    diffs: cachedDiffs,
                    items: items
                )
                let key = IntegratedDiffLoadKey(
                    worktreeID: snapshot.id,
                    activityDate: snapshot.lastActivityAt,
                    context: initialContext,
                    options: startupContent.pendingKey.options,
                    fileIDs: items.map(\.id)
                )
                _diffsByFileID = State(initialValue: restored)
                let expectedIDs = Set(items.map(\.id))
                if startupContent.historicalDiffsAreComplete,
                   Set(restored.keys) == expectedIDs {
                    _restoredBaseDiffLoadKey = State(initialValue: key)
                } else {
                    _isLoadingDiffs = State(initialValue: true)
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
            if let remoteOperationError {
                Divider()
                remoteOperationErrorBar(remoteOperationError)
            }
            if let blockingGitRefreshError {
                Divider()
                blockingGitRefreshErrorBar(blockingGitRefreshError)
            }
            if let statusError = snapshot.errorMessage,
               snapshot.hasUsableState,
               mutationError == nil {
                Divider()
                statusRefreshErrorBar(statusError)
            }
            Divider()

            if let statusError = snapshot.errorMessage,
               !snapshot.hasUsableState {
                ContentUnavailableView {
                    Label("Unable to Read Status", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(statusError)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                workspaceSplitView
            }
        }
        .onChange(of: snapshot.id) {
            resetWorkspace()
        }
        .onChange(of: stateKey) { previousKey, newKey in
            model.reviewStates.save(review, for: previousKey)
            model.reviewStates.saveLastContext(
                newKey.context,
                selectedCommitIDs: selectedCommitIDSet,
                pane: pane,
                historyFilter: commitFilterText,
                for: newKey.worktreeID
            )
            review = model.reviewStates.state(for: newKey)
            navigatorSelection = review.focusedFileID.map(NavigatorSelection.file)
            fileFocusedFromDiffID = nil
            contextChanges = []
            contextMessage = ""
            diffsByFileID = [:]
            restoredBaseDiffLoadKey = nil
            completedDiffLoadKey = nil
            imageDiffsByFileID = [:]
            wholeFileDiffsByFileID = [:]
            loadingWholeFileIDs = []
            expandedContextDiffsByFileID = [:]
            expandedContextLineCountByFileID = [:]
            loadingContextGapIDs = []
            existingWorkingFileIDs = []
            supplementalDiffFailures = [:]
            contextDetailError = nil
            diffError = nil
            mutationError = nil
            remoteOperationError = nil
            isLoadingContextDetail = false
            isLoadingDiffs = false
            selectedReviewDocument = .summary
            openReviewFileIDs = []
            diffCommand = nil
        }
        .onChange(of: reviewFileExpansionSyncKey, initial: true) { _, key in
            let changedFiles = synchronizeReviewFileExpansion(
                in: &review,
                fileIDs: key.fileIDs
            )
            let changedFolders = synchronizeNavigatorFolderExpansion(
                in: &review,
                validFolderIDs: currentNavigatorFolderIDs
            )
            guard changedFiles || changedFolders else {
                return
            }
            model.reviewStates.save(review, for: key.stateKey)
        }
        .onChange(of: review.filterText) {
            if let focused = review.focusedFileID,
               !visibleFileItems.contains(where: { $0.id.stackID == focused }) {
                focusFileFromNavigator(
                    visibleFileItems.first?.id.stackID,
                    expandsFile: false
                )
            }
        }
        .onChange(of: currentFileItems.map { $0.id.stackID }, initial: true) {
            synchronizeReviewDocuments()
        }
        .onChange(of: commitFilterText) { previousFilter, currentFilter in
            handleHistoryFilterChange(
                from: previousFilter,
                to: currentFilter
            )
        }
        .onChange(of: selection) { previous, current in
            let normalized = normalizedCommitEndpointSelection(
                normalizedOverviewSelection(
                    previous: previous,
                    current: current
                ),
                commits: displayedHistoryCommits
            )
            if normalized != current {
                selection = normalized
            }
        }
        .onChange(of: pane) { _, newPane in
            model.reviewStates.saveLastContext(
                activeContext,
                selectedCommitIDs: selectedCommitIDSet,
                pane: newPane,
                historyFilter: commitFilterText,
                for: snapshot.id
            )
        }
        .task(id: model.isApplicationActive ? historyLoadKey : nil) {
            guard model.isApplicationActive else {
                return
            }
            await loadHistory(for: historyLoadKey)
            await loadPagesForRequestedHistoryContext()
        }
        .task(id: model.isApplicationActive ? historySearchLoadKey : nil) {
            guard model.isApplicationActive else {
                return
            }
            await updateHistorySearch(for: historySearchLoadKey)
            await loadPagesForRequestedHistoryContext()
        }
        .task(id: model.isApplicationActive ? stateKey : nil) {
            guard model.isApplicationActive else {
                return
            }
            await loadContextDetails(for: stateKey)
        }
        .task(id: model.isApplicationActive ? diffLoadKey : nil) {
            guard model.isApplicationActive else {
                return
            }
            await loadDiffs()
        }
        .task(id: model.isApplicationActive ? workingFileAvailabilityKey : nil) {
            guard model.isApplicationActive else {
                return
            }
            await loadWorkingFileAvailability(for: workingFileAvailabilityKey)
        }
        .focusedSceneValue(
            \.reviewCommandActions,
            ReviewCommandActions(
                navigateBack: navigateBack,
                navigateForward: navigateForward,
                canNavigateBack: navigationHistory.canNavigateBack
                    && !isFilterFocused,
                canNavigateForward: navigationHistory.canNavigateForward
                    && !isFilterFocused,
                selectNext: { moveFileFocus(by: 1) },
                selectPrevious: { moveFileFocus(by: -1) },
                focusFilter: { isFilterFocused = true },
                showCommits: { pane = .commits },
                showFiles: { pane = .files },
                navigatorDefaultActionTitle: navigatorDefaultActionTitle,
                performNavigatorDefaultAction: performNavigatorDefaultAction,
                canDiscardFocusedFile: focusedFileDiscardCommand != nil,
                requestFocusedFileDiscard: requestFocusedFileDiscard
            )
        )
        .onChange(of: pane) { _, pane in
            guard pane == .files else {
                return
            }
            isFilesNavigatorFocused = true
        }
    }

    private var workspaceSplitView: some View {
        GeometryReader { proxy in
            let width = clampedReviewNavigationPaneWidth(
                navigationPaneWidth,
                totalWidth: proxy.size.width
            )
            HStack(spacing: 0) {
                navigationPane
                    .frame(width: width, height: proxy.size.height)
                    .clipped()
                reviewSplitDivider(
                    navigationWidth: width,
                    totalWidth: proxy.size.width
                )
                reviewPane
                    .frame(
                        width: max(0, proxy.size.width - width - 7),
                        height: proxy.size.height
                    )
                    .clipped()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func reviewSplitDivider(
        navigationWidth: CGFloat,
        totalWidth: CGFloat
    ) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 7)
            .overlay {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .onHover { isHovered in
                if isHovered {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if navigationPaneDragStartWidth == nil {
                            navigationPaneDragStartWidth = navigationWidth
                        }
                        navigationPaneWidth = clampedReviewNavigationPaneWidth(
                            (navigationPaneDragStartWidth ?? navigationWidth)
                                + value.translation.width,
                            totalWidth: totalWidth
                        )
                    }
                    .onEnded { _ in
                        navigationPaneDragStartWidth = nil
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Review Splitter")
            .accessibilityValue("\(Int(navigationWidth)) points")
            .accessibilityAdjustableAction { direction in
                let delta: CGFloat = switch direction {
                case .increment: 20
                case .decrement: -20
                @unknown default: 0
                }
                navigationPaneWidth = clampedReviewNavigationPaneWidth(
                    navigationWidth + delta,
                    totalWidth: totalWidth
                )
            }
            .help("Drag to resize the navigation and review panes")
    }

    // MARK: - Header

    private var workspaceHeader: some View {
        HStack(spacing: 16) {
            HStack(spacing: 2) {
                Button(action: navigateBack) {
                    Image(systemName: "chevron.left")
                        .frame(width: 18, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!navigationHistory.canNavigateBack)
                .help("Navigate Back (⌘←)")
                .accessibilityLabel("Navigate Back")

                Button(action: navigateForward) {
                    Image(systemName: "chevron.right")
                        .frame(width: 18, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!navigationHistory.canNavigateForward)
                .help("Navigate Forward (⌘→)")
                .accessibilityLabel("Navigate Forward")
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.worktree.displayName)
                    .font(.headline)
                Text(snapshot.worktree.rootURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            AgentSessionsButton(worktree: snapshot.worktree)

            if isRefreshingSnapshot {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Updating…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Updating repository status")
            }

            if let branch = snapshot.status.branch, !branch.isSynced {
                let description = branchTrackingDescription(branch) ?? ""
                HStack(spacing: 4) {
                    if branch.aheadCount > 0 {
                        Text("↑\(branch.aheadCount)")
                    }
                    if branch.behindCount > 0 {
                        Text("↓\(branch.behindCount)")
                    }
                }
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.blue)
                .help(description)
                .accessibilityLabel(description)
            }

            if let runningRemoteAction {
                ProgressView()
                    .controlSize(.small)
                    .help("\(runningRemoteAction.title) in progress")
                Button {
                    cancelRemoteOperation()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .labelStyle(.iconOnly)
                .disabled(isCancellingRemoteOperation)
                .help(
                    isCancellingRemoteOperation
                        ? "Cancelling \(runningRemoteAction.title)…"
                        : "Cancel \(runningRemoteAction.title)"
                )
            } else if let remoteOperationFeedback {
                RemoteOperationFeedbackView(feedback: remoteOperationFeedback)
            }
            Button {
                performRemoteAction(.pull)
            } label: {
                Label("Pull", systemImage: "arrow.down")
            }
            .disabled(!canRunRemoteOperation(.pull))
            .help(remoteActionHelp(.pull))

            Button {
                performRemoteAction(.push)
            } label: {
                Label(pushActionTitle, systemImage: "arrow.up")
            }
            .disabled(!canRunRemoteOperation(.push))
            .help(remoteActionHelp(.push))
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    // MARK: - Navigation

    private var navigationPane: some View {
        VStack(spacing: 0) {
            ReviewPaneTabBar(selection: $pane)

            Divider()

            IntegratedFilterField(
                placeholder: pane == .commits ? "Search history · author:name" : "Filter files",
                text: pane == .commits ? $commitFilterText : $review.filterText,
                isFocused: $isFilterFocused
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Divider()

            switch pane {
            case .commits: commitsList
            case .files: filesList
            }
        }
    }

    private var commitsList: some View {
        let graph = commitGraphLayout
        return ScrollViewReader { scrollProxy in
            List(selection: overviewSelectionBinding) {
                PendingOverviewRow(
                    workingCount: workingItems.count,
                    untrackedCount: untrackedItems.count,
                    stagedCount: stagedItems.count
                )
                .tag(IntegratedOverviewSelection.pending)

            Section(isHistorySearchActive ? "Search Results" : "History") {
                if isHistorySearchActive, isSearchingHistory, searchedCommits.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Searching history…")
                            .foregroundStyle(.secondary)
                    }
                } else if isHistorySearchActive, let historySearchError {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Unable to Search History", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Text(historySearchError)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                            .help(historySearchError)
                        Button("Retry") {
                            Task {
                                await updateHistorySearch(for: historySearchLoadKey, debounces: false)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                    .font(.caption)
                } else if !isHistorySearchActive, isLoadingHistory, commits.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading commits…")
                            .foregroundStyle(.secondary)
                    }
                } else if !isHistorySearchActive, let historyError {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Unable to Load History", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Text(historyError)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                            .help(historyError)
                        Button("Retry") {
                            Task {
                                await loadHistory(for: historyLoadKey)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                    .font(.caption)
                } else {
                    if visibleCommits.isEmpty {
                        if commitFilterText.isEmpty {
                            Text("No Commits Yet")
                                .foregroundStyle(.secondary)
                        } else {
                            NavigatorFilterEmptyState(
                                title: "No Matching Commits",
                                query: commitFilterText,
                                clearFilter: { commitFilterText = "" }
                            )
                        }
                    } else {
                        ForEach(visibleCommits) { commit in
                            IntegratedCommitRow(
                                commit: commit,
                                graphRow: isHistorySearchActive
                                    ? nil
                                    : graph.rowsByCommitID[commit.id],
                                graphLaneCount: isHistorySearchActive
                                    ? 1
                                    : graph.renderedLaneCount,
                                graphWidth: isHistorySearchActive ? 14 : graph.displayWidth,
                                isSearchResult: isHistorySearchActive
                            )
                                .id(commit.id)
                                .tag(IntegratedOverviewSelection.commit(commit.id))
                                .contextMenu {
                                    Button("Copy Commit SHA") {
                                        copyToPasteboard(commit.oid)
                                    }
                                    Button("Copy Subject") {
                                        copyToPasteboard(commit.subject)
                                    }
                                }
                        }
                    }
                    if isHistorySearchActive, !searchedCommits.isEmpty {
                        historySearchFooter
                    } else if !isHistorySearchActive, !commits.isEmpty {
                        historyFooter
                    }
                }
                }
            }
            .listStyle(.sidebar)
            .task(id: requestedHistoryScrollCommitID) {
                guard let commitID = requestedHistoryScrollCommitID else {
                    return
                }
                await Task.yield()
                scrollProxy.scrollTo(commitID, anchor: .center)
                if requestedHistoryScrollCommitID == commitID {
                    requestedHistoryScrollCommitID = nil
                }
            }
        }
    }

    @ViewBuilder
    private var historyFooter: some View {
        let trigger = HistoryPaginationTrigger(
            offset: historyNextOffset,
            automaticallyLoads: requestedRestoredContext == nil,
            hasMore: hasMoreHistory,
            hasError: historyPaginationError != nil
        )
        Group {
            if isLoadingMoreHistory {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading older commits…")
                    Spacer(minLength: 8)
                    Text(countedLabel(commits.count, singular: "commit") + " loaded")
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
            } else if let historyPaginationError {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Unable to Load Older Commits", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Text(historyPaginationError)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .help(historyPaginationError)
                    Button("Retry") {
                        Task {
                            await loadMoreHistory()
                            await loadPagesForRequestedHistoryContext()
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            } else if hasMoreHistory {
                Button {
                    Task {
                        await loadMoreHistory()
                        await loadPagesForRequestedHistoryContext()
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.down")
                        Text("Load Older Commits")
                        Spacer(minLength: 8)
                        Text(countedLabel(commits.count, singular: "commit") + " loaded")
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else if historyNextOffset >= Self.historyPageSize {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark")
                    Text("End of History")
                    Spacer(minLength: 8)
                    Text(countedLabel(commits.count, singular: "commit"))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .task(id: model.isApplicationActive ? trigger : nil) {
            guard model.isApplicationActive,
                  trigger.automaticallyLoads,
                  trigger.hasMore,
                  !trigger.hasError else {
                return
            }
            await loadMoreHistory()
        }
    }

    @ViewBuilder
    private var historySearchFooter: some View {
        let trigger = HistoryPaginationTrigger(
            offset: historySearchNextOffset,
            automaticallyLoads: requestedRestoredContext == nil,
            hasMore: hasMoreHistorySearchResults,
            hasError: historySearchPaginationError != nil
        )
        Group {
            if isLoadingMoreHistorySearchResults {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading more results…")
                    Spacer(minLength: 8)
                    Text(
                        countedLabel(searchedCommits.count, singular: "result")
                            + " found"
                    )
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
            } else if let historySearchPaginationError {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Unable to Load More Results", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Text(historySearchPaginationError)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .help(historySearchPaginationError)
                    Button("Retry") {
                        Task {
                            await loadMoreHistorySearchResults()
                            await loadPagesForRequestedHistoryContext()
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            } else if hasMoreHistorySearchResults {
                Button {
                    Task {
                        await loadMoreHistorySearchResults()
                        await loadPagesForRequestedHistoryContext()
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.down")
                        Text("Load More Results")
                        Spacer(minLength: 8)
                        Text(
                            countedLabel(searchedCommits.count, singular: "result")
                                + " found"
                        )
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else if historySearchNextOffset >= Self.historySearchPageSize {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark")
                    Text("End of Results")
                    Spacer(minLength: 8)
                    Text(
                        countedLabel(searchedCommits.count, singular: "result")
                            + " found"
                    )
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .task(id: model.isApplicationActive ? trigger : nil) {
            guard model.isApplicationActive,
                  trigger.automaticallyLoads,
                  trigger.hasMore,
                  !trigger.hasError else {
                return
            }
            await loadMoreHistorySearchResults()
        }
    }

    private var filesList: some View {
        List(selection: navigatorSelectionBinding) {
            if visibleFileItems.isEmpty {
                if review.filterText.isEmpty {
                    Text("No File Changes")
                        .foregroundStyle(.secondary)
                } else {
                    NavigatorFilterEmptyState(
                        title: "No Matching Files",
                        query: review.filterText,
                        clearFilter: { review.filterText = "" }
                    )
                }
            } else {
                switch activeContext {
                case .pending:
                    ForEach(
                        pendingNavigatorFileGroups(
                            workingItems: workingItems,
                            untrackedItems: untrackedItems,
                            stagedItems: stagedItems
                        )
                    ) { group in
                        Section(group.title) {
                            navigatorTreeRows(
                                group.items,
                                namespace: group.id
                            )
                        }
                    }
                case .commit, .range:
                    navigatorTreeRows(
                        contextItems,
                        namespace: "context"
                    )
                }
            }
        }
        .listStyle(.sidebar)
        .focusable()
        .focused($isFilesNavigatorFocused)
        .onKeyPress(.space) {
            guard navigatorDefaultActionTitle != nil else {
                return .ignored
            }
            performNavigatorDefaultAction()
            return .handled
        }
    }

    @ViewBuilder
    private func navigatorTreeRows(
        _ items: [IntegratedFileItem],
        namespace: String
    ) -> some View {
        let allNodes = navigatorTreeCache.nodes(
            items: items,
            namespace: namespace
        )
        let nodes = filteredNavigatorTreeNodes(
            allNodes,
            query: review.filterText
        )
        let expandedFolderIDs = review.filterText.isEmpty
            ? review.expandedNavigatorFolderIDs
            : navigatorFolderIDs(in: nodes)
        ForEach(
            flattenedNavigatorTreeRows(
                nodes: nodes,
                expandedFolderIDs: expandedFolderIDs
            )
        ) { row in
            switch row.content {
            case let .folder(id, name, fileCount):
                NavigatorFolderRow(
                    name: name,
                    fileCount: fileCount,
                    isExpanded: expandedFolderIDs.contains(id)
                )
                .padding(.leading, CGFloat(row.depth) * 13)
                .tag(NavigatorSelection.folder(id))
            case let .file(item):
                let mutationMode = primaryPendingMutationMode(
                    context: activeContext,
                    item: item
                )
                NavigatorFileRow(
                    item: item,
                    diff: diffsByFileID[item.id],
                    isReviewed: isReviewed(item),
                    primaryActionTitle: mutationMode?.fileActionTitle,
                    canDiscard: activeContext == .pending
                        && item.scope == .working
                        && item.change.kind != .unmerged,
                    showsPathDetail: false
                )
                .padding(.leading, CGFloat(row.depth) * 13)
                .tag(NavigatorSelection.file(item.id.stackID))
                .onTapGesture(count: 2) {
                    performFileUtilityAction(
                        fileID: item.id.stackID,
                        action: .openFile
                    )
                }
                .contextMenu {
                    fileUtilityMenu(for: item)
                }
            }
        }
    }

    /// Files 只负责定位：选中即滚动到 Review 流里的那个文件。
    private var navigatorSelectionBinding: Binding<NavigatorSelection?> {
        Binding(
            get: { navigatorSelection },
            set: { requestedSelection in
                navigatorSelection = requestedSelection
                if requestedSelection != nil {
                    isFilesNavigatorFocused = true
                }
                switch requestedSelection {
                case let .file(fileID):
                    focusFileFromNavigator(fileID)
                case let .folder(folderID):
                    guard review.filterText.isEmpty else {
                        return
                    }
                    toggleNavigatorFolder(folderID)
                case nil:
                    focusFileFromNavigator(nil, expandsFile: false)
                }
            }
        )
    }

    private var reviewScrollTarget: String? {
        diffReviewScrollTarget(
            focusedFileID: review.focusedFileID,
            fileFocusedFromDiffID: fileFocusedFromDiffID
        )
    }

    private func focusFileFromNavigator(
        _ fileID: String?,
        expandsFile: Bool = true
    ) {
        fileFocusedFromDiffID = nil
        navigatorSelection = fileID.map(NavigatorSelection.file)
        if expandsFile, let fileID {
            openReviewDocument(fileID)
        }
        if expandsFile,
           let fileID,
           setReviewFileExpansion(
               in: &review,
               fileIDs: [fileID],
               isExpanded: true
           ) {
            model.reviewStates.save(review, for: stateKey)
        }
        updateFocusedFile(fileID)
    }

    private func openReviewDocument(_ fileID: String) {
        if !openReviewFileIDs.contains(fileID) {
            openReviewFileIDs.append(fileID)
        }
        selectedReviewDocument = .file(fileID)
    }

    private func closeReviewDocument(_ fileID: String) {
        openReviewFileIDs.removeAll { $0 == fileID }
        if selectedReviewDocument == .file(fileID) {
            selectedReviewDocument = .summary
        }
    }

    private func synchronizeReviewDocuments() {
        let validFileIDs = Set(currentFileItems.map { $0.id.stackID })
        openReviewFileIDs.removeAll { !validFileIDs.contains($0) }
        if case let .file(fileID) = selectedReviewDocument,
           !validFileIDs.contains(fileID) {
            selectedReviewDocument = .summary
        }
    }

    private func focusFileFromDiff(_ fileID: String) {
        fileFocusedFromDiffID = fileID
        navigatorSelection = .file(fileID)
        updateFocusedFile(fileID)
    }

    private func updateFocusedFile(_ fileID: String?) {
        guard review.focusedFileID != fileID else {
            return
        }
        review.focusedFileID = fileID
        model.reviewStates.save(review, for: stateKey)
    }

    @ViewBuilder
    private func fileUtilityMenu(for item: IntegratedFileItem) -> some View {
        if let mutationMode = primaryPendingMutationMode(
            context: activeContext,
            item: item
        ) {
            Button(mutationMode.fileActionTitle) {
                executeFileAction(
                    fileID: item.id.stackID,
                    action: mutationMode.primaryAction
                )
            }
            .disabled(!allowsPendingMutations)
            Divider()
        }
        let canOpen = existingWorkingFileIDs.contains(item.id.stackID)
        Button("Open File") {
            performFileUtilityAction(fileID: item.id.stackID, action: .openFile)
        }
        .disabled(!canOpen)
        Button("Open with Visual Studio Code") {
            performFileUtilityAction(
                fileID: item.id.stackID,
                action: .openInVisualStudioCode
            )
        }
        .disabled(!canOpen || Self.visualStudioCodeURL == nil)
        Button("Reveal in Finder") {
            performFileUtilityAction(fileID: item.id.stackID, action: .revealInFinder)
        }
        Divider()
        Button("Copy Relative Path") {
            performFileUtilityAction(fileID: item.id.stackID, action: .copyRelativePath)
        }
        Button("Copy Absolute Path") {
            performFileUtilityAction(fileID: item.id.stackID, action: .copyAbsolutePath)
        }
    }

    // MARK: - Review

    private var reviewPane: some View {
        VStack(spacing: 0) {
            reviewDocumentTabBar
            Divider()
            if selectedReviewDocument == .summary {
                reviewContextHeader
                Divider()
            }
            reviewToolbar
            Divider()
            reviewBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var reviewDocumentTabBar: some View {
        ReviewDocumentTabBar(
            selection: selectedReviewDocument,
            files: openReviewFileIDs.compactMap { fileID in
                currentFileItems.first(where: { $0.id.stackID == fileID }).map {
                    ReviewDocumentFile(
                        id: fileID,
                        title: ($0.change.path as NSString).lastPathComponent,
                        path: $0.change.path
                    )
                }
            },
            selectSummary: {
                selectedReviewDocument = .summary
            },
            selectFile: { fileID in
                selectedReviewDocument = .file(fileID)
                focusFileFromNavigator(fileID)
            },
            closeFile: closeReviewDocument
        )
    }

    @ViewBuilder
    private var reviewContextHeader: some View {
        switch activeContext {
        case .pending:
            IntegratedReviewTitle(
                title: "Pending Changes",
                subtitle: "",
                message: ""
            )
        case let .commit(commitID):
            if let commit = commit(withID: commitID) {
                IntegratedReviewTitle(
                    title: messageSubject(fallback: commit.subject),
                    subtitle: "\(commit.shortOID) · \(commit.authorName) · "
                        + commit.authoredAt.formatted(.dateTime.year().month().day().hour().minute()),
                    message: messageBody
                )
            } else if requestedRestoredContext?.context == .commit(commitID) {
                IntegratedReviewTitle(
                    title: messageSubject(
                        fallback: "Commit \(String(commitID.prefix(7)))"
                    ),
                    subtitle: "\(String(commitID.prefix(7))) · Restoring history…",
                    message: messageBody
                )
            } else {
                IntegratedReviewTitle(
                    title: "Commit Unavailable",
                    subtitle: "This commit is no longer part of the history.",
                    message: ""
                )
            }
        case let .range(base, head):
            IntegratedReviewTitle(
                title: "Commit Range",
                subtitle: "\(String(base.prefix(7)))..\(String(head.prefix(7)))"
                    + " · endpoint diff",
                message: selectedCommits.prefix(4).map(\.subject).joined(separator: "\n")
            )
        }
    }

    private var reviewToolbar: some View {
        HStack(spacing: 12) {
            Text(countedLabel(reviewDocumentFileItems.count, singular: "file"))
                .font(.caption.monospacedDigit().weight(.medium))
            DiffCountLabel(added: totalAddedLineCount, deleted: totalDeletedLineCount)
            if reviewedFileCount > 0 {
                Text(
                    countedLabel(reviewedFileCount, singular: "file")
                        + " reviewed"
                )
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isApplyingMutation || (isLoadingDiffs && !isRefreshingSnapshot) {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .controlSize(.small)
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.bar)
    }

    private func canRunRemoteOperation(_ action: GitRemoteAction) -> Bool {
        remoteOperationUnavailableMessage(for: action) == nil
    }

    private func remoteOperationUnavailableMessage(
        for action: GitRemoteAction
    ) -> String? {
        guard model.isApplicationActive else {
            return "Git operations resume when AgentGit is active."
        }
        return gitRemoteOperationUnavailableReason(
            action: action,
            worktree: snapshot.worktree,
            branchStatus: snapshot.status.branch,
            isApplyingMutation: isApplyingMutation,
            runningAction: runningRemoteAction,
            hasUnresolvedRefreshFailure: blockingGitRefreshError != nil,
            isRefreshingRepository: isRefreshingSnapshot
        )
    }

    private func remoteActionHelp(_ action: GitRemoteAction) -> String {
        if let unavailableMessage = remoteOperationUnavailableMessage(for: action) {
            return unavailableMessage
        }
        return switch action {
        case .pull: "Pull the current branch using fast-forward only"
        case .push:
            hasConfiguredUpstream
                ? "Push the current branch to its configured upstream"
                : "Publish the current branch and configure its upstream"
        }
    }

    private var hasConfiguredUpstream: Bool {
        guard let upstreamRef = snapshot.status.branch?.upstreamRef else {
            return false
        }
        return !upstreamRef.isEmpty
    }

    private var pushActionTitle: String {
        gitPushActionTitle(branchStatus: snapshot.status.branch)
    }

    private var allowsPendingMutations: Bool {
        model.isApplicationActive
            && !isApplyingMutation
            && mutationError == nil
            && blockingGitRefreshError == nil
            && runningRemoteAction == nil
            && !isRefreshingSnapshot
    }

    private var isRefreshingSnapshot: Bool {
        model.isRefreshing(worktreeID: snapshot.id)
    }

    private var blockingGitRefreshError: String? {
        model.blockingGitRefreshError(for: snapshot.id)
    }

    private func remoteOperationErrorBar(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .lineLimit(2)
                .textSelection(.enabled)
                .help(message)
            Spacer(minLength: 8)
            Button {
                remoteOperationError = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss Git Remote Error")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    private func statusRefreshErrorBar(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .lineLimit(2)
                .textSelection(.enabled)
                .help(message)
            Spacer(minLength: 8)
            Button("Retry") {
                Task {
                    await model.refreshWorktree(id: snapshot.id)
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    @ViewBuilder
    private var reviewBody: some View {
        if let diffError, diffsByFileID.isEmpty {
            ContentUnavailableView {
                Label("Unable to Read Diff", systemImage: "exclamationmark.triangle")
            } description: {
                Text(diffError)
                    .textSelection(.enabled)
            } actions: {
                Button("Retry") {
                    Task {
                        await loadDiffs()
                    }
                }
            }
        } else if let contextDetailError {
            ContentUnavailableView {
                Label("Unable to Read Changes", systemImage: "exclamationmark.triangle")
            } description: {
                Text(contextDetailError)
                    .textSelection(.enabled)
            } actions: {
                Button("Retry") {
                    Task {
                        await loadContextDetails(for: stateKey)
                    }
                }
            }
        } else if currentFileItems.isEmpty {
            ContentUnavailableView {
                Label(
                    isLoadingContextDetail ? "Loading Files…" : "No File Changes",
                    systemImage: isLoadingContextDetail ? "clock" : "checkmark.circle"
                )
            } description: {
                if !isLoadingContextDetail {
                    Text(
                        activeContext == .pending
                            ? "The working tree has no staged or unstaged changes."
                            : "This commit selection contains no file changes."
                    )
                }
            }
        } else if selectedReviewDocument == .summary, visibleFileItems.isEmpty {
            ContentUnavailableView {
                Label("No Matching Files", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No changed file matches “\(review.filterText)”.")
            } actions: {
                Button("Clear Filter") {
                    review.filterText = ""
                }
            }
        } else {
            VStack(spacing: 0) {
                if let inlineDiffErrorMessage {
                    inlineDiffErrorBar(inlineDiffErrorMessage)
                    Divider()
                }
                DiffStackView(
                    groups: reviewDocumentStackGroups,
                    layout: model.diffLayout,
                    scrollTarget: reviewScrollTarget,
                    scrollKey: stateKey,
                    scrollStore: model.reviewStates,
                    isApplicationActive: model.isApplicationActive,
                    loadingMessage: isRefreshingSnapshot
                        ? "Waiting for repository update…"
                        : "Loading diff…",
                    mutationActionsEnabled: allowsPendingMutations,
                    command: diffCommand,
                    onFocusFile: focusFileFromDiff,
                    onToggleFile: toggleFile,
                    onToggleGroup: toggleGroup,
                    onToggleReviewed: toggleReviewed,
                    onToggleWholeFile: toggleWholeFile,
                    onExpandContext: expandContext,
                    onFileUtilityAction: performFileUtilityAction,
                    onFileAction: performFileAction,
                    onSelectionAction: performSelectionAction
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func inlineDiffErrorBar(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .lineLimit(2)
                .textSelection(.enabled)
                .help(message)
            Spacer(minLength: 8)
            if mutationError == nil {
                Button("Retry") {
                    Task {
                        if diffError != nil {
                            await loadDiffs()
                        } else {
                            await retrySupplementalDiffs()
                        }
                    }
                }
                .buttonStyle(.borderless)
            }
            Button {
                mutationError = nil
                diffError = nil
                supplementalDiffFailures = [:]
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss Review Error")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.08))
    }

    private func blockingGitRefreshErrorBar(_ message: String) -> some View {
        BlockingGitRefreshErrorBar(
            message: message,
            isRefreshing: isRefreshingSnapshot
        ) {
            Task {
                switch await model.refreshWorktree(id: snapshot.id) {
                case .updated:
                    model.setBlockingGitRefreshError(nil, for: snapshot.id)
                case .superseded:
                    break
                case let .failed(detail):
                    model.setBlockingGitRefreshError(
                        GitMutationRefreshError(detail: detail).description,
                        for: snapshot.id
                    )
                }
            }
        }
    }

    private var inlineDiffErrorMessage: String? {
        mutationError ?? diffError ?? supplementalDiffErrorMessage
    }

    private var supplementalDiffErrorMessage: String? {
        let failures = currentFileItems.compactMap { item -> (String, String)? in
            supplementalDiffFailures[item.id].map { (item.change.path, $0.message) }
        }
        guard let first = failures.first else {
            return nil
        }
        let remaining = failures.count - 1
        return remaining > 0
            ? "\(first.0): \(first.1) · "
                + countedLabel(
                    remaining,
                    singular: "more file",
                    plural: "more files"
                )
            : "\(first.0): \(first.1)"
    }

    // MARK: - Stack composition

    private var stackGroups: [DiffStackGroup] {
        let groups = switch activeContext {
        case .pending:
            [
                stackGroup(
                    id: "working",
                    title: "Working",
                    emptyMessage: emptyMessage("No working changes", "No matching working files"),
                    items: filtered(workingItems + untrackedItems)
                ),
                stackGroup(
                    id: "staged",
                    title: "Staged",
                    emptyMessage: emptyMessage("No staged changes", "No matching staged files"),
                    items: filtered(stagedItems)
                )
            ]
        case .commit, .range:
            [
                stackGroup(
                    id: "context",
                    title: nil,
                    emptyMessage: emptyMessage("No file changes", "No matching files"),
                    items: filtered(contextItems)
                )
            ]
        }
        return nonEmptyDiffStackGroups(groups)
    }

    private var reviewDocumentStackGroups: [DiffStackGroup] {
        switch selectedReviewDocument {
        case .summary:
            return stackGroups
        case let .file(fileID):
            guard let item = currentFileItems.first(where: {
                $0.id.stackID == fileID
            }) else {
                return []
            }
            return [
                stackGroup(
                    id: "document",
                    title: nil,
                    emptyMessage: "No file changes",
                    items: [item]
                )
            ]
        }
    }

    private func emptyMessage(_ empty: String, _ filteredAway: String) -> String {
        review.filterText.isEmpty ? empty : filteredAway
    }

    private func stackGroup(
        id: String,
        title: String?,
        emptyMessage: String,
        items: [IntegratedFileItem]
    ) -> DiffStackGroup {
        DiffStackGroup(
            id: id,
            title: title,
            emptyMessage: emptyMessage,
            isExpanded: items.contains {
                isReviewFileExpanded($0.id.stackID, in: review)
            },
            files: items.map { stackFile(for: $0) }
        )
    }

    private func stackFile(for item: IntegratedFileItem) -> DiffStackFile {
        let canOpenWorkingFile = existingWorkingFileIDs.contains(item.id.stackID)
        return DiffStackFile(
            id: item.id.stackID,
            path: item.change.path,
            originalPath: item.change.originalPath,
            status: item.stackStatus,
            statusLabel: item.statusLabel,
            isExpanded: isReviewFileExpanded(item.id.stackID, in: review),
            isFocused: item.id.stackID == review.focusedFileID,
            isReviewed: isReviewed(item),
            showsWholeFile: showsWholeFile(item),
            isLoadingWholeFile: loadingWholeFileIDs.contains(item.id.stackID),
            canToggleWholeFile: canToggleWholeFile(item),
            canOpenWorkingFile: canOpenWorkingFile,
            canOpenInVisualStudioCode: canOpenWorkingFile
                && Self.visualStudioCodeURL != nil,
            canApplyPrimaryAction: primaryPendingMutationMode(
                context: activeContext,
                item: item
            ) != nil,
            canDiscard: activeContext == .pending
                && item.scope == .working
                && item.change.kind != .unmerged,
            isMutationEnabled: allowsPendingMutations,
            mutationSnapshotID: reviewSnapshotID(for: item),
            contextGaps: contextGaps(for: item),
            mutationMode: activeContext == .pending
                ? (item.scope == .working ? .working : .staged)
                : nil,
            diff: displayedDiff(for: item),
            imageDiff: imageDiffsByFileID[item.id]
        )
    }

    // MARK: - Pending mutations

    private func performFileUtilityAction(
        fileID: String,
        action: DiffStackFileUtilityAction
    ) {
        guard let item = currentFileItems.first(where: { $0.id.stackID == fileID }),
              let fileURL = workingFileURL(for: item) else {
            return
        }
        switch action {
        case .openFile:
            guard existingWorkingFileURL(for: item) != nil else {
                return
            }
            openDocument(fileURL)
        case .openInVisualStudioCode:
            guard existingWorkingFileURL(for: item) != nil,
                  let applicationURL = Self.visualStudioCodeURL else {
                return
            }
            openInVisualStudioCode(fileURL, applicationURL: applicationURL)
        case .revealInFinder:
            revealInFinder(nearestExistingURL(from: fileURL))
        case .copyRelativePath:
            copyToPasteboard(item.change.path)
        case .copyAbsolutePath:
            copyToPasteboard(fileURL.path)
        }
    }

    private func workingFileURL(for item: IntegratedFileItem) -> URL? {
        let rootURL = snapshot.worktree.rootURL.standardizedFileURL
        let fileURL = rootURL
            .appendingPathComponent(item.change.path)
            .standardizedFileURL
        guard fileURL.path.hasPrefix(rootURL.path + "/") else {
            return nil
        }
        return fileURL
    }

    private func existingWorkingFileURL(for item: IntegratedFileItem) -> URL? {
        guard let fileURL = workingFileURL(for: item) else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: fileURL.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue else {
            return nil
        }
        return fileURL
    }

    private func nearestExistingURL(from fileURL: URL) -> URL {
        let rootURL = snapshot.worktree.rootURL.standardizedFileURL
        var candidate = fileURL
        while candidate.path != rootURL.path,
              !FileManager.default.fileExists(atPath: candidate.path) {
            candidate = candidate.deletingLastPathComponent()
        }
        return candidate
    }

    private func performFileAction(
        fileID: String,
        action: GitPendingSelectionAction
    ) {
        executeFileAction(fileID: fileID, action: action)
    }

    private var navigatorDefaultActionTitle: String? {
        guard isFilesNavigatorFocused, pane == .files else {
            return nil
        }
        switch navigatorSelection {
        case let .folder(folderID):
            guard review.filterText.isEmpty else {
                return nil
            }
            return review.expandedNavigatorFolderIDs.contains(folderID)
                ? "Collapse Folder"
                : "Expand Folder"
        case .file:
            guard let command = focusedFilePrimaryCommand else {
                return nil
            }
            return command.action == .stage
                ? "Stage Focused File"
                : "Unstage Focused File"
        case nil:
            return nil
        }
    }

    private var focusedFilePrimaryCommand: PendingFilePrimaryCommand? {
        guard allowsPendingMutations else {
            return nil
        }
        return pendingFilePrimaryCommand(
            context: activeContext,
            focusedFileID: review.focusedFileID,
            items: currentFileItems
        )
    }

    private var focusedFileDiscardCommand: PendingFilePrimaryCommand? {
        guard isFilesNavigatorFocused,
              pane == .files,
              allowsPendingMutations else {
            return nil
        }
        return pendingFileDiscardCommand(
            context: activeContext,
            focusedFileID: review.focusedFileID,
            items: currentFileItems
        )
    }

    private func performNavigatorDefaultAction() {
        guard isFilesNavigatorFocused, pane == .files else {
            return
        }
        switch navigatorSelection {
        case let .folder(folderID):
            guard review.filterText.isEmpty else {
                return
            }
            toggleNavigatorFolder(folderID)
        case .file:
            _ = performFocusedFilePrimaryAction()
        case nil:
            break
        }
    }

    private func requestFocusedFileDiscard() {
        guard let command = focusedFileDiscardCommand else {
            return
        }
        diffCommandSequence &+= 1
        diffCommand = DiffStackCommand(
            id: diffCommandSequence,
            action: .requestFileDiscard(command.fileID)
        )
    }

    private func performFocusedFilePrimaryAction() -> Bool {
        guard let command = focusedFilePrimaryCommand else {
            return false
        }
        executeFileAction(
            fileID: command.fileID,
            action: command.action
        )
        return true
    }

    private func executeFileAction(
        fileID: String,
        action: GitPendingSelectionAction
    ) {
        guard activeContext == .pending,
              allowsPendingMutations,
              let item = currentFileItems.first(where: { $0.id.stackID == fileID }) else {
            return
        }
        if item.change.kind == .unmerged, action != .stage {
            return
        }
        mutationSequence &+= 1
        let request = ReviewOperationRequest(
            worktreeID: snapshot.id,
            sequence: mutationSequence
        )
        isApplyingMutation = true
        mutationError = nil
        Task {
            let operationErrorMessage: String?
            let refreshErrorMessage: String?
            do {
                try await model.applyFileAction(
                    action,
                    worktree: snapshot.worktree,
                    change: item.change
                )
                operationErrorMessage = nil
                refreshErrorMessage = nil
            } catch let error as GitMutationRefreshError {
                operationErrorMessage = nil
                refreshErrorMessage = error.description
            } catch {
                let message = String(describing: error)
                let refreshOutcome = await model.refreshWorktree(id: snapshot.id)
                operationErrorMessage = message
                refreshErrorMessage = mutationRefreshFailureMessage(
                    refreshOutcome
                )
            }
            model.setBlockingGitRefreshError(
                refreshErrorMessage,
                for: request.worktreeID
            )
            guard reviewOperationRequestMatches(
                currentWorktreeID: model.selectedWorktreeID,
                currentSequence: mutationSequence,
                requested: request
            ) else {
                return
            }
            mutationError = operationErrorMessage
            isApplyingMutation = false
        }
    }

    private func performSelectionAction(
        fileID: String,
        lineIDs: Set<GitDiffLine.ID>,
        action: GitPendingSelectionAction
    ) {
        executeSelectionAction(fileID: fileID, lineIDs: lineIDs, action: action)
    }

    private func executeSelectionAction(
        fileID: String,
        lineIDs: Set<GitDiffLine.ID>,
        action: GitPendingSelectionAction
    ) {
        guard activeContext == .pending,
              allowsPendingMutations,
              let item = currentFileItems.first(where: { $0.id.stackID == fileID }),
              item.change.kind != .unmerged,
              let diff = displayedDiff(for: item),
              !lineIDs.isEmpty else {
            return
        }
        mutationSequence &+= 1
        let request = ReviewOperationRequest(
            worktreeID: snapshot.id,
            sequence: mutationSequence
        )
        isApplyingMutation = true
        mutationError = nil
        Task {
            let operationErrorMessage: String?
            let refreshErrorMessage: String?
            do {
                try await model.applySelectionAction(
                    action,
                    worktree: snapshot.worktree,
                    diff: diff,
                    selectedLineIDs: lineIDs
                )
                operationErrorMessage = nil
                refreshErrorMessage = nil
            } catch let error as GitMutationRefreshError {
                operationErrorMessage = nil
                refreshErrorMessage = error.description
            } catch {
                let message = String(describing: error)
                let refreshOutcome = await model.refreshWorktree(id: snapshot.id)
                operationErrorMessage = message
                refreshErrorMessage = mutationRefreshFailureMessage(
                    refreshOutcome
                )
            }
            model.setBlockingGitRefreshError(
                refreshErrorMessage,
                for: request.worktreeID
            )
            guard reviewOperationRequestMatches(
                currentWorktreeID: model.selectedWorktreeID,
                currentSequence: mutationSequence,
                requested: request
            ) else {
                return
            }
            mutationError = operationErrorMessage
            isApplyingMutation = false
        }
    }

    private func performRemoteAction(_ action: GitRemoteAction) {
        executeRemoteAction(action)
    }

    private func executeRemoteAction(_ action: GitRemoteAction) {
        guard canRunRemoteOperation(action) else {
            return
        }
        remoteOperationSequence &+= 1
        let request = ReviewOperationRequest(
            worktreeID: snapshot.id,
            sequence: remoteOperationSequence
        )
        runningRemoteAction = action
        remoteFeedbackDismissTask?.cancel()
        remoteFeedbackDismissTask = nil
        remoteOperationFeedback = nil
        isCancellingRemoteOperation = false
        remoteOperationError = nil
        let task = Task {
            let feedback: RemoteOperationFeedback?
            let errorMessage: String?
            let refreshErrorMessage: String?
            do {
                try await model.performRemoteAction(action, worktree: snapshot.worktree)
                feedback = RemoteOperationFeedback(
                    action: action,
                    outcome: .completed
                )
                errorMessage = nil
                refreshErrorMessage = nil
            } catch is CancellationError {
                let refreshOutcome = await refreshWorktreeAfterRemoteCancellation(
                    id: snapshot.id
                )
                feedback = RemoteOperationFeedback(
                    action: action,
                    outcome: .cancelled
                )
                errorMessage = nil
                refreshErrorMessage = mutationRefreshFailureMessage(
                    refreshOutcome
                )
            } catch let error as GitMutationRefreshError {
                feedback = nil
                errorMessage = nil
                refreshErrorMessage = error.description
            } catch {
                let refreshOutcome = await model.refreshWorktree(id: snapshot.id)
                feedback = nil
                errorMessage = gitRemoteOperationFailureMessage(
                    action: action,
                    error: error
                )
                refreshErrorMessage = mutationRefreshFailureMessage(
                    refreshOutcome
                )
            }
            model.setBlockingGitRefreshError(
                refreshErrorMessage,
                for: request.worktreeID
            )
            guard reviewOperationRequestMatches(
                currentWorktreeID: model.selectedWorktreeID,
                currentSequence: remoteOperationSequence,
                requested: request
            ) else {
                return
            }
            if let feedback {
                showRemoteOperationFeedback(
                    feedback,
                    request: request
                )
            }
            remoteOperationError = errorMessage
            runningRemoteAction = nil
            isCancellingRemoteOperation = false
            remoteOperationTask = nil
        }
        remoteOperationTask = task
    }

    private func refreshWorktreeAfterRemoteCancellation(
        id: GitWorktree.ID
    ) async -> WorktreeRefreshOutcome {
        await runIndependentWorktreeRefresh {
            await model.refreshWorktree(id: id)
        }
    }

    private func cancelRemoteOperation() {
        guard remoteOperationTask != nil else {
            return
        }
        isCancellingRemoteOperation = true
        remoteOperationTask?.cancel()
    }

    private func showRemoteOperationFeedback(
        _ feedback: RemoteOperationFeedback,
        request: ReviewOperationRequest
    ) {
        remoteFeedbackDismissTask?.cancel()
        remoteOperationFeedback = feedback
        remoteFeedbackDismissTask = Task {
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard reviewOperationRequestMatches(
                currentWorktreeID: model.selectedWorktreeID,
                currentSequence: remoteOperationSequence,
                requested: request
            ), remoteOperationFeedback == feedback else {
                return
            }
            remoteOperationFeedback = nil
            remoteFeedbackDismissTask = nil
        }
    }

    // MARK: - Derived state

    private var activeContext: ReviewContext {
        effectiveReviewContext(
            requestedRestoration: requestedRestoredContext,
            selectedCommits: selectedCommits
        )
    }

    /// 按历史顺序（新 → 旧）排列，range 的 head/base 才有确定含义。
    private var selectedCommits: [GitCommit] {
        displayedHistoryCommits.filter {
            selectedCommitIDSet.contains($0.id)
        }
    }

    private var selectedCommitIDSet: Set<GitCommit.ID> {
        Set(
            selection.compactMap { item -> GitCommit.ID? in
                guard case let .commit(id) = item else {
                    return nil
                }
                return id
            }
        )
    }

    private var stateKey: ReviewStateKey {
        ReviewStateKey(worktreeID: snapshot.id, context: activeContext)
    }

    private var reviewFileExpansionSyncKey: ReviewFileExpansionSyncKey {
        ReviewFileExpansionSyncKey(
            stateKey: stateKey,
            fileIDs: Set(currentFileItems.map(\.id.stackID))
        )
    }

    private var currentNavigatorFolderIDs: Set<String> {
        switch activeContext {
        case .pending:
            return navigatorFolderIDs(
                in: navigatorTreeCache.nodes(
                    items: workingItems + untrackedItems,
                    namespace: "working"
                )
            ).union(
                navigatorFolderIDs(
                    in: navigatorTreeCache.nodes(
                        items: stagedItems,
                        namespace: "staged"
                    )
                )
            )
        case .commit, .range:
            return navigatorFolderIDs(
                in: navigatorTreeCache.nodes(
                    items: contextItems,
                    namespace: "context"
                )
            )
        }
    }

    private var currentNavigationState: ReviewNavigationState {
        if let requestedRestoredContext {
            return requestedRestoredContext
        }
        return ReviewNavigationState(
            context: activeContext,
            selectedCommitIDs: selectedCommitIDSet,
            pane: pane,
            historyFilter: commitFilterText
        )
    }

    private var historyLoadKey: HistoryLoadKey {
        HistoryLoadKey(
            worktreeID: snapshot.id,
            revision: snapshot.worktree.headOID
        )
    }

    private var historySearchQuery: GitHistorySearchQuery? {
        GitHistorySearchQuery(commitFilterText)
    }

    private var historySearchLoadKey: HistorySearchLoadKey {
        HistorySearchLoadKey(
            worktreeID: snapshot.id,
            revision: snapshot.worktree.headOID,
            query: historySearchQuery
        )
    }

    private var isHistorySearchActive: Bool {
        historySearchQuery != nil
    }

    private var displayedHistoryCommits: [GitCommit] {
        isHistorySearchActive ? searchedCommits : commits
    }

    private var visibleCommits: [GitCommit] {
        displayedHistoryCommits
    }

    private func commit(withID id: GitCommit.ID) -> GitCommit? {
        searchedCommits.first(where: { $0.id == id })
            ?? commits.first(where: { $0.id == id })
    }

    private var workingItems: [IntegratedFileItem] {
        snapshotWorkingItems
    }

    private var untrackedItems: [IntegratedFileItem] {
        snapshotUntrackedItems
    }

    private var stagedItems: [IntegratedFileItem] {
        snapshotStagedItems
    }

    private var contextItems: [IntegratedFileItem] {
        guard activeContext != .pending else {
            return []
        }
        let contextID = Self.identifier(for: activeContext)
        return contextChanges.map { change in
            IntegratedFileItem(
                id: .context(contextID: contextID, changeID: change.id),
                change: change,
                scope: .staged
            )
        }
    }

    private var currentFileItems: [IntegratedFileItem] {
        switch activeContext {
        case .pending: workingItems + untrackedItems + stagedItems
        case .commit, .range: contextItems
        }
    }

    private var visibleFileItems: [IntegratedFileItem] {
        filtered(currentFileItems)
    }

    private var reviewDocumentFileItems: [IntegratedFileItem] {
        switch selectedReviewDocument {
        case .summary:
            visibleFileItems
        case let .file(fileID):
            currentFileItems.filter { $0.id.stackID == fileID }
        }
    }

    private func filtered(_ items: [IntegratedFileItem]) -> [IntegratedFileItem] {
        guard !review.filterText.isEmpty else {
            return items
        }
        return items.filter {
            $0.change.path.localizedCaseInsensitiveContains(review.filterText)
        }
    }

    private func isReviewed(_ item: IntegratedFileItem) -> Bool {
        guard let reviewed = review.reviewedSnapshotByFileID[item.id.stackID],
              let current = reviewSnapshotID(for: item) else {
            return false
        }
        return reviewed == current
    }

    private func reviewSnapshotID(for item: IntegratedFileItem) -> DiffReviewSnapshotID? {
        guard let diff = diffsByFileID[item.id] else {
            return nil
        }
        let externalSeed: String?
        if activeContext == .pending, diff.state != .textual {
            externalSeed = String(snapshot.lastActivityAt.timeIntervalSinceReferenceDate.bitPattern)
        } else {
            externalSeed = nil
        }
        return DiffReviewSnapshotID(diff: diff, externalSeed: externalSeed)
    }

    private func displayedDiff(for item: IntegratedFileItem) -> GitFileDiff? {
        return diffsByFileID[item.id]
    }

    private func contextGaps(for item: IntegratedFileItem) -> [DiffStackContextGap] {
        guard let compactDiff = diffsByFileID[item.id] else {
            return []
        }
        return DiffContextGapBuilder.gaps(
            fileID: item.id.stackID,
            compactDiff: compactDiff,
            contextSourceDiff: wholeFileDiffsByFileID[item.id]
                ?? expandedContextDiffsByFileID[item.id],
            revealedLineCountByGapID: review.revealedContextLineCountByGapID,
            revealsWholeFile: showsWholeFile(item)
        )
    }

    private func canToggleWholeFile(_ item: IntegratedFileItem) -> Bool {
        guard model.diffOptions.context != .wholeFile else {
            return false
        }
        return canLoadWholeFileContext(item)
    }

    private func canLoadWholeFileContext(_ item: IntegratedFileItem) -> Bool {
        guard !item.change.isUntracked,
              let diff = diffsByFileID[item.id] else {
            return false
        }
        return diff.state == .textual
    }

    private func showsWholeFile(_ item: IntegratedFileItem) -> Bool {
        model.diffOptions.context == .wholeFile
            || review.wholeFileIDs.contains(item.id.stackID)
    }

    private var totalAddedLineCount: Int {
        reviewDocumentFileItems.reduce(0) {
            $0 + (diffsByFileID[$1.id]?.addedLineCount ?? 0)
        }
    }

    private var totalDeletedLineCount: Int {
        reviewDocumentFileItems.reduce(0) {
            $0 + (diffsByFileID[$1.id]?.deletedLineCount ?? 0)
        }
    }

    private var reviewedFileCount: Int {
        reviewDocumentFileItems.count(where: isReviewed)
    }

    private func messageSubject(fallback: String) -> String {
        let subject = contextMessage
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        return subject.isEmpty ? fallback : subject
    }

    private var messageBody: String {
        let parts = contextMessage.split(
            separator: "\n",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard parts.count == 2 else {
            return ""
        }
        return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var diffLoadKey: IntegratedDiffLoadKey {
        IntegratedDiffLoadKey(
            worktreeID: snapshot.id,
            activityDate: snapshot.lastActivityAt,
            context: activeContext,
            options: model.diffOptions,
            fileIDs: currentFileItems.map(\.id)
        )
    }

    private func acceptsReviewState(_ key: ReviewStateKey) -> Bool {
        reviewStateRequestMatches(
            currentWorktreeID: model.selectedWorktreeID,
            currentContext: activeContext,
            requested: key
        )
    }

    private func acceptsDiffLoad(_ key: IntegratedDiffLoadKey) -> Bool {
        guard let currentSnapshot = model.selectedWorktree else {
            return false
        }
        return acceptsIntegratedDiffLoad(
            currentWorktreeID: currentSnapshot.id,
            currentActivityDate: currentSnapshot.lastActivityAt,
            currentContext: activeContext,
            currentOptions: model.diffOptions,
            currentFileIDs: currentFileIDs(
                snapshot: currentSnapshot,
                context: key.context
            ),
            requested: key
        )
    }

    private func currentFileIDs(
        snapshot: GitWorktreeSnapshot,
        context: ReviewContext
    ) -> [IntegratedFileID] {
        switch context {
        case .pending:
            return pendingIntegratedFileItems(in: snapshot).all.map(\.id)
        case .commit, .range:
            let contextID = Self.identifier(for: context)
            return contextChanges.map { change in
                IntegratedFileID.context(
                    contextID: contextID,
                    changeID: change.id
                )
            }
        }
    }

    private func acceptsWorkingFileAvailabilityLoad(
        _ key: WorkingFileAvailabilityKey
    ) -> Bool {
        guard let currentSnapshot = model.selectedWorktree else {
            return false
        }
        return workingFileAvailabilityRequestMatches(
            currentWorktreeID: currentSnapshot.id,
            currentActivityDate: currentSnapshot.lastActivityAt,
            currentContext: activeContext,
            currentFileIDs: currentFileIDs(
                snapshot: currentSnapshot,
                context: key.context
            ),
            requested: key
        )
    }

    private var workingFileAvailabilityKey: WorkingFileAvailabilityKey {
        WorkingFileAvailabilityKey(
            worktreeID: snapshot.id,
            activityDate: snapshot.lastActivityAt,
            context: activeContext,
            fileIDs: currentFileItems.map(\.id)
        )
    }

    // MARK: - Actions

    private var overviewSelectionBinding: Binding<
        Set<IntegratedOverviewSelection>
    > {
        Binding(
            get: { selection },
            set: { requestedSelection in
                applyUserSelection(requestedSelection)
            }
        )
    }

    private func applyUserSelection(
        _ requestedSelection: Set<IntegratedOverviewSelection>
    ) {
        let normalized = normalizedCommitEndpointSelection(
            normalizedOverviewSelection(
                previous: selection,
                current: requestedSelection
            ),
            commits: displayedHistoryCommits
        )
        let selectedIDs = commitIDs(in: normalized)
        let selected = displayedHistoryCommits.filter {
            selectedIDs.contains($0.id)
        }
        let next = ReviewNavigationState(
            context: reviewContext(for: selected),
            selectedCommitIDs: selectedIDs,
            pane: pane,
            historyFilter: commitFilterText
        )
        navigationHistory.recordTransition(
            from: currentNavigationState,
            to: next
        )
        requestedRestoredContext = nil
        selection = normalized
        model.reviewStates.saveLastContext(
            next.context,
            selectedCommitIDs: next.selectedCommitIDs,
            pane: next.pane,
            historyFilter: next.historyFilter,
            for: snapshot.id
        )
    }

    private func navigateBack() {
        guard let target = navigationHistory.navigateBack(
            from: currentNavigationState
        ) else {
            return
        }
        applyNavigationState(target)
    }

    private func navigateForward() {
        guard let target = navigationHistory.navigateForward(
            from: currentNavigationState
        ) else {
            return
        }
        applyNavigationState(target)
    }

    private func applyNavigationState(_ state: ReviewNavigationState) {
        pane = state.pane
        if commitFilterText != state.historyFilter {
            suppressedHistoryFilterValue = state.historyFilter
            commitFilterText = state.historyFilter
        }
        let availableCommits = commitsForNavigationState(state)
        if let restoredSelection = restoredHistorySelection(
            state,
            commits: availableCommits
        ) {
            requestedHistoryScrollCommitID = historyScrollTargetID(
                selection: restoredSelection,
                commits: availableCommits
            )
            selection = restoredSelection
            requestedRestoredContext = nil
        } else {
            selection = unresolvedOverviewSelection(
                context: state.context,
                selectedCommitIDs: state.selectedCommitIDs
            )
            requestedRestoredContext = state
        }
    }

    private func handleHistoryFilterChange(
        from previousFilter: String,
        to currentFilter: String
    ) {
        if suppressedHistoryFilterValue == currentFilter {
            suppressedHistoryFilterValue = nil
            return
        }
        let selectedIDs = selectedCommitIDSet
        guard !selectedIDs.isEmpty else {
            model.reviewStates.saveLastContext(
                activeContext,
                selectedCommitIDs: selectedIDs,
                pane: pane,
                historyFilter: currentFilter,
                for: snapshot.id
            )
            return
        }
        guard let transition = historyFilterNavigationTransition(
            previousFilter: previousFilter,
            currentFilter: currentFilter,
            selectedCommitIDs: selectedIDs,
            pane: pane,
            baseCommits: commits,
            searchedCommits: searchedCommits
        ) else {
            selection = [.pending]
            requestedRestoredContext = nil
            model.reviewStates.saveLastContext(
                .pending,
                selectedCommitIDs: [],
                pane: pane,
                historyFilter: currentFilter,
                for: snapshot.id
            )
            return
        }
        selection = transition.selection
        requestedRestoredContext = nil
        navigationHistory.recordTransition(
            from: transition.previous,
            to: transition.current
        )
        model.reviewStates.saveLastContext(
            transition.current.context,
            selectedCommitIDs: transition.current.selectedCommitIDs,
            pane: transition.current.pane,
            historyFilter: transition.current.historyFilter,
            for: snapshot.id
        )
    }

    private func commitsForNavigationState(
        _ state: ReviewNavigationState
    ) -> [GitCommit] {
        guard let query = GitHistorySearchQuery(state.historyFilter) else {
            return commits
        }
        let key = HistorySearchLoadKey(
            worktreeID: snapshot.id,
            revision: snapshot.worktree.headOID,
            query: query
        )
        return loadedHistorySearchKey == key ? searchedCommits : []
    }

    private func commitIDs(
        in selection: Set<IntegratedOverviewSelection>
    ) -> Set<GitCommit.ID> {
        Set(selection.compactMap { item in
            guard case let .commit(id) = item else {
                return nil
            }
            return id
        })
    }

    private func resetWorkspace() {
        remoteOperationSequence &+= 1
        remoteOperationTask?.cancel()
        remoteOperationTask = nil
        remoteFeedbackDismissTask?.cancel()
        remoteFeedbackDismissTask = nil
        commits = []
        commitGraphLayout = CommitGraphLayout(commits: [])
        selection = [.pending]
        pane = initialPane
        requestedRestoredContext = initialContext == .pending
            ? nil
            : ReviewNavigationState(
                context: initialContext,
                selectedCommitIDs: initialSelectedCommitIDs,
                pane: initialPane,
                historyFilter: initialHistoryFilter
            )
        requestedHistoryScrollCommitID = nil
        commitFilterText = initialHistoryFilter
        historyError = nil
        historyPaginationError = nil
        loadedHistoryKey = nil
        completedHistoryKey = nil
        historyNextOffset = 0
        hasMoreHistory = false
        searchedCommits = []
        loadedHistorySearchKey = nil
        completedHistorySearchKey = nil
        historySearchNextOffset = 0
        hasMoreHistorySearchResults = false
        historySearchError = nil
        historySearchPaginationError = nil
        historySearchPageCache.removeAll()
        contextChanges = []
        contextMessage = ""
        diffsByFileID = [:]
        restoredBaseDiffLoadKey = nil
        completedDiffLoadKey = nil
        imageDiffsByFileID = [:]
        wholeFileDiffsByFileID = [:]
        loadingWholeFileIDs = []
        expandedContextDiffsByFileID = [:]
        expandedContextLineCountByFileID = [:]
        loadingContextGapIDs = []
        existingWorkingFileIDs = []
        supplementalDiffFailures = [:]
        review = model.reviewStates.state(
            for: ReviewStateKey(
                worktreeID: snapshot.id,
                context: .pending
            )
        )
        navigatorSelection = review.focusedFileID.map(NavigatorSelection.file)
        contextDetailError = nil
        diffError = nil
        mutationError = nil
        remoteOperationError = nil
        runningRemoteAction = nil
        remoteOperationFeedback = nil
        isCancellingRemoteOperation = false
        isLoadingContextDetail = false
        isLoadingDiffs = false
        isLoadingMoreHistory = false
        isSearchingHistory = false
        isLoadingMoreHistorySearchResults = false
        mutationSequence &+= 1
        isApplyingMutation = false
        navigationHistory.removeAll()
        suppressedHistoryFilterValue = nil
        fileFocusedFromDiffID = nil
        diffCommand = nil
    }

    private func toggleFile(_ stackID: String) {
        toggleReviewFileExpansion(in: &review, fileID: stackID)
        model.reviewStates.save(review, for: stateKey)
    }

    private func toggleNavigatorFolder(_ folderID: String) {
        if review.expandedNavigatorFolderIDs.contains(folderID) {
            review.expandedNavigatorFolderIDs.remove(folderID)
        } else {
            review.expandedNavigatorFolderIDs.insert(folderID)
        }
        model.reviewStates.save(review, for: stateKey)
    }

    private func toggleReviewed(_ stackID: String) {
        guard let item = currentFileItems.first(where: { $0.id.stackID == stackID }),
              let snapshotID = reviewSnapshotID(for: item) else {
            return
        }
        if review.reviewedSnapshotByFileID[stackID] == snapshotID {
            review.reviewedSnapshotByFileID.removeValue(forKey: stackID)
        } else {
            review.reviewedSnapshotByFileID[stackID] = snapshotID
        }
        model.reviewStates.save(review, for: stateKey)
    }

    private func toggleWholeFile(_ stackID: String) {
        guard let item = currentFileItems.first(where: { $0.id.stackID == stackID }) else {
            return
        }
        if review.wholeFileIDs.contains(stackID) {
            review.wholeFileIDs.remove(stackID)
            loadingWholeFileIDs.remove(stackID)
            supplementalDiffFailures[item.id] = nil
            model.reviewStates.save(review, for: stateKey)
            return
        }
        guard canToggleWholeFile(item) else {
            return
        }

        if wholeFileDiffsByFileID[item.id] != nil {
            review.wholeFileIDs.insert(stackID)
            supplementalDiffFailures[item.id] = nil
            model.reviewStates.save(review, for: stateKey)
            return
        }

        let requestedLoadKey = diffLoadKey
        let requestedContext = activeContext
        review.wholeFileIDs.insert(stackID)
        model.reviewStates.save(review, for: stateKey)
        loadingWholeFileIDs.insert(stackID)
        Task {
            defer {
                if acceptsDiffLoad(requestedLoadKey) {
                    loadingWholeFileIDs.remove(stackID)
                }
            }
            do {
                let diff = try await loadWholeFileDiff(
                    for: item,
                    context: requestedContext
                )
                try Task.checkCancellation()
                guard acceptsDiffLoad(requestedLoadKey) else {
                    return
                }
                guard diff.state == .textual else {
                    throw IntegratedReviewLoadError.contextUnavailable
                }
                wholeFileDiffsByFileID[item.id] = diff
                supplementalDiffFailures[item.id] = nil
            } catch is CancellationError {
                return
            } catch {
                guard acceptsDiffLoad(requestedLoadKey) else {
                    return
                }
                recordSupplementalFailure(
                    for: item,
                    operation: .wholeFile,
                    error: error
                )
            }
        }
    }

    private func expandContext(fileID: String, gapID: String) {
        guard !loadingContextGapIDs.contains(gapID),
              let item = currentFileItems.first(where: { $0.id.stackID == fileID }),
              let gap = contextGaps(for: item).first(where: { $0.id == gapID }),
              gap.hiddenLineCount > 0,
              let baseContextLineCount else {
            return
        }
        let currentLineCount = review.revealedContextLineCountByGapID[gapID] ?? 0
        let requestedLineCount = currentLineCount + min(20, gap.hiddenLineCount)
        if wholeFileDiffsByFileID[item.id] != nil
            || (expandedContextLineCountByFileID[item.id] ?? 0) >= requestedLineCount {
            review.revealedContextLineCountByGapID[gapID] = requestedLineCount
            model.reviewStates.save(review, for: stateKey)
            return
        }

        let requestedLoadKey = diffLoadKey
        let requestedContext = activeContext
        var options = compactDiffOptions
        options.context = .lines(baseContextLineCount + requestedLineCount)
        loadingContextGapIDs.insert(gapID)
        Task {
            defer {
                if acceptsDiffLoad(requestedLoadKey) {
                    loadingContextGapIDs.remove(gapID)
                }
            }
            do {
                let diff = try await loadFileDiff(
                    for: item,
                    context: requestedContext,
                    options: options
                )
                try Task.checkCancellation()
                guard acceptsDiffLoad(requestedLoadKey) else {
                    return
                }
                guard diff.state == .textual else {
                    throw IntegratedReviewLoadError.contextUnavailable
                }
                expandedContextDiffsByFileID[item.id] = diff
                expandedContextLineCountByFileID[item.id] = requestedLineCount
                review.revealedContextLineCountByGapID[gapID] = requestedLineCount
                model.reviewStates.save(review, for: stateKey)
                supplementalDiffFailures[item.id] = nil
            } catch is CancellationError {
                return
            } catch {
                guard acceptsDiffLoad(requestedLoadKey) else {
                    return
                }
                recordSupplementalFailure(
                    for: item,
                    operation: .context(gapID: gapID, lineCount: requestedLineCount),
                    error: error
                )
            }
        }
    }

    private var baseContextLineCount: Int? {
        guard case let .lines(count) = compactDiffOptions.context else {
            return nil
        }
        return count
    }

    private var compactDiffOptions: GitDiffOptions {
        var options = model.diffOptions
        if options.context == .wholeFile {
            options.context = .lines(3)
        }
        return options
    }

    /// 点分组标题一键展开或折叠该组：只要还有展开的文件就整组折叠。
    private func toggleGroup(_ groupID: String) {
        let items = groupItems(id: groupID)
        guard !items.isEmpty else {
            return
        }
        let shouldExpand = !items.contains {
            isReviewFileExpanded($0.id.stackID, in: review)
        }
        setReviewFileExpansion(
            in: &review,
            fileIDs: Set(items.map(\.id.stackID)),
            isExpanded: shouldExpand
        )
        model.reviewStates.save(review, for: stateKey)
    }

    private func groupItems(id: String) -> [IntegratedFileItem] {
        switch id {
        case "working": filtered(workingItems + untrackedItems)
        case "staged": filtered(stagedItems)
        case "context": filtered(contextItems)
        default: []
        }
    }

    private func moveFileFocus(by offset: Int) {
        let files = visibleFileItems
        guard !files.isEmpty else {
            return
        }
        let next: Int
        if let current = files.firstIndex(where: { $0.id.stackID == review.focusedFileID }) {
            next = min(files.count - 1, max(0, current + offset))
        } else {
            next = offset > 0 ? 0 : files.count - 1
        }
        focusFileFromNavigator(files[next].id.stackID)
    }

    // MARK: - Loading

    private func loadHistory(for key: HistoryLoadKey) async {
        guard completedHistoryKey != key else {
            return
        }
        isLoadingHistory = true
        defer {
            if loadedHistoryKey == key {
                isLoadingHistory = false
            }
        }
        historyError = nil
        historyPaginationError = nil
        if requestedRestoredContext == nil, activeContext != .pending {
            requestedRestoredContext = ReviewNavigationState(
                context: activeContext,
                selectedCommitIDs: selectedCommitIDSet,
                pane: pane,
                historyFilter: commitFilterText
            )
        }
        loadedHistoryKey = key
        historyNextOffset = 0
        hasMoreHistory = false
        if let cachedPage = await model.cachedHistoryPage(
            worktreeID: snapshot.id,
            revision: key.revision,
            pageSize: Self.historyPageSize
        ) {
            guard !Task.isCancelled else {
                return
            }
            let graph = await buildCommitGraph(for: cachedPage.commits)
            guard !Task.isCancelled, loadedHistoryKey == key else {
                return
            }
            commits = cachedPage.commits
            commitGraphLayout = graph
            historyNextOffset = cachedPage.nextOffset
            hasMoreHistory = cachedPage.hasMore
            restoreLastContextIfPossible(
                commits: cachedPage.commits,
                hasMore: cachedPage.hasMore,
                query: nil
            )
            completedHistoryKey = key
            return
        }
        do {
            let page = try await model.loadHistoryPage(
                worktree: snapshot.worktree,
                revision: key.revision,
                offset: 0,
                pageSize: Self.historyPageSize
            )
            try Task.checkCancellation()
            let graph = await buildCommitGraph(for: page.commits)
            try Task.checkCancellation()
            guard loadedHistoryKey == key else {
                return
            }
            commits = page.commits
            commitGraphLayout = graph
            historyNextOffset = page.nextOffset
            hasMoreHistory = page.hasMore
            restoreLastContextIfPossible(
                commits: page.commits,
                hasMore: page.hasMore,
                query: nil
            )
            completedHistoryKey = key
            await model.cacheHistoryPage(
                page,
                worktreeID: snapshot.id,
                revision: key.revision,
                pageSize: Self.historyPageSize
            )
        } catch is CancellationError {
            return
        } catch {
            guard loadedHistoryKey == key else {
                return
            }
            completedHistoryKey = nil
            historyError = String(describing: error)
        }
    }

    private func loadMoreHistory() async {
        guard let key = loadedHistoryKey,
              key == historyLoadKey,
              hasMoreHistory,
              !isLoadingHistory,
              !isLoadingMoreHistory else {
            return
        }
        let requestedOffset = historyNextOffset
        isLoadingMoreHistory = true
        historyPaginationError = nil
        defer {
            if loadedHistoryKey == key {
                isLoadingMoreHistory = false
            }
        }
        do {
            let page = try await model.loadHistoryPage(
                worktree: snapshot.worktree,
                revision: key.revision,
                offset: requestedOffset,
                pageSize: Self.historyPageSize
            )
            try Task.checkCancellation()
            guard loadedHistoryKey == key,
                  historyNextOffset == requestedOffset else {
                return
            }
            let existingIDs = Set(commits.map(\.id))
            let appendedCommits = page.commits.filter { !existingIDs.contains($0.id) }
            let combinedCommits = commits + appendedCommits
            let graph = await extendCommitGraph(
                commitGraphLayout,
                with: appendedCommits
            )
            try Task.checkCancellation()
            guard loadedHistoryKey == key,
                  historyNextOffset == requestedOffset else {
                return
            }
            commits = combinedCommits
            commitGraphLayout = graph
            historyNextOffset = page.nextOffset
            hasMoreHistory = page.hasMore
            restoreLastContextIfPossible(
                commits: combinedCommits,
                hasMore: page.hasMore,
                query: nil
            )
            await model.cacheHistoryPage(
                GitHistoryPage(
                    commits: combinedCommits,
                    nextOffset: page.nextOffset,
                    hasMore: page.hasMore
                ),
                worktreeID: snapshot.id,
                revision: key.revision,
                pageSize: Self.historyPageSize
            )
        } catch is CancellationError {
            return
        } catch {
            guard loadedHistoryKey == key else {
                return
            }
            historyPaginationError = String(describing: error)
        }
    }

    private func restoreLastContextIfPossible(
        commits: [GitCommit],
        hasMore: Bool,
        query: GitHistorySearchQuery?
    ) {
        let expectedQuery = expectedHistoryRestorationQuery(
            requestedRestoration: requestedRestoredContext,
            activeQuery: historySearchQuery
        )
        guard expectedQuery == query else {
            return
        }
        guard let requested = requestedRestoredContext else {
            let availableIDs = Set(commits.map(\.id))
            if !selectedCommitIDSet.isSubset(of: availableIDs), !hasMore {
                selection = [.pending]
                model.reviewStates.saveLastContext(
                    .pending,
                    selectedCommitIDs: [],
                    pane: pane,
                    historyFilter: commitFilterText,
                    for: snapshot.id
                )
            }
            return
        }
        guard let restoredSelection = restoredHistorySelection(
            requested,
            commits: commits
        ) else {
            guard !hasMore else {
                return
            }
            requestedRestoredContext = nil
            selection = [.pending]
            model.reviewStates.saveLastContext(
                .pending,
                selectedCommitIDs: [],
                pane: pane,
                historyFilter: commitFilterText,
                for: snapshot.id
            )
            return
        }
        requestedHistoryScrollCommitID = historyScrollTargetID(
            selection: restoredSelection,
            commits: commits
        )
        selection = restoredSelection
        requestedRestoredContext = nil
    }

    private func loadPagesForRequestedHistoryContext() async {
        var validatedContext: ReviewNavigationState?
        while let requested = requestedRestoredContext,
              model.isApplicationActive,
              !Task.isCancelled {
            let requestedQuery = GitHistorySearchQuery(
                requested.historyFilter
            )
            if let requestedQuery {
                guard historySearchQuery == requestedQuery,
                      loadedHistorySearchKey == historySearchLoadKey,
                      hasMoreHistorySearchResults,
                      historySearchPaginationError == nil else {
                    return
                }
            } else {
                guard !isHistorySearchActive,
                      loadedHistoryKey == historyLoadKey,
                      hasMoreHistory,
                      historyPaginationError == nil else {
                    return
                }
            }
            if validatedContext != requested {
                do {
                    let isReachable = try await model.historyContainsCommits(
                        worktree: snapshot.worktree,
                        revision: snapshot.worktree.headOID,
                        commitIDs: historyRestorationCommitIDs(requested)
                    )
                    try Task.checkCancellation()
                    guard requestedRestoredContext == requested else {
                        return
                    }
                    guard isReachable else {
                        abandonRequestedHistoryContext()
                        return
                    }
                    validatedContext = requested
                } catch is CancellationError {
                    return
                } catch {
                    let message = "Unable to validate the saved History position: "
                        + String(describing: error)
                    if GitHistorySearchQuery(requested.historyFilter) == nil {
                        historyPaginationError = message
                    } else {
                        historySearchPaginationError = message
                    }
                    return
                }
            }
            if requestedQuery != nil {
                let previousOffset = historySearchNextOffset
                await loadMoreHistorySearchResults()
                guard historySearchNextOffset > previousOffset else {
                    return
                }
            } else {
                let previousOffset = historyNextOffset
                await loadMoreHistory()
                guard historyNextOffset > previousOffset else {
                    return
                }
            }
        }
    }

    private func abandonRequestedHistoryContext() {
        requestedRestoredContext = nil
        requestedHistoryScrollCommitID = nil
        selection = [.pending]
        model.reviewStates.saveLastContext(
            .pending,
            selectedCommitIDs: [],
            pane: pane,
            historyFilter: commitFilterText,
            for: snapshot.id
        )
    }

    private func updateHistorySearch(
        for key: HistorySearchLoadKey,
        debounces: Bool = true
    ) async {
        guard let query = key.query else {
            loadedHistorySearchKey = nil
            completedHistorySearchKey = nil
            searchedCommits = []
            historySearchNextOffset = 0
            hasMoreHistorySearchResults = false
            historySearchError = nil
            historySearchPaginationError = nil
            isSearchingHistory = false
            isLoadingMoreHistorySearchResults = false
            return
        }
        guard shouldLoadHistorySearch(
            requested: key,
            completed: completedHistorySearchKey
        ) else {
            return
        }

        loadedHistorySearchKey = key
        completedHistorySearchKey = nil
        searchedCommits = []
        historySearchNextOffset = 0
        hasMoreHistorySearchResults = false
        historySearchError = nil
        historySearchPaginationError = nil
        let preservesRequestedContext = requestedRestoredContext.map { requested in
            HistorySearchLoadKey(
                worktreeID: snapshot.id,
                revision: snapshot.worktree.headOID,
                query: GitHistorySearchQuery(requested.historyFilter)
            ) == key
        } ?? false
        if !preservesRequestedContext {
            requestedRestoredContext = nil
            selection = [.pending]
        }
        if let cachedPage = historySearchPageCache.page(for: key) {
            searchedCommits = cachedPage.commits
            historySearchNextOffset = cachedPage.nextOffset
            hasMoreHistorySearchResults = cachedPage.hasMore
            isSearchingHistory = false
            restoreLastContextIfPossible(
                commits: cachedPage.commits,
                hasMore: cachedPage.hasMore,
                query: key.query
            )
            completedHistorySearchKey = key
            return
        }
        isSearchingHistory = true
        defer {
            if loadedHistorySearchKey == key {
                isSearchingHistory = false
            }
        }
        do {
            if debounces {
                try await Task.sleep(for: .milliseconds(250))
            }
            try Task.checkCancellation()
            guard historySearchLoadKey == key else {
                return
            }
            let page = try await model.searchHistoryPage(
                worktree: snapshot.worktree,
                revision: key.revision,
                query: query,
                offset: 0,
                pageSize: Self.historySearchPageSize
            )
            try Task.checkCancellation()
            guard loadedHistorySearchKey == key,
                  historySearchLoadKey == key else {
                return
            }
            searchedCommits = page.commits
            historySearchNextOffset = page.nextOffset
            hasMoreHistorySearchResults = page.hasMore
            historySearchPageCache.insert(page, for: key)
            restoreLastContextIfPossible(
                commits: page.commits,
                hasMore: page.hasMore,
                query: key.query
            )
            completedHistorySearchKey = key
        } catch is CancellationError {
            return
        } catch {
            guard loadedHistorySearchKey == key else {
                return
            }
            completedHistorySearchKey = nil
            historySearchError = String(describing: error)
        }
    }

    private func loadMoreHistorySearchResults() async {
        guard let key = loadedHistorySearchKey,
              let query = key.query,
              key == historySearchLoadKey,
              hasMoreHistorySearchResults,
              !isSearchingHistory,
              !isLoadingMoreHistorySearchResults else {
            return
        }
        let requestedOffset = historySearchNextOffset
        isLoadingMoreHistorySearchResults = true
        historySearchPaginationError = nil
        defer {
            if loadedHistorySearchKey == key {
                isLoadingMoreHistorySearchResults = false
            }
        }
        do {
            let page = try await model.searchHistoryPage(
                worktree: snapshot.worktree,
                revision: key.revision,
                query: query,
                offset: requestedOffset,
                pageSize: Self.historySearchPageSize
            )
            try Task.checkCancellation()
            guard loadedHistorySearchKey == key,
                  historySearchLoadKey == key,
                  historySearchNextOffset == requestedOffset else {
                return
            }
            let existingIDs = Set(searchedCommits.map(\.id))
            searchedCommits.append(
                contentsOf: page.commits.filter { !existingIDs.contains($0.id) }
            )
            historySearchNextOffset = page.nextOffset
            hasMoreHistorySearchResults = page.hasMore
            historySearchPageCache.insert(
                GitHistoryPage(
                    commits: searchedCommits,
                    nextOffset: page.nextOffset,
                    hasMore: page.hasMore
                ),
                for: key
            )
            restoreLastContextIfPossible(
                commits: searchedCommits,
                hasMore: page.hasMore,
                query: key.query
            )
        } catch is CancellationError {
            return
        } catch {
            guard loadedHistorySearchKey == key else {
                return
            }
            historySearchPaginationError = String(describing: error)
        }
    }

    private func buildCommitGraph(for commits: [GitCommit]) async -> CommitGraphLayout {
        let task = Task.detached(priority: .userInitiated) {
            CommitGraphLayout(commits: commits)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func extendCommitGraph(
        _ layout: CommitGraphLayout,
        with commits: [GitCommit]
    ) async -> CommitGraphLayout {
        let task = Task.detached(priority: .userInitiated) {
            layout.appending(commits)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func loadContextDetails(for key: ReviewStateKey) async {
        guard acceptsReviewState(key) else {
            return
        }
        switch key.context {
        case .pending:
            isLoadingContextDetail = false
            return
        case let .commit(commitID):
            guard let commit = commit(withID: commitID) else {
                return
            }
            await loadCommitDetails(commit, key: key)
        case let .range(base, head):
            await loadRangeDetails(base: base, head: head, key: key)
        }
    }

    private func loadCommitDetails(
        _ commit: GitCommit,
        key: ReviewStateKey
    ) async {
        let context = ReviewContext.commit(commit.id)
        isLoadingContextDetail = true
        contextDetailError = nil
        contextMessage = commit.subject
        if let cached = await model.cachedHistoricalDetails(
            worktreeID: key.worktreeID,
            context: context
        ) {
            guard !Task.isCancelled, acceptsReviewState(key) else {
                return
            }
            contextMessage = cached.message
            contextChanges = cached.changes
            isLoadingContextDetail = false
            return
        }
        do {
            async let loadedMessage = model.loadCommitMessage(
                worktree: snapshot.worktree,
                commit: commit
            )
            async let loadedChanges = model.loadCommitChanges(
                worktree: snapshot.worktree,
                commit: commit
            )
            let (message, changes) = try await (loadedMessage, loadedChanges)
            try Task.checkCancellation()
            guard acceptsReviewState(key) else {
                return
            }
            contextMessage = message
            let sortedChanges = changes.sorted(by: integratedChangePrecedes)
            contextChanges = sortedChanges
            await model.cacheHistoricalDetails(
                HistoricalReviewDetails(
                    message: message,
                    changes: sortedChanges
                ),
                worktreeID: key.worktreeID,
                context: context
            )
        } catch is CancellationError {
            return
        } catch {
            guard acceptsReviewState(key) else {
                return
            }
            contextChanges = []
            contextDetailError = String(describing: error)
        }
        if acceptsReviewState(key) {
            isLoadingContextDetail = false
        }
    }

    private func loadRangeDetails(
        base: String,
        head: String,
        key: ReviewStateKey
    ) async {
        let context = ReviewContext.range(base: base, head: head)
        isLoadingContextDetail = true
        contextDetailError = nil
        contextMessage = ""
        if let cached = await model.cachedHistoricalDetails(
            worktreeID: key.worktreeID,
            context: context
        ) {
            guard !Task.isCancelled, acceptsReviewState(key) else {
                return
            }
            contextMessage = cached.message
            contextChanges = cached.changes
            isLoadingContextDetail = false
            return
        }
        do {
            let changes = try await model.loadRangeChanges(
                worktree: snapshot.worktree,
                baseOID: base,
                headOID: head
            )
            try Task.checkCancellation()
            guard acceptsReviewState(key) else {
                return
            }
            let sortedChanges = changes.sorted(by: integratedChangePrecedes)
            contextChanges = sortedChanges
            await model.cacheHistoricalDetails(
                HistoricalReviewDetails(
                    message: "",
                    changes: sortedChanges
                ),
                worktreeID: key.worktreeID,
                context: context
            )
        } catch is CancellationError {
            return
        } catch {
            guard acceptsReviewState(key) else {
                return
            }
            contextChanges = []
            contextDetailError = String(describing: error)
        }
        if acceptsReviewState(key) {
            isLoadingContextDetail = false
        }
    }

    /// 基础变更批量读取；用户展开完整文件时，再按文件读取完整上下文。
    private func loadDiffs() async {
        let requestedContext = activeContext
        let items = currentFileItems
        let requestedLoadKey = diffLoadKey
        guard completedDiffLoadKey != requestedLoadKey else {
            return
        }
        let restoredBase = restoredBaseDiffLoadKey == requestedLoadKey
            ? diffsByFileID
            : nil
        imageDiffsByFileID = [:]
        wholeFileDiffsByFileID = [:]
        loadingWholeFileIDs = []
        expandedContextDiffsByFileID = [:]
        expandedContextLineCountByFileID = [:]
        loadingContextGapIDs = []
        supplementalDiffFailures = [:]
        guard !items.isEmpty else {
            diffsByFileID = [:]
            imageDiffsByFileID = [:]
            if activeContext == .pending {
                invalidateReviewedState(using: [])
            }
            completedDiffLoadKey = requestedLoadKey
            isLoadingDiffs = false
            return
        }

        isLoadingDiffs = restoredBase == nil
        defer {
            if acceptsDiffLoad(requestedLoadKey) {
                isLoadingDiffs = false
            }
        }
        diffError = nil
        var hasLoadedBaseDiffs = restoredBase != nil || !diffsByFileID.isEmpty
        do {
            let loaded: [IntegratedFileID: GitFileDiff]
            switch activeContext {
            case .pending:
                let working = items.filter { $0.scope == .working }
                let staged = items.filter { $0.scope == .staged }
                let expectedIDs = Set(items.map(\.id))
                if let restoredBase {
                    loaded = restoredBase
                } else {
                    let cachedEntry = await model.cachedPendingDiffEntry(
                        snapshot: snapshot,
                        options: compactDiffOptions
                    )
                    var incremental = integratedDiffCache(
                        diffs: cachedEntry?.diffs ?? [],
                        items: items
                    )
                    try Task.checkCancellation()
                    guard acceptsDiffLoad(requestedLoadKey) else {
                        return
                    }
                    if !incremental.isEmpty {
                        diffsByFileID = incremental
                        hasLoadedBaseDiffs = true
                    }
                    let missingWorking = integratedItemsMissingDiff(
                        working,
                        cached: incremental
                    )
                    let missingStaged = integratedItemsMissingDiff(
                        staged,
                        cached: incremental
                    )
                    if !missingWorking.isEmpty || !missingStaged.isEmpty {
                        for try await batch in model.loadPendingDiffBatches(
                            worktree: snapshot.worktree,
                            workingChanges: missingWorking.map(\.change),
                            stagedChanges: missingStaged.map(\.change),
                            options: compactDiffOptions
                        ) {
                            try Task.checkCancellation()
                            guard acceptsDiffLoad(requestedLoadKey) else {
                                return
                            }
                            let matchingItems = batch.scope == .working
                                ? missingWorking
                                : missingStaged
                            merge(
                                diffs: batch.diffs,
                                into: &incremental,
                                items: matchingItems
                            )
                            diffsByFileID = incremental
                            hasLoadedBaseDiffs = !incremental.isEmpty
                            await model.cachePendingDiffs(
                                sortedIntegratedDiffs(incremental),
                                snapshot: snapshot,
                                options: compactDiffOptions,
                                isComplete: false
                            )
                        }
                        await model.cachePendingDiffs(
                            sortedIntegratedDiffs(incremental),
                            snapshot: snapshot,
                            options: compactDiffOptions,
                            isComplete: Set(incremental.keys) == expectedIDs
                        )
                    } else if shouldFinalizeDiffCache(
                        cachedEntry,
                        missingItemCount: missingWorking.count
                            + missingStaged.count
                    ) {
                        await model.cachePendingDiffs(
                            sortedIntegratedDiffs(incremental),
                            snapshot: snapshot,
                            options: compactDiffOptions
                        )
                    }
                    loaded = incremental
                }
            case let .commit(commitID):
                if let restoredBase {
                    loaded = restoredBase
                    break
                }
                guard let commit = commit(withID: commitID) else {
                    isLoadingDiffs = false
                    return
                }
                let cachedEntry = await model.cachedHistoricalDiffEntry(
                    worktreeID: snapshot.id,
                    context: requestedContext,
                    options: compactDiffOptions
                )
                var incremental = integratedDiffCache(
                    diffs: cachedEntry?.diffs ?? [],
                    items: items
                )
                try Task.checkCancellation()
                guard acceptsDiffLoad(requestedLoadKey) else {
                    return
                }
                if !incremental.isEmpty {
                    diffsByFileID = incremental
                    hasLoadedBaseDiffs = true
                }
                let missingItems = integratedItemsMissingDiff(
                    items,
                    cached: incremental
                )
                if !missingItems.isEmpty {
                    for try await batch in model.loadCommitDiffBatches(
                        worktree: snapshot.worktree,
                        commit: commit,
                        changes: missingItems.map(\.change),
                        options: compactDiffOptions
                    ) {
                        try Task.checkCancellation()
                        guard acceptsDiffLoad(requestedLoadKey) else {
                            return
                        }
                        merge(diffs: batch, into: &incremental, items: missingItems)
                        diffsByFileID = incremental
                        hasLoadedBaseDiffs = !incremental.isEmpty
                        await model.cacheHistoricalDiffs(
                            sortedIntegratedDiffs(incremental),
                            worktreeID: snapshot.id,
                            context: requestedContext,
                            options: compactDiffOptions,
                            isComplete: false
                        )
                    }
                    await model.cacheHistoricalDiffs(
                        sortedIntegratedDiffs(incremental),
                        worktreeID: snapshot.id,
                        context: requestedContext,
                        options: compactDiffOptions,
                        isComplete: Set(incremental.keys) == Set(items.map(\.id))
                    )
                } else if shouldFinalizeDiffCache(
                    cachedEntry,
                    missingItemCount: missingItems.count
                ) {
                    await model.cacheHistoricalDiffs(
                        sortedIntegratedDiffs(incremental),
                        worktreeID: snapshot.id,
                        context: requestedContext,
                        options: compactDiffOptions
                    )
                }
                loaded = incremental
            case let .range(base, head):
                if let restoredBase {
                    loaded = restoredBase
                    break
                }
                let cachedEntry = await model.cachedHistoricalDiffEntry(
                    worktreeID: snapshot.id,
                    context: requestedContext,
                    options: compactDiffOptions
                )
                var incremental = integratedDiffCache(
                    diffs: cachedEntry?.diffs ?? [],
                    items: items
                )
                try Task.checkCancellation()
                guard acceptsDiffLoad(requestedLoadKey) else {
                    return
                }
                if !incremental.isEmpty {
                    diffsByFileID = incremental
                    hasLoadedBaseDiffs = true
                }
                let missingItems = integratedItemsMissingDiff(
                    items,
                    cached: incremental
                )
                if !missingItems.isEmpty {
                    for try await batch in model.loadRangeDiffBatches(
                        worktree: snapshot.worktree,
                        baseOID: base,
                        headOID: head,
                        changes: missingItems.map(\.change),
                        options: compactDiffOptions
                    ) {
                        try Task.checkCancellation()
                        guard acceptsDiffLoad(requestedLoadKey) else {
                            return
                        }
                        merge(diffs: batch, into: &incremental, items: missingItems)
                        diffsByFileID = incremental
                        hasLoadedBaseDiffs = !incremental.isEmpty
                        await model.cacheHistoricalDiffs(
                            sortedIntegratedDiffs(incremental),
                            worktreeID: snapshot.id,
                            context: requestedContext,
                            options: compactDiffOptions,
                            isComplete: false
                        )
                    }
                    await model.cacheHistoricalDiffs(
                        sortedIntegratedDiffs(incremental),
                        worktreeID: snapshot.id,
                        context: requestedContext,
                        options: compactDiffOptions,
                        isComplete: Set(incremental.keys) == Set(items.map(\.id))
                    )
                } else if shouldFinalizeDiffCache(
                    cachedEntry,
                    missingItemCount: missingItems.count
                ) {
                    await model.cacheHistoricalDiffs(
                        sortedIntegratedDiffs(incremental),
                        worktreeID: snapshot.id,
                        context: requestedContext,
                        options: compactDiffOptions
                    )
                }
                loaded = incremental
            }
            try Task.checkCancellation()
            guard acceptsDiffLoad(requestedLoadKey) else {
                return
            }
            diffsByFileID = loaded
            invalidateReviewedState(using: items)
            hasLoadedBaseDiffs = true
            let loadedImageDiffs = try await loadImageDiffs(
                for: items,
                diffs: loaded,
                context: requestedContext,
                loadKey: requestedLoadKey
            )
            try Task.checkCancellation()
            guard acceptsDiffLoad(requestedLoadKey) else {
                return
            }
            imageDiffsByFileID = loadedImageDiffs
            let wholeFileItems = items.filter { item in
                showsWholeFile(item) && canLoadWholeFileContext(item)
            }
            loadingWholeFileIDs = Set(wholeFileItems.map { $0.id.stackID })
            for item in wholeFileItems {
                do {
                    let diff = try await loadWholeFileDiff(
                        for: item,
                        context: requestedContext
                    )
                    try Task.checkCancellation()
                    guard acceptsDiffLoad(requestedLoadKey) else {
                        return
                    }
                    guard diff.state == .textual else {
                        throw IntegratedReviewLoadError.contextUnavailable
                    }
                    wholeFileDiffsByFileID[item.id] = diff
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard acceptsDiffLoad(requestedLoadKey) else {
                        return
                    }
                    recordSupplementalFailure(
                        for: item,
                        operation: .wholeFile,
                        error: error
                    )
                }
                loadingWholeFileIDs.remove(item.id.stackID)
            }
            if let baseContextLineCount {
                for item in items where !showsWholeFile(item) {
                    guard let compactDiff = loaded[item.id] else {
                        continue
                    }
                    let requestedLineCount = DiffContextGapBuilder.gaps(
                        fileID: item.id.stackID,
                        compactDiff: compactDiff,
                        contextSourceDiff: nil,
                        revealedLineCountByGapID: review.revealedContextLineCountByGapID
                    ).compactMap {
                        review.revealedContextLineCountByGapID[$0.id]
                    }.max() ?? 0
                    guard requestedLineCount > 0 else {
                        continue
                    }
                    var options = compactDiffOptions
                    options.context = .lines(baseContextLineCount + requestedLineCount)
                    do {
                        let diff = try await loadFileDiff(
                            for: item,
                            context: requestedContext,
                            options: options
                        )
                        try Task.checkCancellation()
                        guard acceptsDiffLoad(requestedLoadKey) else {
                            return
                        }
                        guard diff.state == .textual else {
                            throw IntegratedReviewLoadError.contextUnavailable
                        }
                        expandedContextDiffsByFileID[item.id] = diff
                        expandedContextLineCountByFileID[item.id] = requestedLineCount
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        guard acceptsDiffLoad(requestedLoadKey) else {
                            return
                        }
                        recordSupplementalFailure(
                            for: item,
                            operation: .context(gapID: nil, lineCount: requestedLineCount),
                            error: error
                        )
                    }
                }
            }
            completedDiffLoadKey = requestedLoadKey
            restoredBaseDiffLoadKey = nil
        } catch is CancellationError {
            return
        } catch {
            guard acceptsDiffLoad(requestedLoadKey) else {
                return
            }
            if !hasLoadedBaseDiffs {
                diffsByFileID = [:]
            }
            loadingWholeFileIDs = []
            loadingContextGapIDs = []
            diffError = String(describing: error)
        }
    }

    private func loadWorkingFileAvailability(
        for key: WorkingFileAvailabilityKey
    ) async {
        let items = currentFileItems
        if activeContext == .pending {
            existingWorkingFileIDs = Set(items.compactMap { item in
                guard workingFileURL(for: item) != nil,
                      item.change.submoduleStatus == nil,
                      item.statusLabel != "D" else {
                    return nil
                }
                return item.id.stackID
            })
            return
        }
        let candidates = items.compactMap { item -> WorkingFileCandidate? in
            workingFileURL(for: item).map {
                WorkingFileCandidate(id: item.id.stackID, path: $0.path)
            }
        }
        let candidateIDs = Set(candidates.map(\.id))
        existingWorkingFileIDs.formIntersection(candidateIDs)
        let task = Task.detached(priority: .utility) {
            existingRegularFileIDs(for: candidates)
        }
        let existingIDs = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !Task.isCancelled, acceptsWorkingFileAvailabilityLoad(key) else {
            return
        }
        existingWorkingFileIDs = existingIDs
    }

    private func invalidateReviewedState(using items: [IntegratedFileItem]) {
        let currentByFileID = Dictionary(
            items.compactMap { item in
                reviewSnapshotID(for: item).map { (item.id.stackID, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        guard invalidateReviewedSnapshots(
            in: &review,
            currentByFileID: currentByFileID
        ) else {
            return
        }
        model.reviewStates.save(review, for: stateKey)
    }

    private func loadImageDiffs(
        for items: [IntegratedFileItem],
        diffs: [IntegratedFileID: GitFileDiff],
        context: ReviewContext,
        loadKey: IntegratedDiffLoadKey
    ) async throws -> [IntegratedFileID: GitImageDiff] {
        var result: [IntegratedFileID: GitImageDiff] = [:]
        for item in items {
            guard diffs[item.id]?.state == .binary,
                  GitImageDiff.supports(path: item.change.path)
                    || item.change.originalPath.map(GitImageDiff.supports(path:)) == true else {
                continue
            }
            do {
                let imageDiff = try await loadImageDiff(for: item, context: context)
                try Task.checkCancellation()
                guard acceptsDiffLoad(loadKey) else {
                    throw CancellationError()
                }
                result[item.id] = imageDiff
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard acceptsDiffLoad(loadKey) else {
                    throw CancellationError()
                }
                recordSupplementalFailure(
                    for: item,
                    operation: .image,
                    error: error
                )
            }
        }
        return result
    }

    private func loadImageDiff(
        for item: IntegratedFileItem,
        context: ReviewContext
    ) async throws -> GitImageDiff {
        switch context {
        case .pending:
            return try await model.loadImageDiff(
                worktree: snapshot.worktree,
                change: item.change,
                scope: item.scope
            )
        case let .commit(commitID):
            guard let commit = commit(withID: commitID) else {
                throw IntegratedReviewLoadError.commitUnavailable
            }
            return try await model.loadCommitImageDiff(
                worktree: snapshot.worktree,
                commit: commit,
                change: item.change
            )
        case let .range(base, head):
            return try await model.loadRangeImageDiff(
                worktree: snapshot.worktree,
                baseOID: base,
                headOID: head,
                change: item.change
            )
        }
    }

    private func retrySupplementalDiffs() async {
        let requestedLoadKey = diffLoadKey
        let requestedContext = activeContext
        let failures = currentFileItems.compactMap { item in
            supplementalDiffFailures[item.id].map { (item, $0) }
        }
        supplementalDiffFailures = [:]

        for (item, failure) in failures {
            guard acceptsDiffLoad(requestedLoadKey) else {
                return
            }
            setSupplementalLoading(
                true,
                operation: failure.operation,
                item: item
            )
            do {
                switch failure.operation {
                case .image:
                    let imageDiff = try await loadImageDiff(
                        for: item,
                        context: requestedContext
                    )
                    try Task.checkCancellation()
                    guard acceptsDiffLoad(requestedLoadKey) else {
                        return
                    }
                    imageDiffsByFileID[item.id] = imageDiff
                case .wholeFile:
                    let diff = try await loadWholeFileDiff(
                        for: item,
                        context: requestedContext
                    )
                    try Task.checkCancellation()
                    guard acceptsDiffLoad(requestedLoadKey) else {
                        return
                    }
                    guard diff.state == .textual else {
                        throw IntegratedReviewLoadError.contextUnavailable
                    }
                    wholeFileDiffsByFileID[item.id] = diff
                case let .context(gapID, lineCount):
                    guard let baseContextLineCount else {
                        throw IntegratedReviewLoadError.contextUnavailable
                    }
                    var options = compactDiffOptions
                    options.context = .lines(baseContextLineCount + lineCount)
                    let diff = try await loadFileDiff(
                        for: item,
                        context: requestedContext,
                        options: options
                    )
                    try Task.checkCancellation()
                    guard acceptsDiffLoad(requestedLoadKey) else {
                        return
                    }
                    guard diff.state == .textual else {
                        throw IntegratedReviewLoadError.contextUnavailable
                    }
                    expandedContextDiffsByFileID[item.id] = diff
                    expandedContextLineCountByFileID[item.id] = lineCount
                    if let gapID {
                        review.revealedContextLineCountByGapID[gapID] = lineCount
                        model.reviewStates.save(review, for: stateKey)
                    }
                }
            } catch is CancellationError {
                if acceptsDiffLoad(requestedLoadKey) {
                    setSupplementalLoading(
                        false,
                        operation: failure.operation,
                        item: item
                    )
                }
                return
            } catch {
                guard acceptsDiffLoad(requestedLoadKey) else {
                    return
                }
                recordSupplementalFailure(
                    for: item,
                    operation: failure.operation,
                    error: error
                )
            }
            if acceptsDiffLoad(requestedLoadKey) {
                setSupplementalLoading(
                    false,
                    operation: failure.operation,
                    item: item
                )
            }
        }
    }

    private func setSupplementalLoading(
        _ isLoading: Bool,
        operation: SupplementalDiffOperation,
        item: IntegratedFileItem
    ) {
        switch operation {
        case .image:
            break
        case .wholeFile:
            if isLoading {
                loadingWholeFileIDs.insert(item.id.stackID)
            } else {
                loadingWholeFileIDs.remove(item.id.stackID)
            }
        case let .context(gapID, _):
            guard let gapID else {
                return
            }
            if isLoading {
                loadingContextGapIDs.insert(gapID)
            } else {
                loadingContextGapIDs.remove(gapID)
            }
        }
    }

    private func recordSupplementalFailure(
        for item: IntegratedFileItem,
        operation: SupplementalDiffOperation,
        error: any Error
    ) {
        supplementalDiffFailures[item.id] = SupplementalDiffFailure(
            operation: operation,
            message: String(describing: error)
        )
    }

    private func loadWholeFileDiff(
        for item: IntegratedFileItem,
        context: ReviewContext
    ) async throws -> GitFileDiff {
        var options = model.diffOptions
        options.context = .wholeFile
        return try await loadFileDiff(for: item, context: context, options: options)
    }

    private func loadFileDiff(
        for item: IntegratedFileItem,
        context: ReviewContext,
        options: GitDiffOptions
    ) async throws -> GitFileDiff {
        switch context {
        case .pending:
            if let cached = await model.cachedPendingDiff(
                snapshot: snapshot,
                changeID: item.change.id,
                scope: item.scope,
                options: options
            ) {
                return cached
            }
            let diff = try await model.loadDiff(
                worktree: snapshot.worktree,
                change: item.change,
                scope: item.scope,
                options: options
            )
            try Task.checkCancellation()
            await model.cachePendingDiff(
                diff,
                snapshot: snapshot,
                options: options
            )
            return diff
        case let .commit(commitID):
            guard let commit = commit(withID: commitID) else {
                throw IntegratedReviewLoadError.commitUnavailable
            }
            if let cached = await model.cachedHistoricalDiff(
                worktreeID: snapshot.id,
                context: context,
                changeID: item.change.id,
                options: options
            ) {
                return cached
            }
            let diff = try await model.loadCommitDiff(
                worktree: snapshot.worktree,
                commit: commit,
                change: item.change,
                options: options
            )
            try Task.checkCancellation()
            await model.cacheHistoricalDiff(
                diff,
                worktreeID: snapshot.id,
                context: context,
                options: options
            )
            return diff
        case let .range(base, head):
            if let cached = await model.cachedHistoricalDiff(
                worktreeID: snapshot.id,
                context: context,
                changeID: item.change.id,
                options: options
            ) {
                return cached
            }
            let diff = try await model.loadRangeDiff(
                worktree: snapshot.worktree,
                baseOID: base,
                headOID: head,
                change: item.change,
                options: options
            )
            try Task.checkCancellation()
            await model.cacheHistoricalDiff(
                diff,
                worktreeID: snapshot.id,
                context: context,
                options: options
            )
            return diff
        }
    }

    private func mapped(
        diffs: [GitFileDiff],
        items: [IntegratedFileItem]
    ) -> [IntegratedFileID: GitFileDiff] {
        var result: [IntegratedFileID: GitFileDiff] = [:]
        merge(diffs: diffs, into: &result, items: items)
        return result
    }

    private func merge(
        diffs: [GitFileDiff],
        into result: inout [IntegratedFileID: GitFileDiff],
        items: [IntegratedFileItem]
    ) {
        mergeIntegratedDiffBatch(diffs: diffs, into: &result, items: items)
    }

    private static func identifier(for context: ReviewContext) -> String {
        switch context {
        case .pending: "pending"
        case let .commit(id): "commit:\(id)"
        case let .range(base, head): "range:\(base)..\(head)"
        }
    }

    /// git 的空树对象，用于把根提交也纳入 range 的 base。
    private static let emptyTreeOID = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
}

func nonEmptyDiffStackGroups(
    _ groups: [DiffStackGroup]
) -> [DiffStackGroup] {
    groups.filter { !$0.files.isEmpty }
}

// MARK: - Identity

enum IntegratedOverviewSelection: Hashable {
    case pending
    case commit(GitCommit.ID)
}

enum ReviewDocumentSelection: Hashable {
    case summary
    case file(String)
}

struct ReviewDocumentFile: Identifiable, Hashable {
    let id: String
    let title: String
    let path: String
}

func normalizedOverviewSelection(
    previous: Set<IntegratedOverviewSelection>,
    current: Set<IntegratedOverviewSelection>
) -> Set<IntegratedOverviewSelection> {
    guard !current.isEmpty else {
        return [.pending]
    }
    guard current.contains(.pending), current.count > 1 else {
        return current
    }
    if !previous.contains(.pending) {
        return [.pending]
    }
    return current.subtracting([.pending])
}

func unresolvedOverviewSelection(
    context: ReviewContext,
    selectedCommitIDs: Set<GitCommit.ID>
) -> Set<IntegratedOverviewSelection> {
    if context == .pending {
        return [.pending]
    }
    var commitIDs = selectedCommitIDs
    if commitIDs.isEmpty {
        switch context {
        case .pending:
            break
        case let .commit(commitID):
            commitIDs = [commitID]
        case let .range(_, head):
            commitIDs = [head]
        }
    }
    return Set(commitIDs.map(IntegratedOverviewSelection.commit))
}

func expectedHistoryRestorationQuery(
    requestedRestoration: ReviewNavigationState?,
    activeQuery: GitHistorySearchQuery?
) -> GitHistorySearchQuery? {
    guard let requestedRestoration else {
        return activeQuery
    }
    return GitHistorySearchQuery(requestedRestoration.historyFilter)
}

func normalizedCommitEndpointSelection(
    _ selection: Set<IntegratedOverviewSelection>,
    commits: [GitCommit]
) -> Set<IntegratedOverviewSelection> {
    guard !selection.contains(.pending) else {
        return [.pending]
    }
    let selectedCommitIDs = Set(selection.compactMap { item -> GitCommit.ID? in
        guard case let .commit(id) = item else {
            return nil
        }
        return id
    })
    guard selectedCommitIDs.count > 2 else {
        return selection
    }
    let orderedIDs = commits.compactMap { commit in
        selectedCommitIDs.contains(commit.id) ? commit.id : nil
    }
    guard let newestID = orderedIDs.first else {
        return [.pending]
    }
    guard let oldestID = orderedIDs.last, oldestID != newestID else {
        return [.commit(newestID)]
    }
    return [.commit(newestID), .commit(oldestID)]
}

struct HistoryFilterNavigationTransition: Equatable {
    let previous: ReviewNavigationState
    let current: ReviewNavigationState
    let selection: Set<IntegratedOverviewSelection>
}

func historyFilterNavigationTransition(
    previousFilter: String,
    currentFilter: String,
    selectedCommitIDs: Set<GitCommit.ID>,
    pane: ReviewPane,
    baseCommits: [GitCommit],
    searchedCommits: [GitCommit]
) -> HistoryFilterNavigationTransition? {
    guard !selectedCommitIDs.isEmpty else {
        return nil
    }
    let previousQuery = GitHistorySearchQuery(previousFilter)
    let currentQuery = GitHistorySearchQuery(currentFilter)
    let previousCommits = (previousQuery == nil ? baseCommits : searchedCommits)
        .filter { selectedCommitIDs.contains($0.id) }
    let previous = ReviewNavigationState(
        context: reviewContext(for: previousCommits),
        selectedCommitIDs: selectedCommitIDs,
        pane: pane,
        historyFilter: previousFilter
    )
    guard previous.context != .pending else {
        return nil
    }

    let candidateCommits: [GitCommit]
    if currentQuery == nil {
        candidateCommits = baseCommits
    } else if currentQuery == previousQuery {
        candidateCommits = searchedCommits
    } else {
        candidateCommits = []
    }
    let candidate = ReviewNavigationState(
        context: previous.context,
        selectedCommitIDs: selectedCommitIDs,
        pane: pane,
        historyFilter: currentFilter
    )
    if let restoredSelection = restoredHistorySelection(
        candidate,
        commits: candidateCommits
    ) {
        return HistoryFilterNavigationTransition(
            previous: previous,
            current: candidate,
            selection: restoredSelection
        )
    }
    return HistoryFilterNavigationTransition(
        previous: previous,
        current: ReviewNavigationState(
            context: .pending,
            selectedCommitIDs: [],
            pane: pane,
            historyFilter: currentFilter
        ),
        selection: [.pending]
    )
}

func reviewContext(for selectedCommits: [GitCommit]) -> ReviewContext {
    guard !selectedCommits.isEmpty else {
        return .pending
    }
    guard selectedCommits.count > 1,
          let head = selectedCommits.first,
          let oldest = selectedCommits.last else {
        return .commit(selectedCommits[0].id)
    }
    let emptyTreeOID = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    return .range(
        base: oldest.parentOIDs.first ?? emptyTreeOID,
        head: head.oid
    )
}

func effectiveReviewContext(
    requestedRestoration: ReviewNavigationState?,
    selectedCommits: [GitCommit]
) -> ReviewContext {
    requestedRestoration?.context ?? reviewContext(for: selectedCommits)
}

func restoredHistorySelection(
    _ state: ReviewNavigationState,
    commits: [GitCommit]
) -> Set<IntegratedOverviewSelection>? {
    if state.context == .pending {
        return [.pending]
    }
    let emptyTreeOID = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    var requestedIDs = state.selectedCommitIDs
    if requestedIDs.isEmpty {
        switch state.context {
        case .pending:
            return [.pending]
        case let .commit(commitID):
            requestedIDs = [commitID]
        case let .range(base, head):
            guard let oldest = commits.first(where: {
                ($0.parentOIDs.first ?? emptyTreeOID) == base
            }) else {
                return nil
            }
            requestedIDs = [head, oldest.id]
        }
    }
    if requestedIDs.count > 2 {
        requestedIDs = Set(
            normalizedCommitEndpointSelection(
                Set(requestedIDs.map(IntegratedOverviewSelection.commit)),
                commits: commits
            ).compactMap { item -> GitCommit.ID? in
                guard case let .commit(id) = item else {
                    return nil
                }
                return id
            }
        )
    }
    guard !requestedIDs.isEmpty, requestedIDs.count <= 2 else {
        return nil
    }
    let availableIDs = Set(commits.map(\.id))
    guard requestedIDs.isSubset(of: availableIDs) else {
        return nil
    }
    let restoredCommits = commits.filter { requestedIDs.contains($0.id) }
    let restoredContext = reviewContext(for: restoredCommits)
    guard restoredContext != .pending else {
        return nil
    }
    guard restoredContext == state.context else {
        return nil
    }
    return Set(requestedIDs.map(IntegratedOverviewSelection.commit))
}

func historyScrollTargetID(
    selection: Set<IntegratedOverviewSelection>,
    commits: [GitCommit]
) -> GitCommit.ID? {
    let selectedIDs = Set(selection.compactMap { item -> GitCommit.ID? in
        guard case let .commit(commitID) = item else {
            return nil
        }
        return commitID
    })
    return commits.first(where: { selectedIDs.contains($0.id) })?.id
}

func historyRestorationCommitIDs(
    _ state: ReviewNavigationState
) -> Set<GitCommit.ID> {
    if !state.selectedCommitIDs.isEmpty {
        return state.selectedCommitIDs
    }
    switch state.context {
    case .pending:
        return []
    case let .commit(commitID):
        return [commitID]
    case let .range(base, head):
        let emptyTreeOID = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        return base == emptyTreeOID ? [head] : [base, head]
    }
}

private struct HistoryLoadKey: Hashable {
    let worktreeID: GitWorktreeSnapshot.ID
    let revision: String?
}

enum RemoteOperationFeedbackOutcome: Hashable {
    case completed
    case cancelled
}

struct RemoteOperationFeedback: Hashable {
    let action: GitRemoteAction
    let outcome: RemoteOperationFeedbackOutcome

    var systemImage: String {
        switch outcome {
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    var tintColor: Color {
        switch outcome {
        case .completed: .green
        case .cancelled: .secondary
        }
    }

    var message: String {
        switch outcome {
        case .completed: "\(action.title) completed"
        case .cancelled: "\(action.title) cancelled"
        }
    }

    var compactTitle: String {
        switch outcome {
        case .completed: "\(action.title) complete"
        case .cancelled: "Cancelled"
        }
    }
}

struct RemoteOperationFeedbackView: View {
    let feedback: RemoteOperationFeedback

    var body: some View {
        Label(feedback.compactTitle, systemImage: feedback.systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(feedback.tintColor)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(feedback.tintColor.opacity(0.1), in: Capsule())
            .help(feedback.message)
            .accessibilityLabel(feedback.message)
    }
}

struct BlockingGitRefreshErrorBar: View {
    let message: String
    var isRefreshing = false
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .lineLimit(2)
                .textSelection(.enabled)
                .help(message)
            Spacer(minLength: 8)
            if isRefreshing {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Refreshing…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("blocking-refresh-progress")
            } else {
                Button("Refresh", action: refresh)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.08))
    }
}

func gitRemoteOperationUnavailableReason(
    action: GitRemoteAction = .pull,
    worktree: GitWorktree,
    branchStatus: GitBranchStatus?,
    isApplyingMutation: Bool,
    runningAction: GitRemoteAction?,
    hasUnresolvedRefreshFailure: Bool = false,
    isRefreshingRepository: Bool = false
) -> String? {
    if let runningAction {
        return "\(runningAction.title) is already in progress."
    }
    if isApplyingMutation {
        return "Wait for the current Git change operation to finish."
    }
    if hasUnresolvedRefreshFailure {
        return "Refresh repository status before running another Git operation."
    }
    if isRefreshingRepository {
        return "Wait for the repository status update to finish."
    }
    if worktree.isDetached {
        return "\(action.title) requires a checked-out branch."
    }
    if worktree.isUnborn {
        return "\(action.title) requires an initial commit."
    }
    guard let upstreamRef = branchStatus?.upstreamRef,
          !upstreamRef.isEmpty else {
        return action == .pull
            ? "Pull requires an upstream branch."
            : nil
    }
    if let branchStatus,
       branchStatus.aheadCount > 0,
       branchStatus.behindCount > 0 {
        return "Local and upstream branches have diverged. Resolve the branch before "
            + "pulling or pushing."
    }
    if action == .push, let branchStatus, branchStatus.behindCount > 0 {
        return "Pull upstream changes before pushing."
    }
    return nil
}

func gitRemoteOperationFailureMessage(
    action: GitRemoteAction,
    error: any Error
) -> String {
    let detail: String
    if let localizedError = error as? any LocalizedError,
       let errorDescription = localizedError.errorDescription,
       !errorDescription.isEmpty {
        detail = errorDescription
    } else {
        detail = String(describing: error)
    }
    let normalized = detail.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty
        ? "\(action.title) failed."
        : "\(action.title) failed: \(normalized)"
}

func gitPushActionTitle(branchStatus: GitBranchStatus?) -> String {
    guard let upstreamRef = branchStatus?.upstreamRef,
          !upstreamRef.isEmpty else {
        return "Publish"
    }
    return "Push"
}

struct HistorySearchLoadKey: Hashable {
    let worktreeID: GitWorktreeSnapshot.ID
    let revision: String?
    let query: GitHistorySearchQuery?
}

func shouldLoadHistorySearch(
    requested: HistorySearchLoadKey,
    completed: HistorySearchLoadKey?
) -> Bool {
    requested.query != nil && completed != requested
}

struct HistorySearchPageCache {
    private let maximumEntryCount: Int
    private let maximumCommitCountPerEntry: Int
    private let maximumEntryByteCount: Int
    private let maximumTotalByteCount: Int
    private var pagesByKey: [HistorySearchLoadKey: GitHistoryPage] = [:]
    private var byteCountByKey: [HistorySearchLoadKey: Int] = [:]
    private var keysByRecentUse: [HistorySearchLoadKey] = []
    private var totalByteCount = 0

    init(
        maximumEntryCount: Int = 8,
        maximumCommitCountPerEntry: Int = 2_000,
        maximumEntryByteCount: Int = 2 * 1_024 * 1_024,
        maximumTotalByteCount: Int = 8 * 1_024 * 1_024
    ) {
        self.maximumEntryCount = max(0, maximumEntryCount)
        self.maximumCommitCountPerEntry = max(0, maximumCommitCountPerEntry)
        self.maximumEntryByteCount = max(0, maximumEntryByteCount)
        self.maximumTotalByteCount = max(0, maximumTotalByteCount)
    }

    mutating func page(
        for key: HistorySearchLoadKey
    ) -> GitHistoryPage? {
        guard let page = pagesByKey[key] else {
            return nil
        }
        touch(key)
        return page
    }

    mutating func insert(
        _ page: GitHistoryPage,
        for key: HistorySearchLoadKey
    ) {
        let byteCount = Self.estimatedByteCount(page)
        guard maximumEntryCount > 0,
              page.commits.count <= maximumCommitCountPerEntry,
              byteCount <= maximumEntryByteCount else {
            removeValue(for: key)
            return
        }
        if let previousByteCount = byteCountByKey[key] {
            totalByteCount -= previousByteCount
        }
        pagesByKey[key] = page
        byteCountByKey[key] = byteCount
        totalByteCount += byteCount
        touch(key)
        while keysByRecentUse.count > maximumEntryCount
            || totalByteCount > maximumTotalByteCount {
            let removedKey = keysByRecentUse.removeFirst()
            removeValue(for: removedKey)
        }
    }

    mutating func removeAll() {
        pagesByKey = [:]
        byteCountByKey = [:]
        keysByRecentUse = []
        totalByteCount = 0
    }

    private mutating func touch(_ key: HistorySearchLoadKey) {
        keysByRecentUse.removeAll { $0 == key }
        keysByRecentUse.append(key)
    }

    private mutating func removeValue(for key: HistorySearchLoadKey) {
        pagesByKey[key] = nil
        if let byteCount = byteCountByKey.removeValue(forKey: key) {
            totalByteCount -= byteCount
        }
        keysByRecentUse.removeAll { $0 == key }
    }

    private static func estimatedByteCount(_ page: GitHistoryPage) -> Int {
        page.commits.reduce(32) { result, commit in
            result
                + 64
                + commit.oid.utf8.count
                + commit.shortOID.utf8.count
                + commit.authorName.utf8.count
                + commit.subject.utf8.count
                + commit.parentOIDs.reduce(0) { $0 + $1.utf8.count }
                + commit.refNames.reduce(0) { $0 + $1.utf8.count }
        }
    }
}

private struct HistoryPaginationTrigger: Hashable {
    let offset: Int
    let automaticallyLoads: Bool
    let hasMore: Bool
    let hasError: Bool
}

private extension GitRemoteAction {
    var title: String {
        switch self {
        case .pull: "Pull"
        case .push: "Push"
        }
    }
}

enum IntegratedFileID: Hashable {
    case pending(scope: GitDiffScope, changeID: GitFileChange.ID)
    case context(contextID: String, changeID: GitFileChange.ID)

    var stackID: String {
        switch self {
        case let .pending(scope, changeID): "pending:\(scope.rawValue):\(changeID)"
        case let .context(contextID, changeID): "\(contextID):\(changeID)"
        }
    }
}

struct IntegratedFileItem: Identifiable, Hashable {
    let id: IntegratedFileID
    let change: GitFileChange
    let scope: GitDiffScope

    var statusLabel: String {
        if change.isUntracked {
            return "U"
        }
        return String(scope == .staged ? change.indexStatus : change.worktreeStatus)
    }

    var stackStatus: DiffStackStatus {
        switch statusLabel {
        case "?": .untracked
        case "A": .added
        case "D": .deleted
        case "R", "C": .renamed
        case "U": change.isUntracked ? .untracked : .conflicted
        default: .modified
        }
    }
}

struct PendingIntegratedFileItems: Equatable {
    let working: [IntegratedFileItem]
    let untracked: [IntegratedFileItem]
    let staged: [IntegratedFileItem]

    var all: [IntegratedFileItem] {
        working + untracked + staged
    }
}

func pendingIntegratedFileItems(
    in snapshot: GitWorktreeSnapshot
) -> PendingIntegratedFileItems {
    var workingChanges: [GitFileChange] = []
    var untrackedChanges: [GitFileChange] = []
    var stagedChanges: [GitFileChange] = []
    workingChanges.reserveCapacity(snapshot.status.changes.count)
    untrackedChanges.reserveCapacity(snapshot.status.changes.count / 8)
    stagedChanges.reserveCapacity(snapshot.status.changes.count)

    for change in snapshot.status.changes {
        if change.isUnstaged {
            workingChanges.append(change)
        }
        if change.isUntracked {
            untrackedChanges.append(change)
        }
        if change.isStaged {
            stagedChanges.append(change)
        }
    }
    workingChanges.sort(by: integratedChangePrecedes)
    untrackedChanges.sort(by: integratedChangePrecedes)
    stagedChanges.sort(by: integratedChangePrecedes)

    return PendingIntegratedFileItems(
        working: integratedFileItems(workingChanges, scope: .working),
        untracked: integratedFileItems(untrackedChanges, scope: .working),
        staged: integratedFileItems(stagedChanges, scope: .staged)
    )
}

private func integratedFileItems(
    _ changes: [GitFileChange],
    scope: GitDiffScope
) -> [IntegratedFileItem] {
    changes.map { change in
        IntegratedFileItem(
            id: .pending(scope: scope, changeID: change.id),
            change: change,
            scope: scope
        )
    }
}

private func integratedChangePrecedes(
    _ lhs: GitFileChange,
    _ rhs: GitFileChange
) -> Bool {
    lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
}

indirect enum NavigatorTreeNode: Identifiable, Hashable {
    case folder(
        id: String,
        name: String,
        fileCount: Int,
        children: [NavigatorTreeNode]
    )
    case file(IntegratedFileItem)

    var id: String {
        switch self {
        case let .folder(id, _, _, _): id
        case let .file(item): "navigator-file:\(item.id.stackID)"
        }
    }
}

struct NavigatorTreeRow: Identifiable, Hashable {
    enum Content: Hashable {
        case folder(id: String, name: String, fileCount: Int)
        case file(IntegratedFileItem)
    }

    let id: String
    let depth: Int
    let content: Content
}

enum NavigatorSelection: Hashable {
    case file(String)
    case folder(String)
}

@MainActor
final class NavigatorTreeCache {
    private struct Entry {
        let items: [IntegratedFileItem]
        let nodes: [NavigatorTreeNode]
    }

    private var entriesByNamespace: [String: Entry] = [:]
    private(set) var buildCount = 0

    func nodes(
        items: [IntegratedFileItem],
        namespace: String
    ) -> [NavigatorTreeNode] {
        if let cached = entriesByNamespace[namespace],
           cached.items == items {
            return cached.nodes
        }
        let nodes = navigatorTreeNodes(
            items: items,
            namespace: namespace
        )
        entriesByNamespace[namespace] = Entry(
            items: items,
            nodes: nodes
        )
        buildCount += 1
        return nodes
    }
}

func navigatorTreeNodes(
    items: [IntegratedFileItem],
    namespace: String
) -> [NavigatorTreeNode] {
    let entries = items.map { item in
        NavigatorTreeEntry(
            components: (item.change.path as NSString).pathComponents.filter {
                !$0.isEmpty && $0 != "/" && $0 != "."
            },
            item: item
        )
    }
    return buildNavigatorTree(
        entries: entries,
        namespace: namespace,
        parentPath: ""
    )
}

func navigatorFolderIDs(in nodes: [NavigatorTreeNode]) -> Set<String> {
    nodes.reduce(into: []) { result, node in
        guard case let .folder(id, _, _, children) = node else {
            return
        }
        result.insert(id)
        result.formUnion(navigatorFolderIDs(in: children))
    }
}

func filteredNavigatorTreeNodes(
    _ nodes: [NavigatorTreeNode],
    query: String
) -> [NavigatorTreeNode] {
    guard !query.isEmpty else {
        return nodes
    }
    return nodes.compactMap { node in
        switch node {
        case let .folder(id, name, _, children):
            let filteredChildren = filteredNavigatorTreeNodes(
                children,
                query: query
            )
            guard !filteredChildren.isEmpty else {
                return nil
            }
            return .folder(
                id: id,
                name: name,
                fileCount: navigatorFileCount(in: filteredChildren),
                children: filteredChildren
            )
        case let .file(item):
            guard item.change.path.localizedCaseInsensitiveContains(query) else {
                return nil
            }
            return node
        }
    }
}

func flattenedNavigatorTreeRows(
    nodes: [NavigatorTreeNode],
    expandedFolderIDs: Set<String>
) -> [NavigatorTreeRow] {
    var rows: [NavigatorTreeRow] = []
    appendNavigatorTreeRows(
        nodes,
        depth: 0,
        expandedFolderIDs: expandedFolderIDs,
        into: &rows
    )
    return rows
}

private struct NavigatorTreeEntry {
    let components: [String]
    let item: IntegratedFileItem
}

private func buildNavigatorTree(
    entries: [NavigatorTreeEntry],
    namespace: String,
    parentPath: String
) -> [NavigatorTreeNode] {
    var files: [IntegratedFileItem] = []
    var entriesByDirectory: [String: [NavigatorTreeEntry]] = [:]
    for entry in entries {
        guard let first = entry.components.first else {
            files.append(entry.item)
            continue
        }
        guard entry.components.count > 1 else {
            files.append(entry.item)
            continue
        }
        entriesByDirectory[first, default: []].append(
            NavigatorTreeEntry(
                components: Array(entry.components.dropFirst()),
                item: entry.item
            )
        )
    }
    let folders = entriesByDirectory.keys.sorted(by: navigatorNamePrecedes).map {
        directoryName in
        let directoryPath = parentPath.isEmpty
            ? directoryName
            : "\(parentPath)/\(directoryName)"
        let children = buildNavigatorTree(
            entries: entriesByDirectory[directoryName] ?? [],
            namespace: namespace,
            parentPath: directoryPath
        )
        return NavigatorTreeNode.folder(
            id: "navigator-folder:\(namespace):\(directoryPath)",
            name: directoryName,
            fileCount: navigatorFileCount(in: children),
            children: children
        )
    }
    let fileNodes = files.sorted {
        navigatorNamePrecedes(
            ($0.change.path as NSString).lastPathComponent,
            ($1.change.path as NSString).lastPathComponent
        )
    }.map(NavigatorTreeNode.file)
    return folders + fileNodes
}

private func navigatorNamePrecedes(_ lhs: String, _ rhs: String) -> Bool {
    let lhsFolded = lhs.folding(options: [.caseInsensitive], locale: nil)
    let rhsFolded = rhs.folding(options: [.caseInsensitive], locale: nil)
    return lhsFolded == rhsFolded ? lhs < rhs : lhsFolded < rhsFolded
}

private func navigatorFileCount(in nodes: [NavigatorTreeNode]) -> Int {
    nodes.reduce(0) { count, node in
        switch node {
        case let .folder(_, _, fileCount, _): count + fileCount
        case .file: count + 1
        }
    }
}

private func appendNavigatorTreeRows(
    _ nodes: [NavigatorTreeNode],
    depth: Int,
    expandedFolderIDs: Set<String>,
    into rows: inout [NavigatorTreeRow]
) {
    for node in nodes {
        switch node {
        case let .folder(id, name, fileCount, children):
            rows.append(
                NavigatorTreeRow(
                    id: id,
                    depth: depth,
                    content: .folder(
                        id: id,
                        name: name,
                        fileCount: fileCount
                    )
                )
            )
            if expandedFolderIDs.contains(id) {
                appendNavigatorTreeRows(
                    children,
                    depth: depth + 1,
                    expandedFolderIDs: expandedFolderIDs,
                    into: &rows
                )
            }
        case let .file(item):
            rows.append(
                NavigatorTreeRow(
                    id: "navigator-file:\(item.id.stackID)",
                    depth: depth,
                    content: .file(item)
                )
            )
        }
    }
}

private struct ReviewFileExpansionSyncKey: Hashable {
    let stateKey: ReviewStateKey
    let fileIDs: Set<String>
}

struct NavigatorFileGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let items: [IntegratedFileItem]
}

func pendingNavigatorFileGroups(
    workingItems: [IntegratedFileItem],
    untrackedItems: [IntegratedFileItem],
    stagedItems: [IntegratedFileItem]
) -> [NavigatorFileGroup] {
    let groups = [
        NavigatorFileGroup(
            id: "working",
            title: "Working",
            items: workingItems + untrackedItems
        ),
        NavigatorFileGroup(
            id: "staged",
            title: "Staged",
            items: stagedItems
        )
    ]
    return groups.filter { !$0.items.isEmpty }
}

func primaryPendingMutationMode(
    context: ReviewContext,
    item: IntegratedFileItem
) -> DiffStackMutationMode? {
    guard context == .pending else {
        return nil
    }
    if item.scope == .staged {
        return .staged
    }
    if let submoduleStatus = item.change.submoduleStatus,
       !submoduleStatus.commitChanged {
        return nil
    }
    return .working
}

struct PendingFilePrimaryCommand: Equatable {
    let fileID: String
    let action: GitPendingSelectionAction
}

func diffReviewScrollTarget(
    focusedFileID: String?,
    fileFocusedFromDiffID: String?
) -> String? {
    focusedFileID == fileFocusedFromDiffID ? nil : focusedFileID
}

func pendingFilePrimaryCommand(
    context: ReviewContext,
    focusedFileID: String?,
    items: [IntegratedFileItem]
) -> PendingFilePrimaryCommand? {
    guard let focusedFileID,
          let item = items.first(where: { $0.id.stackID == focusedFileID }),
          let mutationMode = primaryPendingMutationMode(
              context: context,
              item: item
          ) else {
        return nil
    }
    return PendingFilePrimaryCommand(
        fileID: focusedFileID,
        action: mutationMode.primaryAction
    )
}

func pendingFileDiscardCommand(
    context: ReviewContext,
    focusedFileID: String?,
    items: [IntegratedFileItem]
) -> PendingFilePrimaryCommand? {
    guard context == .pending,
          let focusedFileID,
          let item = items.first(where: { $0.id.stackID == focusedFileID }),
          item.scope == .working,
          item.change.kind != .unmerged else {
        return nil
    }
    return PendingFilePrimaryCommand(
        fileID: focusedFileID,
        action: .discard
    )
}

func mergeIntegratedDiffBatch(
    diffs: [GitFileDiff],
    into result: inout [IntegratedFileID: GitFileDiff],
    items: [IntegratedFileItem]
) {
    let diffsByChangeID = Dictionary(
        diffs.map { ($0.change.id, $0) },
        uniquingKeysWith: { first, _ in first }
    )
    for item in items {
        if let diff = diffsByChangeID[item.change.id] {
            result[item.id] = diff
        }
    }
}

func completeIntegratedDiffCache(
    diffs: [GitFileDiff],
    items: [IntegratedFileItem]
) -> [IntegratedFileID: GitFileDiff]? {
    let result = integratedDiffCache(diffs: diffs, items: items)
    let expectedIDs = Set(items.map(\.id))
    guard Set(result.keys) == expectedIDs else {
        return nil
    }
    return result
}

func integratedDiffCache(
    diffs: [GitFileDiff],
    items: [IntegratedFileItem]
) -> [IntegratedFileID: GitFileDiff] {
    var result: [IntegratedFileID: GitFileDiff] = [:]
    for scope in GitDiffScope.allCases {
        mergeIntegratedDiffBatch(
            diffs: diffs.filter { $0.scope == scope },
            into: &result,
            items: items.filter { $0.scope == scope }
        )
    }
    return result
}

func sortedIntegratedDiffs(
    _ diffsByFileID: [IntegratedFileID: GitFileDiff]
) -> [GitFileDiff] {
    diffsByFileID.values.sorted { lhs, rhs in
        if lhs.scope != rhs.scope {
            return lhs.scope.rawValue < rhs.scope.rawValue
        }
        return lhs.change.id < rhs.change.id
    }
}

func integratedItemsMissingDiff(
    _ items: [IntegratedFileItem],
    cached: [IntegratedFileID: GitFileDiff]
) -> [IntegratedFileItem] {
    items.filter { cached[$0.id] == nil }
}

func shouldFinalizeDiffCache(
    _ entry: ReviewDiffCacheEntry?,
    missingItemCount: Int
) -> Bool {
    entry?.isComplete == false && missingItemCount == 0
}

struct IntegratedDiffLoadKey: Hashable {
    let worktreeID: GitWorktreeSnapshot.ID
    let activityDate: Date
    let context: ReviewContext
    let options: GitDiffOptions
    let fileIDs: [IntegratedFileID]
}

func acceptsIntegratedDiffLoad(
    currentWorktreeID: GitWorktreeSnapshot.ID,
    currentActivityDate: Date,
    currentContext: ReviewContext,
    currentOptions: GitDiffOptions,
    currentFileIDs: [IntegratedFileID],
    requested: IntegratedDiffLoadKey
) -> Bool {
    currentWorktreeID == requested.worktreeID
        && currentActivityDate == requested.activityDate
        && currentContext == requested.context
        && currentOptions == requested.options
        && currentFileIDs == requested.fileIDs
}

struct WorkingFileAvailabilityKey: Hashable {
    let worktreeID: GitWorktreeSnapshot.ID
    let activityDate: Date
    let context: ReviewContext
    let fileIDs: [IntegratedFileID]
}

func workingFileAvailabilityRequestMatches(
    currentWorktreeID: GitWorktreeSnapshot.ID,
    currentActivityDate: Date,
    currentContext: ReviewContext,
    currentFileIDs: [IntegratedFileID],
    requested: WorkingFileAvailabilityKey
) -> Bool {
    currentWorktreeID == requested.worktreeID
        && currentActivityDate == requested.activityDate
        && currentContext == requested.context
        && currentFileIDs == requested.fileIDs
}

struct WorkingFileCandidate: Sendable {
    let id: String
    let path: String
}

func existingRegularFileIDs(
    for candidates: [WorkingFileCandidate]
) -> Set<String> {
    var existingIDs: Set<String> = []
    existingIDs.reserveCapacity(candidates.count)
    for candidate in candidates {
        guard !Task.isCancelled else {
            return []
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: candidate.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue {
            existingIDs.insert(candidate.id)
        }
    }
    return existingIDs
}

private struct SupplementalDiffFailure {
    let operation: SupplementalDiffOperation
    let message: String
}

private enum SupplementalDiffOperation {
    case image
    case wholeFile
    case context(gapID: String?, lineCount: Int)
}

private enum IntegratedReviewLoadError: LocalizedError {
    case commitUnavailable
    case contextUnavailable

    var errorDescription: String? {
        switch self {
        case .commitUnavailable: "The selected commit is unavailable."
        case .contextUnavailable: "Additional context is unavailable for this file."
        }
    }
}

func clampedReviewNavigationPaneWidth(
    _ proposedWidth: CGFloat,
    totalWidth: CGFloat
) -> CGFloat {
    let minimumNavigationWidth: CGFloat = 180
    let minimumReviewWidth: CGFloat = 560
    let dividerWidth: CGFloat = 7
    let maximumNavigationWidth = max(
        minimumNavigationWidth,
        min(300, totalWidth - minimumReviewWidth - dividerWidth)
    )
    return min(
        maximumNavigationWidth,
        max(minimumNavigationWidth, proposedWidth)
    )
}

// MARK: - Components

private struct DiffCountLabel: View {
    let added: Int
    let deleted: Int

    var body: some View {
        HStack(spacing: 7) {
            Text("+\(added)")
                .foregroundStyle(Color(nsColor: AgentGitPalette.additionText))
            Text("−\(deleted)")
                .foregroundStyle(Color(nsColor: AgentGitPalette.deletionText))
        }
        .font(.caption.monospacedDigit().weight(.medium))
    }
}

private struct ReviewPaneTabBar: View {
    @Binding var selection: ReviewPane

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ReviewPane.allCases) { pane in
                Button {
                    selection = pane
                } label: {
                    Text(pane.title)
                        .font(.caption.weight(selection == pane ? .semibold : .regular))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .background(
                    selection == pane
                        ? Color(nsColor: .windowBackgroundColor)
                        : Color.clear
                )
                .accessibilityAddTraits(selection == pane ? .isSelected : [])
            }
        }
        .frame(height: 34)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct ReviewDocumentTabBar: View {
    let selection: ReviewDocumentSelection
    let files: [ReviewDocumentFile]
    let selectSummary: () -> Void
    let selectFile: (String) -> Void
    let closeFile: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: selectSummary) {
                Text("Summary")
                    .font(.caption.weight(selection == .summary ? .semibold : .regular))
                    .frame(width: 106, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(tabBackground(isSelected: selection == .summary))
            .accessibilityAddTraits(selection == .summary ? .isSelected : [])

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(files) { file in
                        let isSelected = selection == .file(file.id)
                        HStack(spacing: 0) {
                            Button {
                                selectFile(file.id)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.text")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    Text(file.title)
                                        .font(
                                            .caption.weight(
                                                isSelected ? .semibold : .regular
                                            )
                                        )
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 2)
                                }
                                .padding(.leading, 9)
                                .frame(width: 164, height: 34)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(file.title)
                            .accessibilityHint("Show file review")
                            .accessibilityAddTraits(isSelected ? .isSelected : [])

                            Button {
                                closeFile(file.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .semibold))
                                    .frame(width: 26, height: 34)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Close \(file.title)")
                        }
                        .frame(width: 190, height: 34)
                        .background(tabBackground(isSelected: isSelected))
                        .overlay(alignment: .trailing) {
                            Divider()
                        }
                        .help(file.path)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(height: 34)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func tabBackground(isSelected: Bool) -> Color {
        isSelected ? Color(nsColor: .windowBackgroundColor) : Color.clear
    }

}

private struct IntegratedFilterField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.tertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.caption)
                .focused($isFocused)
                .onExitCommand {
                    if text.isEmpty {
                        isFocused = false
                    } else {
                        text = ""
                    }
                }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Filter")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            Color(nsColor: .textBackgroundColor).opacity(0.6),
            in: RoundedRectangle(cornerRadius: 6)
        )
    }
}

struct NavigatorFilterEmptyState: View {
    let title: String
    let query: String
    let clearFilter: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "line.3.horizontal.decrease.circle")
                .font(.caption.weight(.semibold))
            Text("No result matches “\(query)”.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Button("Clear Filter", action: clearFilter)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(Color.accentColor)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }
}

func mutationRefreshFailureMessage(
    _ outcome: WorktreeRefreshOutcome
) -> String? {
    guard case let .failed(detail) = outcome else {
        return nil
    }
    return GitMutationRefreshError(detail: detail).description
}

@MainActor
func runIndependentWorktreeRefresh(
    _ operation: @escaping @MainActor () async -> WorktreeRefreshOutcome
) async -> WorktreeRefreshOutcome {
    let refreshTask = Task { @MainActor in
        await operation()
    }
    return await refreshTask.value
}

func acceptedNavigatorFileSelection(
    current: String?,
    requested: String?,
    hasVisibleFiles: Bool
) -> String? {
    requested ?? (hasVisibleFiles ? current : nil)
}

func reviewStateRequestMatches(
    currentWorktreeID: GitWorktreeSnapshot.ID?,
    currentContext: ReviewContext,
    requested: ReviewStateKey
) -> Bool {
    currentWorktreeID == requested.worktreeID
        && currentContext == requested.context
}

struct ReviewOperationRequest: Equatable {
    let worktreeID: GitWorktreeSnapshot.ID
    let sequence: UInt64
}

func reviewOperationRequestMatches(
    currentWorktreeID: GitWorktreeSnapshot.ID?,
    currentSequence: UInt64,
    requested: ReviewOperationRequest
) -> Bool {
    currentWorktreeID == requested.worktreeID
        && currentSequence == requested.sequence
}

private struct IntegratedReviewTitle: View {
    let title: String
    let subtitle: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if !message.isEmpty {
                CommitMessageSummary(message: message)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

struct CommitMessageSummary: View {
    let message: String
    @State private var showsFullMessage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
            if commitMessageNeedsFullReader(message) {
                Button("Show Full Message") {
                    showsFullMessage = true
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("commit-message-full-reader")
                .accessibilityLabel("Show Full Commit Message")
                .accessibilityHint("Opens the complete commit message")
                .popover(isPresented: $showsFullMessage, arrowEdge: .bottom) {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Commit Message")
                                .font(.headline)
                            Spacer()
                            Button("Copy") {
                                copyToPasteboard(message)
                            }
                            .controlSize(.small)
                        }
                        .padding(14)
                        Divider()
                        ScrollView {
                            Text(message)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        }
                    }
                    .frame(width: 520, height: 360)
                }
            }
        }
        .onChange(of: message) {
            showsFullMessage = false
        }
    }
}

func commitMessageNeedsFullReader(_ message: String) -> Bool {
    message.count > 240
        || message.split(separator: "\n", omittingEmptySubsequences: false).count > 3
}

private struct NavigatorFolderRow: View {
    let name: String
    let fileCount: Int
    let isExpanded: Bool

    var body: some View {
        let fileCountLabel = countedLabel(fileCount, singular: "file")
        HStack(spacing: 7) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
            Image(systemName: isExpanded ? "folder.fill" : "folder")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text("\(fileCount)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .help(name)
        .accessibilityLabel("\(name), \(fileCountLabel)")
        .accessibilityHint(isExpanded ? "Collapse folder" : "Expand folder")
    }
}

private struct NavigatorFileRow: View {
    let item: IntegratedFileItem
    let diff: GitFileDiff?
    let isReviewed: Bool
    let primaryActionTitle: String?
    let canDiscard: Bool
    var showsPathDetail = true

    var body: some View {
        HStack(spacing: 8) {
            Text(item.statusLabel)
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(statusColor)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 1) {
                fileName
                    .font(.caption)
                    .lineLimit(1)
                if showsPathDetail, !pathDetail.isEmpty {
                    Text(pathDetail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            if let diff {
                Text("+\(diff.addedLineCount)")
                    .foregroundStyle(Color(nsColor: AgentGitPalette.additionText))
                Text("−\(diff.deletedLineCount)")
                    .foregroundStyle(Color(nsColor: AgentGitPalette.deletionText))
            }
            if isReviewed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(nsColor: AgentGitPalette.statusAdded))
            }
        }
        .font(.caption2.monospacedDigit())
        .padding(.vertical, 1)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(helpText)
    }

    private var fileName: Text {
        let currentName = (item.change.path as NSString).lastPathComponent
        guard let originalPath = item.change.originalPath else {
            return Text(currentName)
        }
        let originalName = (originalPath as NSString).lastPathComponent
        guard originalName != currentName else {
            return Text(currentName)
        }
        return Text(originalName).foregroundStyle(.secondary)
            + Text(" → ").foregroundStyle(.tertiary)
            + Text(currentName)
    }

    private var pathDetail: String {
        let currentParent = (item.change.path as NSString).deletingLastPathComponent
        guard let originalPath = item.change.originalPath else {
            return currentParent
        }
        let originalParent = (originalPath as NSString).deletingLastPathComponent
        guard originalParent != currentParent else {
            return currentParent
        }
        return [originalParent, currentParent]
            .map { $0.isEmpty ? "." : $0 }
            .joined(separator: " → ")
    }

    private var statusColor: Color {
        switch item.stackStatus {
        case .added, .untracked: Color(nsColor: AgentGitPalette.statusAdded)
        case .deleted: Color(nsColor: AgentGitPalette.statusDeleted)
        case .renamed: Color(nsColor: AgentGitPalette.statusRenamed)
        case .conflicted: Color(nsColor: AgentGitPalette.statusConflicted)
        case .modified: Color(nsColor: AgentGitPalette.statusModified)
        }
    }

    private var helpText: String {
        navigatorFileHelpText(
            item: item,
            primaryActionTitle: primaryActionTitle,
            canDiscard: canDiscard
        )
    }

    private var accessibilityLabel: String {
        navigatorFileAccessibilityLabel(
            item: item,
            diff: diff,
            isReviewed: isReviewed
        )
    }
}

func navigatorFileHelpText(
    item: IntegratedFileItem,
    primaryActionTitle: String?,
    canDiscard: Bool
) -> String {
    let path = item.change.originalPath.map {
        "\($0) → \(item.change.path)"
    } ?? item.change.path
    var instructions: [String] = []
    if let primaryActionTitle {
        instructions.append(
            "Press Space to \(primaryActionTitle.lowercased()) this file."
        )
    }
    if canDiscard {
        instructions.append(
            "Press Command-Shift-Delete twice to discard this file."
        )
    }
    guard !instructions.isEmpty else {
        return path
    }
    return "\(path)\n\n\(instructions.joined(separator: " "))"
}

func navigatorFileAccessibilityLabel(
    item: IntegratedFileItem,
    diff: GitFileDiff?,
    isReviewed: Bool
) -> String {
    let path = item.change.originalPath.map {
        "\($0) renamed to \(item.change.path)"
    } ?? item.change.path
    let status: String = switch item.stackStatus {
    case .added: "added"
    case .deleted: "deleted"
    case .modified: "modified"
    case .renamed: "renamed"
    case .untracked: "untracked"
    case .conflicted: "conflicted"
    }
    var details = [path, status]
    if let diff {
        details.append(
            "\(diff.addedLineCount) additions, \(diff.deletedLineCount) deletions"
        )
    }
    if isReviewed {
        details.append("reviewed")
    }
    return details.joined(separator: ", ")
}

private struct PendingOverviewRow: View {
    let workingCount: Int
    let untrackedCount: Int
    let stagedCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.dotted.and.circle")
                .foregroundStyle(.orange)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text("Pending Changes")
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("Working \(workingCount)")
                    Text("·")
                    Text("Untracked \(untrackedCount)")
                    Text("·")
                    Text("Staged \(stagedCount)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(workingCount + untrackedCount + stagedCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            pendingOverviewAccessibilityLabel(
                workingCount: workingCount,
                untrackedCount: untrackedCount,
                stagedCount: stagedCount
            )
        )
        .accessibilityHint("Select to review pending changes")
    }
}

private struct IntegratedCommitRow: View {
    let commit: GitCommit
    let graphRow: CommitGraphRow?
    let graphLaneCount: Int
    let graphWidth: CGFloat
    let isSearchResult: Bool

    var body: some View {
        let references = commit.references
        return HStack(alignment: .center, spacing: 6) {
            if let graphRow {
                CommitGraphView(
                    row: graphRow,
                    totalLaneCount: graphLaneCount,
                    width: graphWidth
                )
            } else {
                Image(systemName: isSearchResult ? "magnifyingglass" : "circle")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: graphWidth, height: 36)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(commit.subject)
                        .lineLimit(1)
                        .layoutPriority(1)
                    ForEach(references.prefix(1)) { reference in
                        CommitReferenceBadge(reference: reference)
                    }
                    if references.count > 1 {
                        Menu {
                            ForEach(references.dropFirst()) { reference in
                                Button("Copy \(reference.label)") {
                                    copyToPasteboard(reference.fullName)
                                }
                            }
                        } label: {
                            Text("+\(references.count - 1)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help(
                            references.dropFirst().map(\.label).joined(separator: "\n")
                        )
                    }
                }
                HStack(spacing: 4) {
                    Text(commit.shortOID)
                        .font(.caption.monospaced())
                    Text("·")
                    Text(commit.authorName)
                        .lineLimit(1)
                    Text("·")
                    Text(commit.authoredAt, format: .dateTime.month().day().hour().minute())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
        .help(
            "\(commit.subject)\n\(commit.oid) · \(commit.authorName) · "
                + commit.authoredAt.formatted(
                    .dateTime.year().month().day().hour().minute()
                )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(commitRowAccessibilityLabel(commit))
        .accessibilityHint("Select to review this commit")
    }
}

func pendingOverviewAccessibilityLabel(
    workingCount: Int,
    untrackedCount: Int,
    stagedCount: Int
) -> String {
    "Pending Changes, \(workingCount) working, \(untrackedCount) untracked, "
        + "\(stagedCount) staged"
}

func commitRowAccessibilityLabel(_ commit: GitCommit) -> String {
    var details = [
        commit.subject,
        commit.shortOID,
        commit.authorName,
        commit.authoredAt.formatted(date: .abbreviated, time: .shortened)
    ]
    if !commit.references.isEmpty {
        details.append(
            "References " + commit.references.map(\.label).joined(separator: ", ")
        )
    }
    return details.joined(separator: ", ")
}

private struct CommitReferenceBadge: View {
    let reference: GitReferenceDecoration

    var body: some View {
        Text(reference.label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(reference.kind.tintColor)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 90)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(reference.kind.tintColor.opacity(0.12), in: Capsule())
            .help("\(reference.kind.title): \(reference.fullName)")
    }
}

private extension GitReferenceKind {
    var title: String {
        switch self {
        case .head: "Current Branch"
        case .localBranch: "Local Branch"
        case .tag: "Tag"
        case .remoteBranch: "Remote Branch"
        case .other: "Reference"
        }
    }

    var tintColor: Color {
        switch self {
        case .head: .green
        case .localBranch: .blue
        case .tag: .orange
        case .remoteBranch: .purple
        case .other: .secondary
        }
    }
}
