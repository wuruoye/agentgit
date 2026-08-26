import AgentGitCore
import AppKit
import SwiftUI

struct IntegratedReviewWorkspace: View {
    @Environment(AppModel.self) private var model

    let snapshot: GitWorktreeSnapshot

    @State private var commits: [GitCommit] = []
    @State private var selection: Set<IntegratedOverviewSelection> = [.pending]
    @State private var contextChanges: [GitFileChange] = []
    @State private var contextMessage = ""
    @State private var diffsByFileID: [IntegratedFileID: GitFileDiff] = [:]
    @State private var pane: ReviewPane = .commits
    @State private var review = ReviewState()
    @State private var commitFilterText = ""
    @State private var historyError: String?
    @State private var contextDetailError: String?
    @State private var diffError: String?
    @State private var isLoadingHistory = false
    @State private var isLoadingContextDetail = false
    @State private var isLoadingDiffs = false
    @State private var isApplyingMutation = false

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Divider()

            if let statusError = snapshot.errorMessage {
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
                        .frame(minWidth: 230, idealWidth: 260, maxWidth: 320)
                    reviewPane
                        .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onChange(of: snapshot.id, initial: true) {
            resetWorkspace()
        }
        .onChange(of: stateKey) { previousKey, newKey in
            model.reviewStates.save(review, for: previousKey)
            review = model.reviewStates.state(for: newKey)
            contextChanges = []
            contextMessage = ""
            diffsByFileID = [:]
            contextDetailError = nil
            diffError = nil
        }
        .onChange(of: review.filterText) {
            if let focused = review.focusedFileID,
               !visibleFileItems.contains(where: { $0.id.stackID == focused }) {
                review.focusedFileID = visibleFileItems.first?.id.stackID
            }
        }
        .task(id: snapshot.id) {
            await loadHistory()
        }
        .task(id: activeContext) {
            await loadContextDetails()
        }
        .task(id: diffLoadKey) {
            await loadDiffs()
        }
        .background {
            FileNavigationShortcuts(
                selectNext: { moveFileFocus(by: 1) },
                selectPrevious: { moveFileFocus(by: -1) }
            )
        }
    }

    // MARK: - Header

    private var workspaceHeader: some View {
        HStack(spacing: 16) {
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

            if let branch = snapshot.status.branch, !branch.isSynced {
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
            }

            if !snapshot.diffStat.isEmpty {
                DiffCountLabel(
                    added: snapshot.diffStat.addedLineCount,
                    deleted: snapshot.diffStat.deletedLineCount
                )
            }
        }
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
                placeholder: pane == .commits ? "Filter commits" : "Filter files",
                text: pane == .commits ? $commitFilterText : $review.filterText
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
        List(selection: $selection) {
            PendingOverviewRow(
                workingCount: workingItems.count,
                untrackedCount: untrackedItems.count,
                stagedCount: stagedItems.count
            )
            .tag(IntegratedOverviewSelection.pending)

            Section("History") {
                if isLoadingHistory, commits.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading commits…")
                            .foregroundStyle(.secondary)
                    }
                } else if let historyError {
                    Label(historyError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                } else if visibleCommits.isEmpty {
                    Text(commitFilterText.isEmpty ? "No Commits Yet" : "No Matching Commits")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleCommits) { commit in
                        IntegratedCommitRow(commit: commit)
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
            }
        }
        .listStyle(.sidebar)
    }

    private var filesList: some View {
        List(selection: focusBinding) {
            if visibleFileItems.isEmpty {
                Text(review.filterText.isEmpty ? "No File Changes" : "No Matching Files")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleFileItems) { item in
                    NavigatorFileRow(item: item, diff: diffsByFileID[item.id])
                        .tag(item.id.stackID)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var optionsBinding: Binding<GitDiffOptions> {
        Binding(
            get: { model.diffOptions },
            set: { model.diffOptions = $0 }
        )
    }

    private var layoutBinding: Binding<DiffLayoutMode> {
        Binding(
            get: { model.diffLayout },
            set: { model.diffLayout = $0 }
        )
    }

    /// Files 只负责定位：选中即滚动到 Review 流里的那个文件。
    private var focusBinding: Binding<String?> {
        Binding(
            get: { review.focusedFileID },
            set: { review.focusedFileID = $0 }
        )
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
                subtitle: snapshot.worktree.rootURL.path,
                message: ""
            )
        case let .commit(commitID):
            if let commit = commits.first(where: { $0.id == commitID }) {
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
                title: "\(selectedCommits.count) Commits",
                subtitle: "\(String(base.prefix(7)))..\(String(head.prefix(7)))"
                    + (rangeAuthors.isEmpty ? "" : " · \(rangeAuthors)"),
                message: selectedCommits.prefix(4).map(\.subject).joined(separator: "\n")
            )
        }
    }

    private var reviewToolbar: some View {
        HStack(spacing: 12) {
            Text("\(visibleFileItems.count) files")
                .font(.caption.monospacedDigit().weight(.medium))
            DiffCountLabel(added: totalAddedLineCount, deleted: totalDeletedLineCount)

            Spacer()

            if isLoadingDiffs || isApplyingMutation {
                ProgressView()
                    .controlSize(.small)
            }

            DiffOptionsMenu(options: optionsBinding)

            Picker("Diff Layout", selection: layoutBinding) {
                ForEach(DiffLayoutMode.allCases) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Unified or side-by-side diff")

            Toggle(isOn: $review.isFocusedOnly) {
                Label("Focus", systemImage: "doc.text.magnifyingglass")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .disabled(review.focusedFileID == nil)
            .help("Show only the selected file")

            Button("Expand All") {
                setCollapsed(false, for: currentFileItems)
            }
            .disabled(!hasCollapsedFiles)

            Button("Collapse All") {
                setCollapsed(true, for: currentFileItems)
            }
            .disabled(!hasExpandedFiles)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.caption)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(.bar)
    }

    @ViewBuilder
    private var reviewBody: some View {
        if let diffError {
            ContentUnavailableView {
                Label("Unable to Read Diff", systemImage: "exclamationmark.triangle")
            } description: {
                Text(diffError)
                    .textSelection(.enabled)
            }
        } else if let contextDetailError {
            ContentUnavailableView {
                Label("Unable to Read Changes", systemImage: "exclamationmark.triangle")
            } description: {
                Text(contextDetailError)
                    .textSelection(.enabled)
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
            }
        } else {
            DiffStackView(
                groups: stackGroups,
                layout: model.diffLayout,
                scrollTarget: review.focusedFileID,
                scrollKey: stateKey,
                scrollStore: model.reviewStates,
                onToggleFile: toggleFile,
                onToggleGroup: toggleGroup,
                onFileAction: performFileAction,
                onSelectionAction: performSelectionAction
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Stack composition

    private var stackGroups: [DiffStackGroup] {
        // 聚焦模式只留选中的那一个文件，折叠/滚动状态照旧共享同一份。
        if review.isFocusedOnly, let focused = focusedItem {
            return [
                DiffStackGroup(
                    id: "focused",
                    title: nil,
                    emptyMessage: "No File Changes",
                    isExpanded: true,
                    files: [stackFile(for: focused, forceExpanded: true)]
                )
            ]
        }

        switch activeContext {
        case .pending:
            return [
                stackGroup(
                    id: "working",
                    title: "Working",
                    emptyMessage: emptyMessage("No working changes", "No matching working files"),
                    items: filtered(workingItems)
                ),
                stackGroup(
                    id: "untracked",
                    title: "Untracked",
                    emptyMessage: emptyMessage("No untracked files", "No matching untracked files"),
                    items: filtered(untrackedItems)
                ),
                stackGroup(
                    id: "staged",
                    title: "Staged",
                    emptyMessage: emptyMessage("No staged changes", "No matching staged files"),
                    items: filtered(stagedItems)
                )
            ]
        case .commit, .range:
            return [
                stackGroup(
                    id: "context",
                    title: "Files",
                    emptyMessage: emptyMessage("No file changes", "No matching files"),
                    items: filtered(contextItems)
                )
            ]
        }
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
            files: items.map { stackFile(for: $0, forceExpanded: false) }
        )
    }

    private func stackFile(for item: IntegratedFileItem, forceExpanded: Bool) -> DiffStackFile {
        DiffStackFile(
            id: item.id.stackID,
            path: item.change.path,
            status: item.stackStatus,
            statusLabel: item.statusLabel,
            isExpanded: forceExpanded || !review.collapsedFileIDs.contains(item.id.stackID),
            isFocused: item.id.stackID == review.focusedFileID,
            mutationMode: activeContext == .pending
                ? (item.scope == .working ? .working : .staged)
                : nil,
            diff: diffsByFileID[item.id]
        )
    }

    // MARK: - Pending mutations

    private func performFileAction(
        fileID: String,
        action: GitPendingSelectionAction
    ) {
        guard activeContext == .pending,
              !isApplyingMutation,
              let item = currentFileItems.first(where: { $0.id.stackID == fileID }) else {
            return
        }
        if action == .discard,
           !confirmDiscard(
               title: item.change.isUntracked ? "Delete Untracked File?" : "Discard File Changes?",
               detail: item.change.isUntracked
                   ? "This permanently deletes \(item.change.path)."
                   : "This permanently discards working changes in \(item.change.path)."
           ) {
            return
        }

        isApplyingMutation = true
        diffError = nil
        Task {
            do {
                try await model.applyFileAction(
                    action,
                    worktree: snapshot.worktree,
                    change: item.change
                )
                diffsByFileID = [:]
            } catch {
                diffError = String(describing: error)
            }
            isApplyingMutation = false
        }
    }

    private func performSelectionAction(
        fileID: String,
        lineIDs: Set<GitDiffLine.ID>,
        action: GitPendingSelectionAction
    ) {
        guard activeContext == .pending,
              !isApplyingMutation,
              let item = currentFileItems.first(where: { $0.id.stackID == fileID }),
              let diff = diffsByFileID[item.id],
              !lineIDs.isEmpty else {
            return
        }
        if action == .discard,
           !confirmDiscard(
               title: lineIDs.count == 1 ? "Discard Selected Line?" : "Discard Selected Lines?",
               detail: "This permanently discards the selected changes in \(item.change.path)."
           ) {
            return
        }

        isApplyingMutation = true
        diffError = nil
        Task {
            do {
                try await model.applySelectionAction(
                    action,
                    worktree: snapshot.worktree,
                    diff: diff,
                    selectedLineIDs: lineIDs
                )
                diffsByFileID = [:]
            } catch {
                diffError = String(describing: error)
            }
            isApplyingMutation = false
        }
    }

    private func confirmDiscard(title: String, detail: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Derived state

    private var activeContext: ReviewContext {
        guard !selectedCommits.isEmpty else {
            return .pending
        }
        guard selectedCommits.count > 1,
              let head = selectedCommits.first,
              let oldest = selectedCommits.last else {
            return .commit(selectedCommits[0].id)
        }
        return .range(base: oldest.parentOIDs.first ?? Self.emptyTreeOID, head: head.oid)
    }

    /// 按历史顺序（新 → 旧）排列，range 的 head/base 才有确定含义。
    private var selectedCommits: [GitCommit] {
        let selectedIDs = Set(
            selection.compactMap { item -> GitCommit.ID? in
                guard case let .commit(id) = item else {
                    return nil
                }
                return id
            }
        )
        return commits.filter { selectedIDs.contains($0.id) }
    }

    private var rangeAuthors: String {
        let authors = Set(selectedCommits.map(\.authorName)).sorted()
        return authors.count > 2 ? "\(authors.count) authors" : authors.joined(separator: ", ")
    }

    private var stateKey: ReviewStateKey {
        ReviewStateKey(worktreeID: snapshot.id, context: activeContext)
    }

    private var visibleCommits: [GitCommit] {
        guard !commitFilterText.isEmpty else {
            return commits
        }
        return commits.filter { commit in
            commit.subject.localizedCaseInsensitiveContains(commitFilterText)
                || commit.authorName.localizedCaseInsensitiveContains(commitFilterText)
                || commit.oid.hasPrefix(commitFilterText)
        }
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
        snapshot.status.changes
            .filter(predicate)
            .sorted(by: Self.compareChanges)
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

    private var focusedItem: IntegratedFileItem? {
        currentFileItems.first { $0.id.stackID == review.focusedFileID }
    }

    private func filtered(_ items: [IntegratedFileItem]) -> [IntegratedFileItem] {
        guard !review.filterText.isEmpty else {
            return items
        }
        return items.filter {
            $0.change.path.localizedCaseInsensitiveContains(review.filterText)
        }
    }

    private var totalAddedLineCount: Int {
        visibleFileItems.reduce(0) { $0 + (diffsByFileID[$1.id]?.addedLineCount ?? 0) }
    }

    private var totalDeletedLineCount: Int {
        visibleFileItems.reduce(0) { $0 + (diffsByFileID[$1.id]?.deletedLineCount ?? 0) }
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

    private var hasCollapsedFiles: Bool {
        currentFileItems.contains { review.collapsedFileIDs.contains($0.id.stackID) }
    }

    private var hasExpandedFiles: Bool {
        currentFileItems.contains { !review.collapsedFileIDs.contains($0.id.stackID) }
    }

    // MARK: - Actions

    private func resetWorkspace() {
        commits = []
        selection = [.pending]
        commitFilterText = ""
        historyError = nil
        contextChanges = []
        contextMessage = ""
        diffsByFileID = [:]
        review = model.reviewStates.state(for: stateKey)
        contextDetailError = nil
        diffError = nil
        isLoadingContextDetail = false
        isLoadingDiffs = false
    }

    private func toggleFile(_ stackID: String) {
        if review.collapsedFileIDs.contains(stackID) {
            review.collapsedFileIDs.remove(stackID)
        } else {
            review.collapsedFileIDs.insert(stackID)
        }
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
        case "working": filtered(workingItems)
        case "untracked": filtered(untrackedItems)
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
        review.focusedFileID = files[next].id.stackID
    }

    // MARK: - Loading

    private func loadHistory() async {
        isLoadingHistory = true
        historyError = nil
        do {
            let loaded = try await model.loadHistory(worktree: snapshot.worktree)
            try Task.checkCancellation()
            commits = loaded
            let availableIDs = Set(loaded.map(\.id))
            selection = selection.filter { item in
                guard case let .commit(id) = item else {
                    return true
                }
                return availableIDs.contains(id)
            }
            if selection.isEmpty {
                selection = [.pending]
            }
        } catch is CancellationError {
            return
        } catch {
            commits = []
            historyError = String(describing: error)
        }
        isLoadingHistory = false
    }

    private func loadContextDetails() async {
        switch activeContext {
        case .pending:
            isLoadingContextDetail = false
            return
        case let .commit(commitID):
            guard let commit = commits.first(where: { $0.id == commitID }) else {
                return
            }
            await loadCommitDetails(commit)
        case let .range(base, head):
            await loadRangeDetails(base: base, head: head)
        }
    }

    private func loadCommitDetails(_ commit: GitCommit) async {
        isLoadingContextDetail = true
        contextDetailError = nil
        contextMessage = commit.subject
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
            contextMessage = message
            contextChanges = changes.sorted(by: Self.compareChanges)
        } catch is CancellationError {
            return
        } catch {
            contextChanges = []
            contextDetailError = String(describing: error)
        }
        isLoadingContextDetail = false
    }

    private func loadRangeDetails(base: String, head: String) async {
        isLoadingContextDetail = true
        contextDetailError = nil
        contextMessage = ""
        do {
            let changes = try await model.loadRangeChanges(
                worktree: snapshot.worktree,
                baseOID: base,
                headOID: head
            )
            try Task.checkCancellation()
            contextChanges = changes.sorted(by: Self.compareChanges)
        } catch is CancellationError {
            return
        } catch {
            contextChanges = []
            contextDetailError = String(describing: error)
        }
        isLoadingContextDetail = false
    }

    /// 整次评审只跑一次 git diff，展开文件不再触发新的进程。
    private func loadDiffs() async {
        let items = currentFileItems
        guard !items.isEmpty else {
            diffsByFileID = [:]
            isLoadingDiffs = false
            return
        }

        isLoadingDiffs = true
        diffError = nil
        do {
            let loaded: [IntegratedFileID: GitFileDiff]
            switch activeContext {
            case .pending:
                loaded = try await loadPendingDiffs(items: items)
            case let .commit(commitID):
                guard let commit = commits.first(where: { $0.id == commitID }) else {
                    isLoadingDiffs = false
                    return
                }
                loaded = mapped(
                    diffs: try await model.loadCommitDiffs(
                        worktree: snapshot.worktree,
                        commit: commit,
                        changes: items.map(\.change)
                    ),
                    items: items
                )
            case let .range(base, head):
                loaded = mapped(
                    diffs: try await model.loadRangeDiffs(
                        worktree: snapshot.worktree,
                        baseOID: base,
                        headOID: head,
                        changes: items.map(\.change)
                    ),
                    items: items
                )
            }
            try Task.checkCancellation()
            diffsByFileID = loaded
        } catch is CancellationError {
            return
        } catch {
            diffsByFileID = [:]
            diffError = String(describing: error)
        }
        isLoadingDiffs = false
    }

    private func loadPendingDiffs(
        items: [IntegratedFileItem]
    ) async throws -> [IntegratedFileID: GitFileDiff] {
        let working = items.filter { $0.scope == .working }
        let staged = items.filter { $0.scope == .staged }

        async let workingDiffs = model.loadDiffs(
            worktree: snapshot.worktree,
            changes: working.map(\.change),
            scope: .working
        )
        async let stagedDiffs = model.loadDiffs(
            worktree: snapshot.worktree,
            changes: staged.map(\.change),
            scope: .staged
        )
        let (loadedWorking, loadedStaged) = try await (workingDiffs, stagedDiffs)

        var result: [IntegratedFileID: GitFileDiff] = [:]
        merge(diffs: loadedWorking, into: &result, items: working)
        merge(diffs: loadedStaged, into: &result, items: staged)
        return result
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
        let diffsByChangeID = Dictionary(
            diffs.map { ($0.change.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for item in items {
            result[item.id] = diffsByChangeID[item.change.id]
        }
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

// MARK: - Identity

enum IntegratedOverviewSelection: Hashable {
    case pending
    case commit(GitCommit.ID)
}

private enum IntegratedFileID: Hashable {
    case pending(scope: GitDiffScope, changeID: GitFileChange.ID)
    case context(contextID: String, changeID: GitFileChange.ID)

    var stackID: String {
        switch self {
        case let .pending(scope, changeID): "pending:\(scope.rawValue):\(changeID)"
        case let .context(contextID, changeID): "\(contextID):\(changeID)"
        }
    }
}

private struct IntegratedFileItem: Identifiable, Hashable {
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

private struct IntegratedDiffLoadKey: Hashable {
    let worktreeID: GitWorktreeSnapshot.ID
    let activityDate: Date
    let context: ReviewContext
    let options: GitDiffOptions
    let fileIDs: [IntegratedFileID]
}

// MARK: - Components

private struct DiffOptionsMenu: View {
    @Binding var options: GitDiffOptions

    private static let contextChoices: [GitDiffContext] = [
        .lines(3), .lines(8), .lines(25), .wholeFile
    ]

    var body: some View {
        Menu {
            Picker("Context", selection: $options.context) {
                ForEach(Self.contextChoices, id: \.self) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Toggle("Ignore Whitespace", isOn: $options.ignoresWhitespace)
        } label: {
            Label("Diff Options", systemImage: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Context lines and whitespace handling")
    }
}

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

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.tertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.caption)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
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
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
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

    var body: some View {
        HStack(spacing: 8) {
            Text(item.statusLabel)
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(statusColor)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 1) {
                Text((item.change.path as NSString).lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                let parent = (item.change.path as NSString).deletingLastPathComponent
                if !parent.isEmpty {
                    Text(parent)
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
        }
        .font(.caption2.monospacedDigit())
        .padding(.vertical, 1)
        .help(item.change.path)
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: commit.isMerge ? "arrow.triangle.merge" : "circle.fill")
                .font(.system(size: commit.isMerge ? 10 : 6))
                .foregroundStyle(commit.isMerge ? Color.purple : Color.accentColor)
                .frame(width: 13)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(commit.subject)
                        .lineLimit(1)
                    ForEach(commit.refNames.prefix(2), id: \.self) { ref in
                        Text(ref)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.14), in: Capsule())
                            .lineLimit(1)
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
        .padding(.vertical, 2)
        .help(commit.subject)
    }
}
