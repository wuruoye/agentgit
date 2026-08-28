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
    @State private var review = ReviewState()
    @State private var commitFilterText = ""
    @State private var historyError: String?
    @State private var historyPaginationError: String?
    @State private var loadedHistoryKey: HistoryLoadKey?
    @State private var completedHistoryKey: HistoryLoadKey?
    @State private var historyNextOffset = 0
    @State private var hasMoreHistory = false
    @State private var searchedCommits: [GitCommit] = []
    @State private var loadedHistorySearchKey: HistorySearchLoadKey?
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
    @FocusState private var isFilterFocused: Bool

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
        _review = State(initialValue: initialReviewState)
        _pane = State(initialValue: initialPane)
        _commitFilterText = State(initialValue: initialHistoryFilter)
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
            let items = Self.pendingItems(
                in: snapshot,
                scope: .working,
                matching: { $0.isUnstaged }
            ) + Self.pendingItems(
                in: snapshot,
                scope: .working,
                matching: { $0.isUntracked }
            ) + Self.pendingItems(
                in: snapshot,
                scope: .staged,
                matching: { $0.isStaged }
            )
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
                HSplitView {
                    navigationPane
                        .frame(minWidth: 200, idealWidth: 240, maxWidth: 300)
                    reviewPane
                        .frame(minWidth: 590, maxWidth: .infinity, maxHeight: .infinity)
                }
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
        }
        .onChange(of: review.filterText) {
            if let focused = review.focusedFileID,
               !visibleFileItems.contains(where: { $0.id.stackID == focused }) {
                focusFileFromNavigator(visibleFileItems.first?.id.stackID)
            }
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
                showFiles: { pane = .files }
            )
        )
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
            Picker("Navigator", selection: $pane) {
                ForEach(ReviewPane.allCases) { pane in
                    Text(pane.title).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

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
        List(selection: focusBinding) {
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
                            workingItems: filtered(workingItems),
                            untrackedItems: filtered(untrackedItems),
                            stagedItems: filtered(stagedItems)
                        )
                    ) { group in
                        Section(group.title) {
                            navigatorFileRows(group.items)
                        }
                    }
                case .commit, .range:
                    navigatorFileRows(filtered(contextItems))
                }
            }
        }
        .listStyle(.sidebar)
        .onKeyPress(.space) {
            performFocusedFilePrimaryAction() ? .handled : .ignored
        }
    }

    @ViewBuilder
    private func navigatorFileRows(
        _ items: [IntegratedFileItem]
    ) -> some View {
        ForEach(items) { item in
            let mutationMode = primaryPendingMutationMode(
                context: activeContext,
                item: item
            )
            NavigatorFileRow(
                item: item,
                diff: diffsByFileID[item.id],
                isReviewed: isReviewed(item),
                primaryActionTitle: mutationMode?.fileActionTitle
            )
                .tag(item.id.stackID)
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

    /// Files 只负责定位：选中即滚动到 Review 流里的那个文件。
    private var focusBinding: Binding<String?> {
        Binding(
            get: { review.focusedFileID },
            set: { requestedFileID in
                let fileID = acceptedNavigatorFileSelection(
                    current: review.focusedFileID,
                    requested: requestedFileID,
                    hasVisibleFiles: !visibleFileItems.isEmpty
                )
                focusFileFromNavigator(fileID)
            }
        )
    }

    private var reviewScrollTarget: String? {
        diffReviewScrollTarget(
            focusedFileID: review.focusedFileID,
            fileFocusedFromDiffID: fileFocusedFromDiffID
        )
    }

    private func focusFileFromNavigator(_ fileID: String?) {
        fileFocusedFromDiffID = nil
        updateFocusedFile(fileID)
    }

    private func focusFileFromDiff(_ fileID: String) {
        fileFocusedFromDiffID = fileID
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
            reviewContextHeader
            Divider()
            reviewToolbar
            Divider()
            reviewBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
            Text(countedLabel(visibleFileItems.count, singular: "file"))
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
        .padding(.horizontal, 14)
        .frame(height: 34)
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
            }
        } else if visibleFileItems.isEmpty {
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
                    groups: stackGroups,
                    layout: model.diffLayout,
                    scrollTarget: reviewScrollTarget,
                    scrollKey: stateKey,
                    scrollStore: model.reviewStates,
                    isApplicationActive: model.isApplicationActive,
                    loadingMessage: isRefreshingSnapshot
                        ? "Waiting for repository update…"
                        : "Loading diff…",
                    mutationActionsEnabled: allowsPendingMutations,
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
        BlockingGitRefreshErrorBar(message: message) {
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
                    title: "Files",
                    emptyMessage: emptyMessage("No file changes", "No matching files"),
                    items: filtered(contextItems)
                )
            ]
        }
        return nonEmptyDiffStackGroups(groups)
    }

    private func emptyMessage(_ empty: String, _ filteredAway: String) -> String {
        review.filterText.isEmpty ? empty : filteredAway
    }

    private func stackGroup(
        id: String,
        title: String,
        emptyMessage: String,
        items: [IntegratedFileItem]
    ) -> DiffStackGroup {
        DiffStackGroup(
            id: id,
            title: title,
            emptyMessage: emptyMessage,
            isExpanded: items.contains { !review.collapsedFileIDs.contains($0.id.stackID) },
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
            isExpanded: !review.collapsedFileIDs.contains(item.id.stackID),
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

    private func performFocusedFilePrimaryAction() -> Bool {
        guard allowsPendingMutations,
              let command = pendingFilePrimaryCommand(
                  context: activeContext,
                  focusedFileID: review.focusedFileID,
                  items: currentFileItems
              ) else {
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
                errorMessage = "\(action.title) did not complete locally: \(error)"
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
        reviewContext(for: selectedCommits)
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
        pendingItems(scope: .working) { $0.isUnstaged }
    }

    private var untrackedItems: [IntegratedFileItem] {
        pendingItems(scope: .working) { $0.isUntracked }
    }

    private var stagedItems: [IntegratedFileItem] {
        pendingItems(scope: .staged) { $0.isStaged }
    }

    private func pendingItems(
        scope: GitDiffScope,
        matching predicate: (GitFileChange) -> Bool
    ) -> [IntegratedFileItem] {
        Self.pendingItems(
            in: snapshot,
            scope: scope,
            matching: predicate
        )
    }

    private static func pendingItems(
        in snapshot: GitWorktreeSnapshot,
        scope: GitDiffScope,
        matching predicate: (GitFileChange) -> Bool
    ) -> [IntegratedFileItem] {
        snapshot.status.changes
            .filter(predicate)
            .sorted(by: compareChanges)
            .map { change in
                IntegratedFileItem(
                    id: .pending(scope: scope, changeID: change.id),
                    change: change,
                    scope: scope
                )
            }
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
        visibleFileItems.reduce(0) { $0 + (diffsByFileID[$1.id]?.addedLineCount ?? 0) }
    }

    private var totalDeletedLineCount: Int {
        visibleFileItems.reduce(0) { $0 + (diffsByFileID[$1.id]?.deletedLineCount ?? 0) }
    }

    private var reviewedFileCount: Int {
        visibleFileItems.count(where: isReviewed)
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
            return Self.pendingItems(
                in: snapshot,
                scope: .working,
                matching: { $0.isUnstaged }
            ).map(\.id) + Self.pendingItems(
                in: snapshot,
                scope: .working,
                matching: { $0.isUntracked }
            ).map(\.id) + Self.pendingItems(
                in: snapshot,
                scope: .staged,
                matching: { $0.isStaged }
            ).map(\.id)
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
            requestedRestoredContext = nil
            requestedHistoryScrollCommitID = historyScrollTargetID(
                selection: restoredSelection,
                commits: availableCommits
            )
            selection = restoredSelection
        } else {
            selection = [.pending]
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
    }

    private func toggleFile(_ stackID: String) {
        if review.collapsedFileIDs.contains(stackID) {
            review.collapsedFileIDs.remove(stackID)
        } else {
            review.collapsedFileIDs.insert(stackID)
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
        setCollapsed(items.contains { !review.collapsedFileIDs.contains($0.id.stackID) }, for: items)
    }

    private func groupItems(id: String) -> [IntegratedFileItem] {
        switch id {
        case "working": filtered(workingItems + untrackedItems)
        case "staged": filtered(stagedItems)
        case "context": filtered(contextItems)
        default: []
        }
    }

    private func setCollapsed(_ isCollapsed: Bool, for items: [IntegratedFileItem]) {
        let ids = items.map(\.id.stackID)
        if isCollapsed {
            review.collapsedFileIDs.formUnion(ids)
        } else {
            review.collapsedFileIDs.subtract(ids)
        }
        model.reviewStates.save(review, for: stateKey)
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
                hasMore: cachedPage.hasMore
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
                hasMore: page.hasMore
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
                hasMore: page.hasMore
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
        hasMore: Bool
    ) {
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
        requestedRestoredContext = nil
        requestedHistoryScrollCommitID = historyScrollTargetID(
            selection: restoredSelection,
            commits: commits
        )
        selection = restoredSelection
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
            searchedCommits = []
            historySearchNextOffset = 0
            hasMoreHistorySearchResults = false
            historySearchError = nil
            historySearchPaginationError = nil
            isSearchingHistory = false
            isLoadingMoreHistorySearchResults = false
            return
        }

        loadedHistorySearchKey = key
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
        }
        selection = [.pending]
        if let cachedPage = historySearchPageCache.page(for: key) {
            searchedCommits = cachedPage.commits
            historySearchNextOffset = cachedPage.nextOffset
            hasMoreHistorySearchResults = cachedPage.hasMore
            isSearchingHistory = false
            restoreLastContextIfPossible(
                commits: cachedPage.commits,
                hasMore: cachedPage.hasMore
            )
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
                hasMore: page.hasMore
            )
        } catch is CancellationError {
            return
        } catch {
            guard loadedHistorySearchKey == key else {
                return
            }
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
                hasMore: page.hasMore
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
            let sortedChanges = changes.sorted(by: Self.compareChanges)
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
            let sortedChanges = changes.sorted(by: Self.compareChanges)
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

    private static func compareChanges(_ lhs: GitFileChange, _ rhs: GitFileChange) -> Bool {
        lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
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
        case .cancelled: "\(action.title) cancellation requested"
        }
    }

    var compactTitle: String {
        switch outcome {
        case .completed: "\(action.title) complete"
        case .cancelled: "Cancel requested"
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
            Button("Refresh", action: refresh)
                .buttonStyle(.borderless)
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
    if action == .pull, let upstreamError = branchStatus?.upstreamError {
        return upstreamError
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
    return nil
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

// MARK: - Components

private struct DiffCountLabel: View {
    let added: Int
    let deleted: Int

    var body: some View {
        HStack(spacing: 7) {
            Text("+\(added)")
                .foregroundStyle(.green)
            Text("−\(deleted)")
                .foregroundStyle(.red)
        }
        .font(.caption.monospacedDigit().weight(.medium))
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
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

private struct NavigatorFileRow: View {
    let item: IntegratedFileItem
    let diff: GitFileDiff?
    let isReviewed: Bool
    let primaryActionTitle: String?

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
                if !pathDetail.isEmpty {
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
                    .foregroundStyle(.green)
                Text("−\(diff.deletedLineCount)")
                    .foregroundStyle(.red)
            }
            if isReviewed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .font(.caption2.monospacedDigit())
        .padding(.vertical, 1)
        .help(helpText)
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
        case .added, .untracked: .green
        case .deleted: .red
        case .renamed: .blue
        case .conflicted: .purple
        case .modified: .orange
        }
    }

    private var helpText: String {
        let path = item.change.originalPath.map {
            "\($0) → \(item.change.path)"
        } ?? item.change.path
        guard let primaryActionTitle else {
            return path
        }
        return "\(path)\n\nPress Space to \(primaryActionTitle.lowercased()) this file."
    }
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
        .help(commit.subject)
    }
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
