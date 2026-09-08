import AgentGitCore
import AppKit
import SwiftUI

struct IntegratedReviewWorkspace: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isReviewVisible) private var isReviewVisible

    /// 文件数不超过这个值时，新 Review 直接展开全部 diff；超过就保持折叠，避免一次铺开
    /// 上百个文件，让用户先滚过一屏文件名才看到代码。
    static let automaticFileExpansionLimit = 20

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
    @State private var contextCommitMetadata: GitCommitMetadata?
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
    /// 空表示跟随上下文默认值：看 commit 时展开，看工作区改动时没有这块。
    @State private var contextMessageExpansionOverride: Bool?
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
    @State private var hunkHistoryFilter: HunkHistoryFilter?
    @State private var hunkHistoryCommits: [GitCommit] = []
    @State private var hunkHistoryError: String?
    @State private var isLoadingHunkHistory = false
    @State private var completedHunkHistoryFilter: HunkHistoryFilter?
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
    @State private var contextDetailLoadSequence: UInt64 = 0
    @State private var completedContextDetailKey: ReviewStateKey?
    @State private var isLoadingDiffs = false
    @State private var diffLoadSequence: UInt64 = 0
    @State private var isApplyingMutation = false
    @State private var mutationSequence: UInt64 = 0
    @State private var runningRemoteAction: GitRemoteAction?
    @State private var remoteOperationFeedback: RemoteOperationFeedback?
    @State private var isCancellingRemoteOperation = false
    @State private var remoteOperationTask: Task<Void, Never>?
    @State private var remoteOperationSequence: UInt64 = 0
    @State private var remoteFeedbackDismissTask: Task<Void, Never>?
    @State private var remoteOperationError: String?
    @State private var completedWorkingFileAvailabilityKey: WorkingFileAvailabilityKey?
    @State private var restoredBaseDiffLoadKey: IntegratedDiffLoadKey?
    @State private var completedDiffLoadKey: IntegratedDiffLoadKey?
    @State private var requestedRestoredContext: ReviewNavigationState?
    @State private var requestedHistoryScrollCommitID: GitCommit.ID? = nil
    @State private var navigationHistory = ReviewNavigationHistory()
    @State private var suppressedHistoryFilterValue: String?
    @State private var fileFocusedFromDiffID: String?
    @State private var collapsedDiffGroupIDs: Set<String> = []
    @State private var diffCommandSequence: UInt64 = 0
    @State private var diffCommand: DiffStackCommand?
    @Binding private var isReviewFocused: Bool
    @State private var isHistoryVisible = true
    @State private var historyBeforeFocus = true
    @FocusState private var isCommitsNavigatorFocused: Bool
    @FocusState private var isCommitFilterFocused: Bool
    @FocusState private var isFileFilterFocused: Bool
    @FocusState private var isFilesNavigatorFocused: Bool

    init(
        snapshot: GitWorktreeSnapshot,
        startupContent: StartupReviewContent? = nil,
        initialContext: ReviewContext = .pending,
        initialSelectedCommitIDs: Set<GitCommit.ID> = [],
        initialPane: ReviewPane = .commits,
        initialHistoryFilter: String = "",
        focusMode: Binding<Bool> = .constant(false),
        initialReviewState: ReviewState = ReviewState()
    ) {
        self.snapshot = snapshot
        _isReviewFocused = focusMode
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
        _collapsedDiffGroupIDs = State(
            initialValue: initialContext == .pending ? ["staged"] : []
        )
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
                let expectedIDs = Set(items.map(\.id))
                if startupContent.pendingDiffsAreComplete,
                   Set(restored.keys) == expectedIDs {
                    _diffsByFileID = State(initialValue: restored)
                    _restoredBaseDiffLoadKey = State(initialValue: key)
                } else {
                    _diffsByFileID = State(initialValue: [:])
                    _isLoadingDiffs = State(initialValue: true)
                }
            }
        }

        if startupContent.historicalContext == initialContext,
           let historicalDetails = startupContent.historicalDetails {
            _contextMessage = State(initialValue: historicalDetails.message)
            _contextChanges = State(initialValue: historicalDetails.changes)
            _contextCommitMetadata = State(
                initialValue: historicalDetails.commitMetadata
            )
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
                let expectedIDs = Set(items.map(\.id))
                if startupContent.historicalDiffsAreComplete,
                   Set(restored.keys) == expectedIDs {
                    _diffsByFileID = State(initialValue: restored)
                    _restoredBaseDiffLoadKey = State(initialValue: key)
                } else {
                    _diffsByFileID = State(initialValue: [:])
                    _isLoadingDiffs = State(initialValue: true)
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Divider()
            if let remoteOperationError {
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
            contextCommitMetadata = nil
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
            contextMessageExpansionOverride = nil
            openReviewFileIDs = []
            collapsedDiffGroupIDs = newKey.context == .pending ? ["staged"] : []
            diffCommand = nil
        }
        .onChange(of: reviewFileExpansionSyncKey, initial: true) { _, key in
            let changedFiles = synchronizeReviewFileExpansion(
                in: &review,
                fileIDs: key.fileIDs,
                automaticExpansionLimit: Self.automaticFileExpansionLimit
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
        // 下面六个 task 在选中的 worktree / commit / diff 变化时补齐内容，不跟随窗口激活状态。
        // 下面两个翻页触发器只在前台启用；AppModel 的定时仓库刷新只在后台执行。
        .task(id: historyLoadKey) {
            await loadHistory(for: historyLoadKey)
            await loadPagesForRequestedHistoryContext()
        }
        .task(id: historySearchLoadKey) {
            await updateHistorySearch(for: historySearchLoadKey)
            await loadPagesForRequestedHistoryContext()
        }
        .task(id: hunkHistoryFilter) {
            guard let hunkHistoryFilter else {
                return
            }
            await loadHunkHistory(hunkHistoryFilter)
        }
        .task(id: contextDetailLoadKey) {
            await loadContextDetails(for: stateKey)
        }
        .task(id: diffLoadRetryKey) {
            await loadDiffs()
        }
        .task(id: workingFileAvailabilityKey) {
            await loadWorkingFileAvailability(for: workingFileAvailabilityKey)
        }
        .focusedSceneValue(
            \.reviewCommandActions,
            isReviewVisible ? ReviewCommandActions(
                navigateBack: navigateBack,
                navigateForward: navigateForward,
                canNavigateBack: canNavigateReviewBack
                    && !isAnyFilterFocused,
                canNavigateForward: navigationHistory.canNavigateForward
                    && !isAnyFilterFocused,
                selectNext: { moveFileFocus(by: 1) },
                selectPrevious: { moveFileFocus(by: -1) },
                focusFilter: focusNavigatorFilter,
                showCommits: { focusNavigator(.commits) },
                showFiles: { focusNavigator(.files) },
                navigatorDefaultActionTitle: navigatorDefaultActionTitle,
                performNavigatorDefaultAction: performNavigatorDefaultAction,
                canDiscardFocusedFile: focusedFileDiscardCommand != nil,
                requestFocusedFileDiscard: requestFocusedFileDiscard,
                collapseAllFiles: { setEntireFileListExpanded(false) },
                expandAllFiles: { setEntireFileListExpanded(true) }
            ) : nil
        )
        .onChange(of: isReviewVisible) { _, visible in
            if !visible {
                isCommitFilterFocused = false
                isFileFilterFocused = false
                isCommitsNavigatorFocused = false
                isFilesNavigatorFocused = false
            }
        }
        .onChange(of: isCommitFilterFocused) { _, focused in
            if focused { pane = .commits }
        }
        .onChange(of: isFileFilterFocused) { _, focused in
            if focused { pane = .files }
        }
        .onChange(of: isCommitsNavigatorFocused) { _, focused in
            if focused { pane = .commits }
        }
        .onChange(of: isFilesNavigatorFocused) { _, focused in
            if focused { pane = .files }
        }
        .onChange(of: isReviewFocused) { _, focused in
            if focused {
                historyBeforeFocus = isHistoryVisible
                isHistoryVisible = false
                focusNavigator(.files)
            } else {
                isHistoryVisible = historyBeforeFocus
            }
        }
    }

    private func focusNavigatorFilter() {
        if pane == .commits && isHistoryVisible {
            isCommitFilterFocused = true
        } else {
            isFileFilterFocused = true
        }
    }

    private func focusNavigator(_ target: ReviewPane) {
        pane = target
        isCommitFilterFocused = false
        isFileFilterFocused = false
        if target == .commits {
            isHistoryVisible = true
            Task { @MainActor in
                await Task.yield()
                guard pane == .commits, isHistoryVisible else { return }
                isCommitsNavigatorFocused = true
            }
        } else {
            isFilesNavigatorFocused = true
        }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 12) {
            HStack(spacing: 1) {
                Button(action: navigateBack) { Image(systemName: "chevron.left") }
                    .disabled(!canNavigateReviewBack)
                    .help("Navigate Back (⌘←)")
                    .accessibilityLabel("Navigate Back")
                Button(action: navigateForward) { Image(systemName: "chevron.right") }
                    .disabled(!navigationHistory.canNavigateForward)
                    .help("Navigate Forward (⌘→)")
                    .accessibilityLabel("Navigate Forward")
            }
            .buttonStyle(WorkspaceIconButtonStyle())
            Button {
                isHistoryVisible.toggle()
                if !isHistoryVisible { focusNavigator(.files) }
            } label: {
                Label { Text("History") } icon: { ReviewIconView(icon: .history) }
            }
            .buttonStyle(ReviewToolbarButtonStyle(kind: isHistoryVisible ? .selected : .normal))
            .help(isHistoryVisible ? "Hide commit history" : "Show commit history")
            .accessibilityLabel("Toggle Commit History")
            .accessibilityValue(isHistoryVisible ? "Shown" : "Hidden")
            Button {
                isReviewFocused.toggle()
            } label: {
                Label { Text(isReviewFocused ? "Exit Focus" : "Focus") } icon: { ReviewIconView(icon: .focus) }
            }
            .buttonStyle(ReviewToolbarButtonStyle(kind: isReviewFocused ? .selected : .normal))
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .help("Focus Review (⇧⌘F)")
            .accessibilityLabel("Toggle Review Focus")
            .accessibilityValue(isReviewFocused ? "On" : "Off")
            if let toolbarActivityLabel {
                Text(toolbarActivityLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: AgentGitPalette.sidebarMetadata))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            AgentSessionsButton(worktree: snapshot.worktree)
            Button {
                Task { await model.refreshSelectedProject() }
            } label: { ReviewIconView(icon: .refresh) }
                .buttonStyle(WorkspaceIconButtonStyle())
                .help("Refresh Current Project (⌘R)")
                .accessibilityLabel("Refresh Current Project")
            if runningRemoteAction != nil {
                Button(action: cancelRemoteOperation) { Image(systemName: "xmark.circle") }
                    .buttonStyle(WorkspaceIconButtonStyle())
                    .disabled(isCancellingRemoteOperation)
                    .accessibilityLabel("Cancel Git Operation")
            } else if let remoteOperationFeedback {
                RemoteOperationFeedbackView(feedback: remoteOperationFeedback)
            }
            HStack(spacing: 8) {
                Button { performRemoteAction(.pull) } label: {
                    Label { Text(pullActionTitle) } icon: { ReviewIconView(icon: .stage) }
                }
                .buttonStyle(ReviewToolbarButtonStyle())
                .disabled(!canRunRemoteOperation(.pull))
                .help(remoteActionHelp(.pull))
                Button { performRemoteAction(.push) } label: {
                    Label { Text(pushActionTitle) } icon: { ReviewIconView(icon: .unstage) }
                }
                .buttonStyle(ReviewToolbarButtonStyle(kind: .primary))
                .disabled(!canRunRemoteOperation(.push))
                .help(remoteActionHelp(.push))
            }
            .controlSize(.regular)
            .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color(nsColor: AgentGitPalette.card))
    }

    private var workspaceSplitView: some View {
        ReviewNativeSplitView {
            navigationPane
                .clipped()
        } review: {
            reviewPane
                .clipped()
        }
    }

    private var toolbarActivityLabel: String? {
        if let runningRemoteAction {
            return isCancellingRemoteOperation
                ? "Cancelling \(runningRemoteAction.title)…"
                : "\(runningRemoteAction.title)…"
        }
        if isRefreshingSnapshot {
            return "Updating…"
        }
        if isLoadingDiffs {
            return "Loading diff…"
        }
        return nil
    }

    // MARK: - Navigation

    private var navigationPane: some View {
        VSplitView {
            if isHistoryVisible {
                historySection.frame(minHeight: 150, idealHeight: 260)
            }
            filesSection.frame(minHeight: 140)
        }
        .background(Color(nsColor: AgentGitPalette.reviewNavigationBackground))
    }

    private var historySection: some View {
        VStack(spacing: 0) {
            NavigatorSectionHeader(title: ReviewPane.commits.title, count: nil, isFocusedSection: pane == .commits)
            IntegratedFilterField(
                placeholder: "Search commits",
                text: $commitFilterText,
                isFocused: $isCommitFilterFocused
            )
            .help("Search commit messages, authors, hashes, and references")
            .padding(.horizontal, 9)
            .padding(.bottom, 7)
            if let hunkHistoryFilter {
                HunkHistoryFilterBar(filter: hunkHistoryFilter, clear: clearHunkHistory)
            }
            commitsList
        }
    }

    private var filesSection: some View {
        VStack(spacing: 0) {
            NavigatorSectionHeader(
                title: ReviewPane.files.title,
                count: currentFileItems.isEmpty ? nil : currentFileItems.count,
                isFocusedSection: pane == .files
            )
            IntegratedFilterField(
                placeholder: "Filter files",
                text: $review.filterText,
                isFocused: $isFileFilterFocused
            )
            .help("Filter changed files by name or path")
            .padding(.horizontal, 9)
            .padding(.bottom, 7)
            filesList
        }
    }

    private var isAnyFilterFocused: Bool {
        isCommitFilterFocused || isFileFilterFocused
    }

    private var commitsList: some View {
        let graph = commitGraphLayout
        return ScrollViewReader { scrollProxy in
            List(selection: overviewSelectionBinding) {
                if !isHunkHistoryActive {
                    PendingOverviewRow(
                        workingCount: workingItems.count,
                        untrackedCount: untrackedItems.count,
                        stagedCount: stagedItems.count,
                        graphWidth: graph.displayWidth
                    )
                    .id(IntegratedOverviewSelection.pending)
                    .tag(IntegratedOverviewSelection.pending)
                    .listRowInsets(
                        EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
                    )
                }

            Group {
                if let hunkHistoryFilter {
                    if isLoadingHunkHistory, hunkHistoryCommits.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading hunk history…")
                                .foregroundStyle(.secondary)
                        }
                    } else if let hunkHistoryError {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(
                                "Unable to Load Hunk History",
                                systemImage: "exclamationmark.triangle"
                            )
                            .foregroundStyle(.red)
                            Text(hunkHistoryError)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .textSelection(.enabled)
                                .help(hunkHistoryError)
                            Button("Retry") {
                                Task {
                                    await loadHunkHistory(hunkHistoryFilter)
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }
                        .font(.caption)
                    } else if hunkHistoryCommits.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No Hunk History")
                                .font(.system(size: 12, weight: .medium))
                            Text("No earlier commit changed these lines.")
                                .foregroundStyle(.secondary)
                            Button("Show All Commits", action: clearHunkHistory)
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                        }
                        .font(.caption)
                    } else {
                        ForEach(hunkHistoryCommits) { commit in
                            IntegratedCommitRow(
                                commit: commit,
                                graphRow: nil,
                                graphLaneCount: 1,
                                graphWidth: 14,
                                isSearchResult: true
                            )
                            .id(commit.id)
                            .tag(IntegratedOverviewSelection.commit(commit.id))
                            .listRowInsets(
                                EdgeInsets(
                                    top: 0,
                                    leading: 8,
                                    bottom: 0,
                                    trailing: 8
                                )
                            )
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
                } else {
                if isHistorySearchActive {
                    Text("Search Results")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
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
                } else if !isHistorySearchActive, historyError == nil, !isHistorySettled,
                          commits.isEmpty {
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
                                .listRowInsets(
                                    EdgeInsets(
                                        top: 0,
                                        leading: 8,
                                        bottom: 0,
                                        trailing: 8
                                    )
                                )
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
            }
            .listStyle(.plain)
            .focusable()
            .focused($isCommitsNavigatorFocused)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: AgentGitPalette.reviewNavigationBackground))
            .id(snapshot.id)
            .onChange(of: selection, initial: true) { _, currentSelection in
                guard let target = overviewVisibilityTargetID(currentSelection) else {
                    return
                }
                Task { @MainActor in
                    await Task.yield()
                    scrollProxy.scrollTo(target)
                }
            }
            .task(id: snapshot.id) {
                await Task.yield()
                guard let target = overviewVisibilityTargetID(selection) else {
                    return
                }
                scrollProxy.scrollTo(target)
            }
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
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: AgentGitPalette.reviewNavigationBackground))
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
            if activeContext != .pending || !openReviewFileIDs.isEmpty {
                reviewDocumentTabBar
                Divider()
            }
            reviewToolbar
            Divider()
            if selectedReviewDocument == .summary, isContextMessageExpanded {
                contextSummaryHeader
                Divider()
            }
            reviewBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            reviewComparisonBar
        }
    }

    /// commit 的说明原来固定占着 diff 顶部，现在由比较条上的开关收放。
    @ViewBuilder
    private var contextSummaryHeader: some View {
        switch activeContext {
        case .pending:
            EmptyView()
        case let .commit(commitID):
            if let commit = commit(withID: commitID) {
                CommitSummaryHeader(
                    commit: commit,
                    metadata: contextCommitMetadata,
                    message: contextMessage.isEmpty ? commit.subject : contextMessage,
                    // 文件清单还在读时先用 commit 行里已有的文件数，否则会先显示
                    // “0 files changed”，看起来像这条 commit 什么都没改。
                    fileCount: reviewDocumentFileItems.isEmpty
                        ? (commit.changedFileCount ?? 0)
                        : reviewDocumentFileItems.count,
                    addedLineCount: totalAddedLineCount,
                    deletedLineCount: totalDeletedLineCount,
                    isLoading: isLoadingContextDetail
                )
            } else {
                reviewContextHeader
            }
        case .range:
            reviewContextHeader
        }
    }

    private var reviewToolbar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(reviewToolbarTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(countedLabel(reviewDocumentFileItems.count, singular: "file"))
                    DiffCountLabel(added: totalAddedLineCount, deleted: totalDeletedLineCount)
                    Text("·")
                    Text(activeContext == .pending ? "Working tree & index" : comparisonEndpointsLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(Color(nsColor: AgentGitPalette.sidebarMetadata))
            }
            Spacer(minLength: 4)
            ReviewLayoutControls(
                diffLayout: Binding(get: { model.diffLayout }, set: { model.diffLayout = $0 }),
                ignoresWhitespace: Binding(get: { model.diffOptions.ignoresWhitespace }, set: { model.diffOptions.ignoresWhitespace = $0 })
            )
        }
        .padding(.horizontal, 16)
        .frame(height: 62)
        .background(Color(nsColor: AgentGitPalette.card))
    }

    private var reviewToolbarTitle: String {
        if case let .file(fileID) = selectedReviewDocument,
           let item = currentFileItems.first(where: { $0.id.stackID == fileID }) {
            return (item.change.path as NSString).lastPathComponent
        }
        switch activeContext {
        case .pending: return "Uncommitted Changes"
        case .commit: return "Commit Review"
        case .range: return "Commit Range"
        }
    }

    private var reviewComparisonBar: some View {
        ViewThatFits(in: .horizontal) {
            reviewComparisonControls(compact: false)
            reviewComparisonControls(compact: true)
        }
        .buttonStyle(WorkspaceIconButtonStyle())
        .font(.system(size: 11).monospacedDigit())
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(Color(nsColor: AgentGitPalette.card))
    }

    private func reviewComparisonControls(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 9) {
            ReviewIconView(icon: reviewedFileCount == reviewDocumentFileItems.count && reviewedFileCount > 0 ? .reviewed : .review)
                .foregroundStyle(Color(nsColor: AgentGitPalette.statusAdded))
            Text("\(reviewedFileCount) / \(reviewDocumentFileItems.count) reviewed")
                .lineLimit(1)
                .help("Files reviewed in the current comparison")
            if !compact {
                ProgressView(value: Double(reviewedFileCount), total: Double(max(1, reviewDocumentFileItems.count)))
                    .progressViewStyle(.linear)
                    .tint(Color(nsColor: AgentGitPalette.statusAdded))
                    .frame(width: 44)
                    .accessibilityLabel("Review progress")
            }
            Spacer(minLength: 4)
            if isApplyingMutation || (isLoadingDiffs && !isRefreshingSnapshot) {
                ProgressView().controlSize(.small)
            }
            if contextMessageSubject != nil {
                Button {
                    contextMessageExpansionOverride = !isContextMessageExpanded
                } label: { Image(systemName: "text.bubble") }
                .help(isContextMessageExpanded ? "Hide commit message" : "Show commit message")
                .accessibilityLabel("Toggle Commit Message")
            }
            Button { setEntireFileListExpanded(false) } label: {
                Label { Text(compact ? "Collapse" : "Collapse All").fixedSize() } icon: { ReviewIconView(icon: .collapse) }
            }
            .buttonStyle(ReviewToolbarButtonStyle())
            .help("Collapse all file diffs in this review")
            .accessibilityLabel("Collapse All Files")
            .disabled(!reviewDocumentStackGroups.contains { $0.files.contains(where: \.isExpanded) })
            Button { setEntireFileListExpanded(true) } label: {
                ReviewIconView(icon: .expand)
            }
            .help("Expand all file diffs in this review")
            .accessibilityLabel("Expand All Files")
            .disabled(isEntireFileListExpanded || reviewDocumentFileItems.isEmpty)
            Divider().frame(height: 12)
            Button { moveHunk(by: -1) } label: { ReviewIconView(icon: .previous) }
                .help("Previous hunk (Shift-Tab)")
                .accessibilityLabel("Previous hunk")
                .disabled(visibleHunkCount == 0)
            if !compact {
                Text(countedLabel(visibleHunkCount, singular: "hunk"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button { moveHunk(by: 1) } label: { ReviewIconView(icon: .next) }
                .help("Next hunk (Tab)")
                .accessibilityLabel("Next hunk")
                .disabled(visibleHunkCount == 0)
        }

    }

    /// commit message 原来占着 diff 顶部一大块，现在收在比较条里按需展开。
    private var contextMessageSubject: String? {
        switch activeContext {
        case .pending:
            return nil
        case let .commit(commitID):
            // 历史还没读回来时也要有说明，否则这块会整个消失。
            let fallback = commit(withID: commitID)?.subject
                ?? "Commit \(String(commitID.prefix(7)))"
            let subject = messageSubject(fallback: fallback)
            return subject.isEmpty ? fallback : subject
        case .range:
            let subjects = selectedCommits.prefix(2).map(\.subject)
            return subjects.isEmpty ? nil : subjects.joined(separator: " · ")
        }
    }

    private var isContextMessageExpanded: Bool {
        contextMessageExpansionOverride ?? (contextMessageSubject != nil)
    }

    private var comparisonEndpointsLabel: String {
        switch activeContext {
        case .pending:
            return "working tree ⇄ HEAD"
        case let .commit(commitID):
            return "\(String(commitID.prefix(7))) ⇄ parent"
        case let .range(base, head):
            return "\(String(base.prefix(7))) ⇄ \(String(head.prefix(7)))"
        }
    }

    /// 只数当前展开的文件：收起的文件在 diff 里没有 hunk 行，导航也跳不过去，
    /// 计数必须和实际能跳的目标一致。
    private var visibleHunkCount: Int {
        guard !isPreparingReviewDiffs else {
            return 0
        }
        return reviewDocumentFileItems.reduce(0) { total, item in
            let isExpanded = selectedReviewDocument == .summary
                ? isReviewFileExpanded(item.id.stackID, in: review)
                : true
            guard isExpanded else {
                return total
            }
            return total + (diffsByFileID[item.id]?.hunks.count ?? 0)
        }
    }

    private func moveHunk(by offset: Int) {
        diffCommandSequence &+= 1
        diffCommand = DiffStackCommand(
            id: diffCommandSequence,
            action: .moveHunk(offset)
        )
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

    private var pullActionTitle: String {
        gitPullActionTitle(branchStatus: snapshot.status.branch)
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
        } else if currentFileItems.isEmpty, isContextDetailSettled {
            ContentUnavailableView {
                Label("No File Changes", systemImage: "checkmark.circle")
            } description: {
                Text(
                    activeContext == .pending
                        ? "The working tree has no staged or unstaged changes."
                        : "This commit selection contains no file changes."
                )
            }
        } else if currentFileItems.isEmpty {
            // 读文件清单是很短的一步，用整块居中的空态会让人以为这条 commit 是空的。
            // 顶部一行提示，位置和随后出现的文件列表对齐。
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading files…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Loading changed files")
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
                    // 规模、进度和 commit message 都由底部比较条承担，
                    // diff 从窗口上沿就是代码。
                    summary: nil,
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
                    loadingContextGapIDs: loadingContextGapIDs,
                    command: diffCommand,
                    onFocusFile: focusFileFromDiff,
                    onToggleFile: toggleFile,
                    onToggleGroup: toggleGroup,
                    onToggleFolder: toggleNavigatorFolder,
                    onSetAllFilesExpanded: setEntireFileListExpanded,
                    onToggleReviewed: toggleReviewed,
                    onToggleWholeFile: toggleWholeFile,
                    onShowHunkHistory: showHunkHistory,
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

    /// 这次 Review 的全部 diff 是否都已经就绪。没就绪时文件先保持收起，界面照常显示摘要和
    /// 文件列表；就绪后一次性展开，避免分批写入正在滚动的列表引起重排。
    /// 已经有 diff 时不再判定为“准备中”，否则刷新、stage 和切文件都会把已展开的内容收回去。
    private var isPreparingReviewDiffs: Bool {
        guard diffsByFileID.isEmpty else {
            return false
        }
        return !reviewDiffsAreReady(
            fileCount: currentFileItems.count,
            requested: diffLoadKey,
            completed: completedDiffLoadKey
        )
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
                DiffStackGroup(
                    id: "document",
                    title: nil,
                    emptyMessage: "No file changes",
                    isExpanded: true,
                    files: [stackFile(for: item)],
                    folders: []
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
        let files = items.map { stackFile(for: $0) }
        return DiffStackGroup(
            id: id,
            title: title,
            emptyMessage: emptyMessage,
            isExpanded: !collapsedDiffGroupIDs.contains(id),
            files: files,
            folders: []
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
            // diff 还没到齐时所有文件保持收起：这样点一条 commit 立刻就能看到摘要和文件列表，
            // 而不是整块白屏转圈；等全部 diff 就绪再一次性展开，中途不会边滚边重排。
            isExpanded: isPreparingReviewDiffs
                ? false
                : isReviewFileExpanded(item.id.stackID, in: review),
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
            isMutationEnabled: true,
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
        // 开标签不需要工作区里真的存在这个文件，删除的文件也应该能单独摊开来看，
        // 所以放在下面那道 workingFileURL 判断之前。
        if action == .openInTab {
            guard currentFileItems.contains(where: { $0.id.stackID == fileID }) else {
                return
            }
            openReviewDocument(fileID)
            return
        }
        guard let item = currentFileItems.first(where: { $0.id.stackID == fileID }),
              let fileURL = workingFileURL(for: item) else {
            return
        }
        switch action {
        case .openInTab:
            return
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

    private var selectedFilePrimaryCommand: PendingFilePrimaryCommand? {
        pendingFilePrimaryCommand(
            context: activeContext,
            focusedFileID: review.focusedFileID,
            items: currentFileItems
        )
    }

    private var focusedFilePrimaryCommand: PendingFilePrimaryCommand? {
        allowsPendingMutations ? selectedFilePrimaryCommand : nil
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

    private var currentNavigatorTreeNodes: [NavigatorTreeNode] {
        switch activeContext {
        case .pending:
            return navigatorTreeCache.nodes(
                items: workingItems + untrackedItems,
                namespace: "working"
            )
                + navigatorTreeCache.nodes(
                    items: stagedItems,
                    namespace: "staged"
                )
        case .commit, .range:
            return navigatorTreeCache.nodes(
                items: contextItems,
                namespace: "context"
            )
        }
    }

    private var currentNavigatorFolderIDs: Set<String> {
        navigatorFolderIDs(in: currentNavigatorTreeNodes)
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

    /// Review 文件清单的加载键。除了 stateKey，还要看目标 commit 是否已经进入 `commits`，
    /// 以及 AppModel 里选中的 worktree 是否已经切到当前快照：这三件事由不同的 task 各自推进，
    /// 文件清单先跑时 `loadContextDetails` 会因为取不到 commit 或 `acceptsReviewState` 不成立
    /// 直接返回。只用 stateKey 做 id 的话后面两者到位也不会重跑，Review 会停在 “Loading Files…”。
    private var contextDetailLoadKey: ContextDetailLoadKey {
        ContextDetailLoadKey(
            state: stateKey,
            isContextCommitResolved: isContextCommitResolved,
            selectedWorktreeID: model.selectedWorktreeID
        )
    }

    /// Diff 的加载键。`loadDiffs` 在目标 commit 还没进入 `commits` 时会直接返回，而 `diffLoadKey`
    /// 只看 worktree、上下文和文件列表，历史到位后不会变，于是 Review 的 diff 永远不会就绪。
    /// 把 commit 是否可解析一起放进 id，历史加载完成后再跑一次。
    private var diffLoadRetryKey: DiffLoadRetryKey {
        DiffLoadRetryKey(
            diff: diffLoadKey,
            isContextCommitResolved: isContextCommitResolved,
            selectedWorktreeID: model.selectedWorktreeID
        )
    }

    /// 当前 Review 上下文引用的 commit 是否已经能在已加载的历史里解析到。
    private var isContextCommitResolved: Bool {
        switch activeContext {
        case .pending:
            return true
        case let .commit(commitID):
            return commit(withID: commitID) != nil
        case let .range(baseID, headID):
            return commit(withID: baseID) != nil && commit(withID: headID) != nil
        }
    }

    /// 历史是否已经完成一次针对当前 worktree 的加载。用它区分“还没加载”和“加载完确实没有提交”，
    /// 避免后台切换 worktree 清空状态后停在 “No Commits Yet”。
    private var isHistorySettled: Bool {
        completedHistoryKey == historyLoadKey
    }

    /// 当前 Review 上下文的文件清单是否已经完成一次加载。
    private var isContextDetailSettled: Bool {
        completedContextDetailKey == stateKey
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

    private var isHunkHistoryActive: Bool {
        hunkHistoryFilter != nil
    }

    private var isFilteredHistoryActive: Bool {
        isHistorySearchActive || isHunkHistoryActive
    }

    private var displayedHistoryCommits: [GitCommit] {
        if isHunkHistoryActive {
            return hunkHistoryCommits
        }
        return isHistorySearchActive ? searchedCommits : commits
    }

    private var visibleCommits: [GitCommit] {
        displayedHistoryCommits
    }

    private func commit(withID id: GitCommit.ID) -> GitCommit? {
        hunkHistoryCommits.first(where: { $0.id == id })
            ?? searchedCommits.first(where: { $0.id == id })
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

    private var canNavigateReviewBack: Bool {
        hunkHistoryFilter != nil || navigationHistory.canNavigateBack
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
        if hunkHistoryFilter != nil {
            clearHunkHistory()
            return
        }
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
        if hunkHistoryFilter != nil {
            clearHunkHistory()
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
        hunkHistoryFilter = nil
        hunkHistoryCommits = []
        hunkHistoryError = nil
        isLoadingHunkHistory = false
        loadedHistorySearchKey = nil
        completedHistorySearchKey = nil
        historySearchNextOffset = 0
        hasMoreHistorySearchResults = false
        historySearchError = nil
        historySearchPaginationError = nil
        historySearchPageCache.removeAll()
        contextChanges = []
        contextMessage = ""
        contextCommitMetadata = nil
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
            if let firstFileID = firstNavigatorFileID(
                in: folderID,
                nodes: currentNavigatorTreeNodes
            ) {
                setReviewFileExpansion(
                    in: &review,
                    fileIDs: [firstFileID],
                    isExpanded: true
                )
            }
        }
        model.reviewStates.save(review, for: stateKey)
    }

    private var isEntireFileListExpanded: Bool {
        let groups = reviewDocumentStackGroups
        guard !groups.isEmpty else {
            return false
        }
        return groups.allSatisfy { group in
            group.isExpanded
                && group.files.allSatisfy(\.isExpanded)
        }
    }

    private func setEntireFileListExpanded(_ isExpanded: Bool) {
        let groups = reviewDocumentStackGroups
        let fileIDs = Set(groups.flatMap(\.files).map(\.id))

        if isExpanded {
            collapsedDiffGroupIDs.subtract(groups.map(\.id))
        }
        setReviewFileExpansion(
            in: &review,
            fileIDs: fileIDs,
            isExpanded: isExpanded
        )
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

    private func toggleGroup(_ groupID: String) {
        if collapsedDiffGroupIDs.contains(groupID) {
            collapsedDiffGroupIDs.remove(groupID)
        } else {
            collapsedDiffGroupIDs.insert(groupID)
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

    private func showHunkHistory(
        fileID: String,
        startLine: Int,
        endLine: Int
    ) {
        guard let item = currentFileItems.first(where: {
            $0.id.stackID == fileID
        }) else {
            return
        }
        if !commitFilterText.isEmpty {
            suppressedHistoryFilterValue = ""
            commitFilterText = ""
        }
        let revision: String? = switch activeContext {
        case .pending:
            snapshot.worktree.headOID
        case let .commit(commitID):
            commitID
        case let .range(_, head):
            head
        }
        pane = .commits
        isCommitFilterFocused = false
        isFileFilterFocused = false
        hunkHistoryCommits = []
        hunkHistoryError = nil
        hunkHistoryFilter = HunkHistoryFilter(
            worktreeID: snapshot.id,
            revision: revision,
            fileID: fileID,
            path: item.change.path,
            startLine: startLine,
            endLine: endLine
        )
    }

    private func clearHunkHistory() {
        hunkHistoryFilter = nil
        completedHunkHistoryFilter = nil
        hunkHistoryCommits = []
        hunkHistoryError = nil
        isLoadingHunkHistory = false
        let availableCommits = isHistorySearchActive ? searchedCommits : commits
        let availableIDs = Set(availableCommits.map(\.id))
        let retainedIDs = selectedCommitIDSet.intersection(availableIDs)
        if retainedIDs.isEmpty {
            selection = [.pending]
        } else {
            selection = normalizedCommitEndpointSelection(
                Set(retainedIDs.map(IntegratedOverviewSelection.commit)),
                commits: availableCommits
            )
        }
    }

    // MARK: - Loading

    private func loadHunkHistory(_ filter: HunkHistoryFilter) async {
        guard completedHunkHistoryFilter != filter else {
            isLoadingHunkHistory = false
            return
        }
        isLoadingHunkHistory = true
        hunkHistoryError = nil
        hunkHistoryCommits = []
        defer {
            if hunkHistoryFilter == filter {
                isLoadingHunkHistory = false
            }
        }
        do {
            let loaded = try await model.loadLineHistory(
                worktree: snapshot.worktree,
                revision: filter.revision,
                path: filter.path,
                startLine: filter.startLine,
                endLine: filter.endLine,
                limit: 2_000
            )
            try Task.checkCancellation()
            guard hunkHistoryFilter == filter else {
                return
            }
            hunkHistoryCommits = loaded
            let availableIDs = Set(loaded.map(\.id))
            let retainedIDs = selectedCommitIDSet.intersection(availableIDs)
            if !retainedIDs.isEmpty {
                selection = normalizedCommitEndpointSelection(
                    Set(retainedIDs.map(IntegratedOverviewSelection.commit)),
                    commits: loaded
                )
            } else if let first = loaded.first {
                selection = [.commit(first.id)]
            } else {
                selection = [.pending]
            }
            requestedRestoredContext = nil
            requestedHistoryScrollCommitID = historyScrollTargetID(
                selection: selection,
                commits: loaded
            )
            completedHunkHistoryFilter = filter
        } catch is CancellationError {
            return
        } catch {
            guard hunkHistoryFilter == filter else {
                return
            }
            hunkHistoryError = String(describing: error)
        }
    }

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
        guard completedContextDetailKey != key else {
            isLoadingContextDetail = false
            return
        }
        switch key.context {
        case .pending:
            isLoadingContextDetail = false
            completedContextDetailKey = key
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
        contextDetailLoadSequence &+= 1
        let loadSequence = contextDetailLoadSequence
        isLoadingContextDetail = true
        defer {
            if acceptsReviewState(key),
               contextDetailLoadSequence == loadSequence {
                isLoadingContextDetail = false
            }
        }
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
            contextCommitMetadata = cached.commitMetadata
            if cached.commitMetadata == nil {
                do {
                    let metadata = try await model.loadCommitMetadata(
                        worktree: snapshot.worktree,
                        commit: commit
                    )
                    try Task.checkCancellation()
                    guard acceptsReviewState(key) else {
                        return
                    }
                    contextCommitMetadata = metadata
                    await model.cacheHistoricalDetails(
                        HistoricalReviewDetails(
                            message: cached.message,
                            changes: cached.changes,
                            commitMetadata: metadata
                        ),
                        worktreeID: key.worktreeID,
                        context: context
                    )
                } catch is CancellationError {
                    return
                } catch {
                    contextCommitMetadata = nil
                }
            }
            guard !Task.isCancelled, acceptsReviewState(key) else {
                return
            }
            completedContextDetailKey = key
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
            async let loadedMetadata = model.loadCommitMetadata(
                worktree: snapshot.worktree,
                commit: commit
            )
            let (message, changes, metadata) = try await (
                loadedMessage,
                loadedChanges,
                loadedMetadata
            )
            try Task.checkCancellation()
            guard acceptsReviewState(key) else {
                return
            }
            contextMessage = message
            contextCommitMetadata = metadata
            let sortedChanges = changes.sorted(by: integratedChangePrecedes)
            contextChanges = sortedChanges
            await model.cacheHistoricalDetails(
                HistoricalReviewDetails(
                    message: message,
                    changes: sortedChanges,
                    commitMetadata: metadata
                ),
                worktreeID: key.worktreeID,
                context: context
            )
            guard !Task.isCancelled, acceptsReviewState(key) else {
                return
            }
            completedContextDetailKey = key
        } catch is CancellationError {
            return
        } catch {
            guard acceptsReviewState(key) else {
                return
            }
            contextChanges = []
            contextCommitMetadata = nil
            contextDetailError = String(describing: error)
        }
    }

    private func loadRangeDetails(
        base: String,
        head: String,
        key: ReviewStateKey
    ) async {
        let context = ReviewContext.range(base: base, head: head)
        contextDetailLoadSequence &+= 1
        let loadSequence = contextDetailLoadSequence
        isLoadingContextDetail = true
        defer {
            if acceptsReviewState(key),
               contextDetailLoadSequence == loadSequence {
                isLoadingContextDetail = false
            }
        }
        contextDetailError = nil
        contextMessage = ""
        contextCommitMetadata = nil
        if let cached = await model.cachedHistoricalDetails(
            worktreeID: key.worktreeID,
            context: context
        ) {
            guard !Task.isCancelled, acceptsReviewState(key) else {
                return
            }
            contextMessage = cached.message
            contextChanges = cached.changes
            contextCommitMetadata = nil
            completedContextDetailKey = key
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
            guard !Task.isCancelled, acceptsReviewState(key) else {
                return
            }
            completedContextDetailKey = key
        } catch is CancellationError {
            return
        } catch {
            guard acceptsReviewState(key) else {
                return
            }
            contextChanges = []
            contextDetailError = String(describing: error)
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
        diffLoadSequence &+= 1
        let loadSequence = diffLoadSequence
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
            if acceptsDiffLoad(requestedLoadKey),
               diffLoadSequence == loadSequence {
                isLoadingDiffs = false
            }
        }
        diffError = nil
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
            if acceptsDiffLoad(requestedLoadKey),
               diffLoadSequence == loadSequence {
                loadingWholeFileIDs = []
                loadingContextGapIDs = []
            }
            return
        } catch {
            guard acceptsDiffLoad(requestedLoadKey) else {
                return
            }
            diffsByFileID = [:]
            loadingWholeFileIDs = []
            loadingContextGapIDs = []
            diffError = String(describing: error)
        }
    }

    private func loadWorkingFileAvailability(
        for key: WorkingFileAvailabilityKey
    ) async {
        guard completedWorkingFileAvailabilityKey != key else {
            return
        }
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
            completedWorkingFileAvailabilityKey = key
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
        completedWorkingFileAvailabilityKey = key
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

func overviewVisibilityTargetID(
    _ selection: Set<IntegratedOverviewSelection>
) -> AnyHashable? {
    guard selection.count == 1, let item = selection.first else {
        return nil
    }
    switch item {
    case .pending:
        return AnyHashable(IntegratedOverviewSelection.pending)
    case let .commit(commitID):
        return AnyHashable(commitID)
    }
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

struct HunkHistoryFilter: Hashable {
    let worktreeID: GitWorktreeSnapshot.ID
    let revision: String?
    let fileID: String
    let path: String
    let startLine: Int
    let endLine: Int

    var lineLabel: String {
        startLine == endLine
            ? "line \(startLine)"
            : "lines \(startLine)–\(endLine)"
    }
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
    guard let aheadCount = branchStatus?.aheadCount, aheadCount > 0 else {
        return "Push"
    }
    return "Push \(aheadCount)"
}

/// 落后的提交数直接写在按钮上。之前只有把鼠标停在箭头上才知道要不要 pull。
func gitPullActionTitle(branchStatus: GitBranchStatus?) -> String {
    guard let behindCount = branchStatus?.behindCount, behindCount > 0 else {
        return "Pull"
    }
    return "Pull \(behindCount)"
}

/// 按钮上有数字时才显示文字；没有领先或落后时保持纯图标，工具栏不会一直被撑宽。
func gitRemoteActionShowsTitle(_ title: String) -> Bool {
    title.contains(where: \.isNumber) || title == "Publish"
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

func firstNavigatorFileID(
    in folderID: String,
    nodes: [NavigatorTreeNode]
) -> String? {
    for node in nodes {
        guard case let .folder(id, _, _, children) = node else {
            continue
        }
        if id == folderID {
            return firstNavigatorFileID(in: children)
        }
        if let nested = firstNavigatorFileID(in: folderID, nodes: children) {
            return nested
        }
    }
    return nil
}

private func firstNavigatorFileID(
    in nodes: [NavigatorTreeNode]
) -> String? {
    for node in nodes {
        switch node {
        case let .file(item):
            return item.id.stackID
        case let .folder(_, _, _, children):
            if let nested = firstNavigatorFileID(in: children) {
                return nested
            }
        }
    }
    return nil
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

func reviewDiffsAreReady(
    fileCount: Int,
    requested: IntegratedDiffLoadKey,
    completed: IntegratedDiffLoadKey?
) -> Bool {
    fileCount == 0 || completed == requested
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

struct RemoteActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .labelStyleForRemoteAction(showsTitle: gitRemoteActionShowsTitle(title))
        .accessibilityLabel(title)
    }
}

private extension View {
    @ViewBuilder
    func labelStyleForRemoteAction(showsTitle: Bool) -> some View {
        if showsTitle {
            labelStyle(.titleAndIcon)
        } else {
            labelStyle(.iconOnly)
        }
    }
}

struct DiffLoadRetryKey: Hashable {
    let diff: IntegratedDiffLoadKey
    let isContextCommitResolved: Bool
    let selectedWorktreeID: GitWorktreeSnapshot.ID?
}

struct ContextDetailLoadKey: Hashable {
    let state: ReviewStateKey
    let isContextCommitResolved: Bool
    let selectedWorktreeID: GitWorktreeSnapshot.ID?
}

enum ReviewSplitLayoutMetrics {
    static let widthDefaultsKey = "agentgit.review-navigation-width.v2"
    static let minimumNavigationWidth: CGFloat = 200
    static let idealNavigationWidth: CGFloat = 290
    static let maximumNavigationWidth: CGFloat = 520
    static let minimumReviewWidth: CGFloat = 490

    static func clampedNavigationWidth(
        _ proposedWidth: CGFloat,
        totalWidth: CGFloat,
        dividerThickness: CGFloat
    ) -> CGFloat {
        let availableMaximum = totalWidth
            - minimumReviewWidth
            - dividerThickness
        let maximum = max(
            minimumNavigationWidth,
            min(maximumNavigationWidth, availableMaximum)
        )
        return min(maximum, max(minimumNavigationWidth, proposedWidth))
    }
}

private struct ReviewSplitDefaultsSuiteKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var reviewSplitDefaultsSuiteName: String? {
        get { self[ReviewSplitDefaultsSuiteKey.self] }
        set { self[ReviewSplitDefaultsSuiteKey.self] = newValue }
    }
}

struct ReviewNativeSplitView<Navigation: View, Review: View>:
    NSViewControllerRepresentable {
    @Environment(\.reviewSplitDefaultsSuiteName) private var defaultsSuiteName
    let navigation: Navigation
    let review: Review

    init(
        @ViewBuilder navigation: () -> Navigation,
        @ViewBuilder review: () -> Review
    ) {
        self.navigation = navigation()
        self.review = review()
    }

    func makeNSViewController(context: Context) -> ReviewSplitViewController {
        let defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:))
            ?? .standard
        return ReviewSplitViewController(
            defaults: defaults,
            navigation: AnyView(navigation),
            review: AnyView(review)
        )
    }

    func updateNSViewController(
        _ controller: ReviewSplitViewController,
        context: Context
    ) {
        controller.update(
            navigation: AnyView(navigation),
            review: AnyView(review)
        )
    }
}

@MainActor
final class ReviewSplitViewController: NSViewController, NSSplitViewDelegate {
    let managedSplitView = NSSplitView()
    private let navigationController: NSHostingController<AnyView>
    private let reviewController: NSHostingController<AnyView>
    private let defaults: UserDefaults
    private var hasAppliedInitialWidth = false
    private var isApplyingPersistedWidth = false
    private var pendingPersistedWidth: CGFloat?
    private var persistTimer: Timer?

    init(
        defaults: UserDefaults,
        navigation: AnyView,
        review: AnyView
    ) {
        self.defaults = defaults
        navigationController = NSHostingController(rootView: navigation)
        reviewController = NSHostingController(rootView: review)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        managedSplitView.isVertical = true
        managedSplitView.dividerStyle = .thin
        managedSplitView.delegate = self
        managedSplitView.arrangesAllSubviews = true
        managedSplitView.identifier = NSUserInterfaceItemIdentifier(
            "AgentGitReviewSplitView"
        )
        view = managedSplitView

        addChild(navigationController)
        addChild(reviewController)
        navigationController.view.frame = NSRect(
            x: 0,
            y: 0,
            width: ReviewSplitLayoutMetrics.idealNavigationWidth,
            height: 600
        )
        reviewController.view.frame = NSRect(
            x: ReviewSplitLayoutMetrics.idealNavigationWidth + 1,
            y: 0,
            width: ReviewSplitLayoutMetrics.minimumReviewWidth,
            height: 600
        )
        managedSplitView.addArrangedSubview(navigationController.view)
        managedSplitView.addArrangedSubview(reviewController.view)
        managedSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        managedSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(splitViewDidResizeSubviews),
            name: NSSplitView.didResizeSubviewsNotification,
            object: managedSplitView
        )
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !hasAppliedInitialWidth,
              managedSplitView.bounds.width
                >= ReviewSplitLayoutMetrics.minimumNavigationWidth
                    + managedSplitView.dividerThickness,
              managedSplitView.subviews.count >= 2 else {
            return
        }
        hasAppliedInitialWidth = true
        let savedWidth = CGFloat(
            defaults.double(forKey: ReviewSplitLayoutMetrics.widthDefaultsKey)
        )
        let preferredWidth = savedWidth > 0
            ? savedWidth
            : ReviewSplitLayoutMetrics.idealNavigationWidth
        let width = ReviewSplitLayoutMetrics.clampedNavigationWidth(
            preferredWidth,
            totalWidth: managedSplitView.bounds.width,
            dividerThickness: managedSplitView.dividerThickness
        )
        isApplyingPersistedWidth = true
        managedSplitView.setPosition(width, ofDividerAt: 0)
        isApplyingPersistedWidth = false
    }

    func update(navigation: AnyView, review: AnyView) {
        navigationController.rootView = navigation
        reviewController.rootView = review
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard dividerIndex == 0 else {
            return proposedMinimumPosition
        }
        return max(
            ReviewSplitLayoutMetrics.minimumNavigationWidth,
            proposedMinimumPosition
        )
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard dividerIndex == 0 else {
            return proposedMaximumPosition
        }
        return min(
            ReviewSplitLayoutMetrics.clampedNavigationWidth(
                proposedMaximumPosition,
                totalWidth: splitView.bounds.width,
                dividerThickness: splitView.dividerThickness
            ),
            proposedMaximumPosition
        )
    }

    func splitView(
        _ splitView: NSSplitView,
        shouldAdjustSizeOfSubview view: NSView
    ) -> Bool {
        view === reviewController.view
    }

    func splitView(
        _ splitView: NSSplitView,
        effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        guard dividerIndex == 0 else {
            return proposedEffectiveRect
        }
        return drawnRect.insetBy(dx: -3, dy: 0)
    }

    @objc func splitViewDidResizeSubviews(_ notification: Notification) {
        guard hasAppliedInitialWidth,
              !isApplyingPersistedWidth,
              managedSplitView.subviews.count >= 2 else {
            return
        }
        let width = managedSplitView.subviews[0].frame.width
        guard width >= ReviewSplitLayoutMetrics.minimumNavigationWidth - 1 else {
            return
        }
        pendingPersistedWidth = width
        persistTimer?.invalidate()
        let timer = Timer(
            timeInterval: 0.18,
            target: self,
            selector: #selector(persistPendingWidth),
            userInfo: nil,
            repeats: false
        )
        persistTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func persistPendingWidth() {
        persistTimer?.invalidate()
        persistTimer = nil
        guard let pendingPersistedWidth else {
            return
        }
        self.pendingPersistedWidth = nil
        defaults.set(
            Double(pendingPersistedWidth),
            forKey: ReviewSplitLayoutMetrics.widthDefaultsKey
        )
    }
}

// MARK: - Components

struct HunkHistoryFilterBar: View {
    let filter: HunkHistoryFilter
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
            Text(filter.path)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("·")
                .foregroundStyle(.tertiary)
            Text(filter.lineLabel)
                .foregroundStyle(.secondary)
                .fixedSize()
            Spacer(minLength: 2)
            Button(action: clear) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close Hunk History")
            .accessibilityLabel("Close Hunk History")
        }
        .font(.system(size: 12, weight: .regular))
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(Color(nsColor: AgentGitPalette.reviewNavigationBackground))
        .help("Hunk History: \(filter.path), \(filter.lineLabel)")
    }
}

struct DiffCountLabel: View {
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

/// 段头只说明这一段是什么、有多少条，焦点段用强调色的小圆点标出来。
struct NavigatorSectionHeader: View {
    let title: String
    let count: Int?
    let isFocusedSection: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: title == ReviewPane.commits.title ? "clock.arrow.circlepath" : "folder")
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            if let count {
                Text(count.formatted())
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if isFocusedSection {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 38)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            count.map { "\(title), \($0) items" } ?? title
        )
    }
}

private struct ReviewLayoutControls: View {
    @Binding var diffLayout: DiffLayoutMode
    @Binding var ignoresWhitespace: Bool
    @State private var isDisplayHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Toggle("Ignore Whitespace Changes", isOn: $ignoresWhitespace)
            } label: {
                Label { Text("Display") } icon: { ReviewIconView(icon: .display) }
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(Color(nsColor: isDisplayHovered ? AgentGitPalette.reviewHover : AgentGitPalette.card), in: RoundedRectangle(cornerRadius: 7))
                    .overlay { RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: AgentGitPalette.reviewControlBorder), lineWidth: 0.7) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .onHover { isDisplayHovered = $0 }
            .foregroundStyle(ignoresWhitespace ? Color.accentColor : Color.primary)
            .help(ignoresWhitespace ? "Display options — whitespace changes hidden" : "Display options — all whitespace changes shown")
            .accessibilityLabel("Diff Display Options")
            .accessibilityValue(ignoresWhitespace ? "Ignoring whitespace" : "Showing whitespace")

            HStack(spacing: 2) {
                ForEach(DiffLayoutMode.allCases) { mode in
                    Button { diffLayout = mode } label: {
                        Label { Text(mode.title) } icon: {
                            ReviewIconView(icon: mode == .sideBySide ? .split : .unified)
                        }
                    }
                    .buttonStyle(ReviewToolbarButtonStyle(kind: diffLayout == mode ? .selected : .normal))
                    .accessibilityLabel(mode.title)
                    .accessibilityAddTraits(diffLayout == mode ? .isSelected : [])
                    .help("Show \(mode.title.lowercased()) diff")
                }
            }
            .padding(2)
            .background(Color(nsColor: AgentGitPalette.inputBackground), in: RoundedRectangle(cornerRadius: 9))
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Diff Layout")
        }
        .font(.system(size: 11.5, weight: .medium))
    }
}

private struct ReviewDocumentTabBar: View {
    let selection: ReviewDocumentSelection
    let files: [ReviewDocumentFile]
    let selectSummary: () -> Void
    let selectFile: (String) -> Void
    let closeFile: (String) -> Void
    @State private var hoveredFileID: String?

    var body: some View {
        HStack(spacing: 0) {
            Button(action: selectSummary) {
                Text("Summary")
                    .font(.system(size: 12, weight: .regular))
                    .frame(width: 100, height: 32)
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
                        let tabWidth = documentTabWidth(file.title)
                        HStack(spacing: 0) {
                            Button {
                                selectFile(file.id)
                            } label: {
                                HStack(spacing: 6) {
                                    Text(file.title)
                                        .font(.system(size: 12, weight: .regular))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 2)
                                }
                                .padding(.leading, 9)
                                .frame(width: tabWidth - 24, height: 32)
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
                                    .frame(width: 24, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .opacity(
                                isSelected || hoveredFileID == file.id ? 1 : 0
                            )
                            .accessibilityLabel("Close \(file.title)")
                        }
                        .frame(width: tabWidth, height: 32)
                        .background(tabBackground(isSelected: isSelected))
                        .overlay(alignment: .trailing) {
                            Divider()
                        }
                        .help(file.path)
                        .onHover { isHovered in
                            if isHovered {
                                hoveredFileID = file.id
                            } else if hoveredFileID == file.id {
                                hoveredFileID = nil
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 8)
        }
        .frame(height: 32)
        .background(Color(nsColor: AgentGitPalette.reviewTabBarBackground))
    }

    private func tabBackground(isSelected: Bool) -> Color {
        isSelected ? Color(nsColor: AgentGitPalette.canvas) : Color.clear
    }

    private func documentTabWidth(_ title: String) -> CGFloat {
        let textWidth = (title as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 12)]
        ).width
        return min(190, max(100, ceil(textWidth) + 48))
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
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
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
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Color(nsColor: AgentGitPalette.inputBackground),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
        }
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
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: AgentGitPalette.canvas),
                    Color.accentColor.opacity(0.025)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.accentColor)
                .frame(width: 3)
                .padding(.vertical, 10)
                .padding(.leading, 6)
        }
    }
}

struct CommitSummaryHeader: View {
    let commit: GitCommit
    let metadata: GitCommitMetadata?
    let message: String
    let fileCount: Int
    let addedLineCount: Int
    let deletedLineCount: Int
    let isLoading: Bool
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(commit.oid.prefix(9)))
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Color(nsColor: AgentGitPalette.commitCountBackground),
                        in: RoundedRectangle(cornerRadius: 3)
                    )
                    .fixedSize()
                Text(authorDescription)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                Text(commitSummaryTimestamp(commit.authoredAt))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Spacer(minLength: 8)
                statsBadges
                    .fixedSize()
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Color(nsColor: AgentGitPalette.codeText))

            HStack(spacing: 5) {
                ForEach(commit.references.prefix(3)) { reference in
                    CommitReferenceBadge(reference: reference)
                }
                if commit.references.count > 3 {
                    Text("+\(commit.references.count - 3)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    showsDetails.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: showsDetails ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text("Details")
                    }
                    .font(.system(size: 10.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("commit-summary-details-toggle")
                .accessibilityLabel(
                    showsDetails ? "Hide Commit Details" : "Show Commit Details"
                )
            }

            if showsDetails {
                Grid(alignment: .leading, horizontalSpacing: 9, verticalSpacing: 2) {
                    metadataRow("Commit Hash") {
                        Text(commit.oid)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    metadataRow("Tree") {
                        Text(metadata?.treeOID ?? (isLoading ? "Loading…" : "Unavailable"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    metadataRow("Parents") {
                        Text(
                            commit.parentOIDs.isEmpty
                                ? "—"
                                : commit.parentOIDs.map { String($0.prefix(8)) }
                                    .joined(separator: ", ")
                        )
                        .textSelection(.enabled)
                    }
                }
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Color(nsColor: AgentGitPalette.codeText))
            }

            if !message.isEmpty {
                CommitMessageSummary(message: message)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: commit.id) {
            showsDetails = false
        }
    }

    private var statsBadges: some View {
        HStack(spacing: 6) {
            Text(countedLabel(fileCount, singular: "file") + " changed")
                .foregroundStyle(.secondary)
            Text("−\(deletedLineCount)")
                .foregroundStyle(Color(nsColor: AgentGitPalette.codeText))
                .padding(.horizontal, 4)
                .background(
                    Color(nsColor: AgentGitPalette.deletionBackground),
                    in: RoundedRectangle(cornerRadius: 2)
                )
            Text("+\(addedLineCount)")
                .foregroundStyle(Color(nsColor: AgentGitPalette.codeText))
                .padding(.horizontal, 4)
                .background(
                    Color(nsColor: AgentGitPalette.additionBackground),
                    in: RoundedRectangle(cornerRadius: 2)
                )
        }
        .monospacedDigit()
    }

    private var authorDescription: String {
        guard let email = metadata?.authorEmail, !email.isEmpty else {
            return commit.authorName
        }
        return "\(commit.authorName) <\(email)>"
    }

    private func metadataRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GridRow {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CommitMessageSummary: View {
    let message: String
    @State private var showsFullMessage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            formattedMessage
                .lineLimit(8)
                .lineSpacing(2)
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
                    .scaledFontPresentation(width: 520, height: 360)
                }
            }
        }
        .onChange(of: message) {
            showsFullMessage = false
        }
    }

    private var formattedMessage: Text {
        let lines = message.split(
            separator: "\n",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let subject = String(lines.first ?? "")
        let subjectText = Text(subject)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(nsColor: AgentGitPalette.commitPrimaryText))
        guard lines.count > 1 else {
            return subjectText
        }
        return subjectText
            + Text("\n" + String(lines[1]))
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color(nsColor: AgentGitPalette.commitSecondaryText))
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
                .font(.callout.weight(.medium))
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
                    .font(.callout)
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

struct PendingOverviewRow: View {
    let workingCount: Int
    let untrackedCount: Int
    let stagedCount: Int
    let graphWidth: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            PendingCommitGraphMarker(width: graphWidth)
            VStack(alignment: .leading, spacing: 3) {
                Text(totalCount == 0 ? "No Changes" : "Pending Changes")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Group {
                    if totalCount == 0 {
                        Text("Working tree clean")
                    } else {
                        HStack(spacing: 6) {
                            Text("Working \(workingCount)")
                            if untrackedCount > 0 {
                                Text("·")
                                Text("Untracked \(untrackedCount)")
                            }
                            Text("·")
                            Text("Staged \(stagedCount)")
                        }
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: CommitGraphMetrics.rowHeight)
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

    private var totalCount: Int {
        workingCount + untrackedCount + stagedCount
    }
}

private struct PendingCommitGraphMarker: View {
    let width: CGFloat

    var body: some View {
        Canvas { context, size in
            let x = min(CommitGraphMetrics.horizontalPadding, size.width / 2)
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(
                path,
                with: .color(Color(nsColor: AgentGitPalette.statusRenamed)),
                style: StrokeStyle(lineWidth: 1.2, dash: [2, 2])
            )
            let node = CGRect(x: x - 4, y: size.height / 2 - 4, width: 8, height: 8)
            context.fill(
                Path(roundedRect: node, cornerRadius: 2),
                with: .color(Color(nsColor: AgentGitPalette.statusRenamed))
            )
        }
        .frame(width: width, height: CommitGraphMetrics.rowHeight)
        .accessibilityHidden(true)
    }
}

struct IntegratedCommitRow: View {
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
                    .frame(width: graphWidth, height: CommitGraphMetrics.rowHeight)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(commit.subject)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let changedFileCount = commit.changedFileCount,
                       changedFileCount > 0 {
                        Text("\(changedFileCount)")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                Color(nsColor: AgentGitPalette.commitCountBackground),
                                in: RoundedRectangle(cornerRadius: 2)
                            )
                            .fixedSize()
                            .layoutPriority(2)
                    }
                }
                HStack(spacing: 4) {
                    Text(commit.authorName)
                        .lineLimit(1)
                        .layoutPriority(0)
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
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(
                                    .quaternary,
                                    in: RoundedRectangle(cornerRadius: 2)
                                )
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help(
                            references.dropFirst().map(\.label).joined(separator: "\n")
                        )
                    }
                    Spacer(minLength: 2)
                    Text(commitListTimestamp(commit.authoredAt))
                        .fixedSize()
                        .layoutPriority(2)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: CommitGraphMetrics.rowHeight)
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

func commitListTimestamp(
    _ date: Date,
    relativeTo now: Date = Date(),
    calendar: Calendar = .current
) -> String {
    if calendar.isDate(date, inSameDayAs: now) {
        return CommitListDateFormatting.time.string(from: date)
    }
    let days = calendar.dateComponents(
        [.day],
        from: calendar.startOfDay(for: date),
        to: calendar.startOfDay(for: now)
    ).day ?? 0
    if (0...6).contains(days) {
        return CommitListDateFormatting.weekdayAndTime.string(from: date)
    }
    if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
        return CommitListDateFormatting.monthDay.string(from: date)
    }
    return CommitListDateFormatting.yearMonthDay.string(from: date)
}

func commitSummaryTimestamp(_ date: Date) -> String {
    CommitListDateFormatting.summary.string(from: date)
}

private enum CommitListDateFormatting {
    static let time = formatter("HH:mm")
    static let weekdayAndTime = formatter("EEE, HH:mm")
    static let monthDay = formatter("MMM d")
    static let yearMonthDay = formatter("yyyy MMM d")
    static let summary = formatter("yyyy, MMM d, EEE, HH:mm")

    private static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = template
        return formatter
    }
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
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: badgeWidth, alignment: .leading)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(reference.kind.tintColor)
                    .frame(width: 2)
                    .padding(.vertical, 2)
            }
            .layoutPriority(1)
            .help("\(reference.kind.title): \(reference.fullName)")
    }

    private var badgeWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 11, weight: .regular)
        let textWidth = (reference.label as NSString).size(
            withAttributes: [.font: font]
        ).width
        return min(168, max(24, ceil(textWidth)))
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
        case .head: Color(nsColor: AgentGitPalette.commitEdge0)
        case .localBranch: .blue
        case .tag: .orange
        case .remoteBranch: .purple
        case .other: .secondary
        }
    }
}
