import AgentGitCore
import AppKit
import SwiftUI

struct WorktreeHistoryView: View {
    @Environment(AppModel.self) private var model

    let snapshot: GitWorktreeSnapshot

    @State private var commits: [GitCommit] = []
    @State private var selectedCommitID: GitCommit.ID?
    @State private var changes: [GitFileChange] = []
    @State private var selectedChangeID: GitFileChange.ID?
    @State private var diff: GitFileDiff?
    @State private var historyError: String?
    @State private var detailError: String?
    @State private var isLoadingHistory = false
    @AppStorage("agentgit.history-commit-list-height") private var commitListHeight: Double = 300

    var body: some View {
        VStack(spacing: 0) {
            commitList
                .frame(height: commitListHeight)

            CommitListDivider(height: $commitListHeight)

            HSplitView {
                commitFileNavigator
                    .frame(minWidth: 210, idealWidth: 270, maxWidth: 390)
                commitDiffContent
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .task(id: snapshot.id) {
            await loadHistory()
        }
        .task(id: selectedCommitID) {
            await loadCommitChanges()
        }
        .task(id: commitDiffKey) {
            await loadCommitDiff()
        }
    }

    @ViewBuilder
    private var commitList: some View {
        if isLoadingHistory {
            ProgressView("Loading history…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let historyError {
            ContentUnavailableView {
                Label("Unable to Read History", systemImage: "exclamationmark.triangle")
            } description: {
                Text(historyError)
                    .textSelection(.enabled)
            }
        } else if commits.isEmpty {
            ContentUnavailableView {
                Label("No Commits Yet", systemImage: "clock")
            }
        } else {
            List(commits, selection: $selectedCommitID) { commit in
                CommitRow(commit: commit)
                    .tag(commit.id)
                    .contextMenu {
                        Button("Copy Commit SHA") {
                            copyToPasteboard(commit.oid)
                        }
                        Button("Copy Subject") {
                            copyToPasteboard(commit.subject)
                        }
                    }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var commitFileNavigator: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Files in Commit")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(changes.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if selectedCommit == nil {
                ContentUnavailableView {
                    Label("Select a Commit", systemImage: "clock.arrow.circlepath")
                }
            } else if changes.isEmpty {
                ContentUnavailableView {
                    Label("No File Changes", systemImage: "checkmark.circle")
                }
            } else {
                List(changes, selection: $selectedChangeID) { change in
                    ChangedFileRow(change: change, scope: .staged)
                        .tag(change.id)
                        .contextMenu {
                            Button("Copy Path") {
                                copyToPasteboard(change.path)
                            }
                        }
                }
                .listStyle(.sidebar)
            }
        }
    }

    @ViewBuilder
    private var commitDiffContent: some View {
        if let detailError {
            ContentUnavailableView {
                Label("Unable to Read Diff", systemImage: "exclamationmark.triangle")
            } description: {
                Text(detailError)
                    .textSelection(.enabled)
            }
        } else if let diff {
            UnifiedDiffView(diff: diff)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ContentUnavailableView {
                Label("Select a File", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("Choose a file to review what this commit changed.")
            }
        }
    }

    private var selectedCommit: GitCommit? {
        commits.first { $0.id == selectedCommitID }
    }

    private var selectedChange: GitFileChange? {
        changes.first { $0.id == selectedChangeID }
    }

    private var commitDiffKey: CommitDiffKey {
        CommitDiffKey(commitID: selectedCommitID, changeID: selectedChangeID)
    }

    private func loadHistory() async {
        isLoadingHistory = true
        historyError = nil
        do {
            let loaded = try await model.loadHistory(worktree: snapshot.worktree)
            try Task.checkCancellation()
            commits = loaded
            selectedCommitID = loaded.first?.id
        } catch is CancellationError {
            return
        } catch {
            commits = []
            selectedCommitID = nil
            historyError = String(describing: error)
        }
        isLoadingHistory = false
    }

    private func loadCommitChanges() async {
        guard let selectedCommit else {
            changes = []
            selectedChangeID = nil
            return
        }

        detailError = nil
        do {
            let loaded = try await model.loadCommitChanges(
                worktree: snapshot.worktree,
                commit: selectedCommit
            )
            try Task.checkCancellation()
            changes = loaded.sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            selectedChangeID = changes.first?.id
        } catch is CancellationError {
            return
        } catch {
            changes = []
            selectedChangeID = nil
            detailError = String(describing: error)
        }
    }

    private func loadCommitDiff() async {
        guard let selectedCommit, let selectedChange else {
            diff = nil
            return
        }

        detailError = nil
        do {
            let loaded = try await model.loadCommitDiff(
                worktree: snapshot.worktree,
                commit: selectedCommit,
                change: selectedChange
            )
            try Task.checkCancellation()
            diff = loaded
        } catch is CancellationError {
            return
        } catch {
            diff = nil
            detailError = String(describing: error)
        }
    }
}

private struct CommitDiffKey: Hashable {
    let commitID: GitCommit.ID?
    let changeID: GitFileChange.ID?
}

private struct CommitRow: View {
    let commit: GitCommit

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: commit.isMerge ? "arrow.triangle.merge" : "circle.fill")
                .font(.system(size: commit.isMerge ? 11 : 6))
                .foregroundStyle(commit.isMerge ? Color.purple : Color.accentColor)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(commit.subject)
                        .lineLimit(1)

                    ForEach(commit.refNames, id: \.self) { ref in
                        Text(ref)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.14), in: Capsule())
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 5) {
                    Text(commit.shortOID)
                        .font(.caption.monospaced())
                    Text("·")
                    Text(commit.authorName)
                        .lineLimit(1)
                    Text("·")
                    Text(commit.authoredAt, format: .dateTime.year().month().day().hour().minute())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .help(commit.subject)
    }
}

/// 可拖拽的水平分隔条：VSplitView 在此布局下忽略 idealHeight，只能压到 minHeight。
private struct CommitListDivider: View {
    @Binding var height: Double

    private static let range: ClosedRange<Double> = 120 ... 900

    var body: some View {
        ZStack {
            Divider()
            Color.clear
                .frame(height: 8)
                .contentShape(Rectangle())
        }
        .frame(height: 8)
        .gesture(
            DragGesture()
                .onChanged { value in
                    height = min(
                        Self.range.upperBound,
                        max(Self.range.lowerBound, height + value.translation.height)
                    )
                }
        )
        .onHover { isInside in
            if isInside {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
