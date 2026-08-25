import AgentGitCore
import SwiftUI

struct WorktreeReviewView: View {
    @Environment(AppModel.self) private var model

    let snapshot: GitWorktreeSnapshot

    @State private var tab: ReviewTab = .working
    @State private var selectedChangeID: GitFileChange.ID?
    @State private var diff: GitFileDiff?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var filterText = ""

    var body: some View {
        VStack(spacing: 0) {
            reviewHeader
            Divider()

            if let statusError = snapshot.errorMessage {
                ContentUnavailableView {
                    Label("Unable to Read Status", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(statusError)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tab == .history {
                WorktreeHistoryView(snapshot: snapshot)
            } else {
                HSplitView {
                    fileNavigator
                        .frame(minWidth: 210, idealWidth: 270, maxWidth: 390)
                    diffContent
                        .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onChange(of: snapshot.id, initial: true) {
            resetSelection()
        }
        .onChange(of: tab) {
            resetSelection()
        }
        .onChange(of: filterText) {
            if !visibleChanges.contains(where: { $0.id == selectedChangeID }) {
                selectedChangeID = visibleChanges.first?.id
            }
        }
        .task(id: loadKey) {
            await loadSelectedDiff()
        }
    }

    private var reviewHeader: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.worktree.displayName)
                    .font(.headline)
                Text(snapshot.worktree.rootURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer()

            if let diff, tab != .history {
                HStack(spacing: 7) {
                    Text("+\(diff.addedLineCount)")
                        .foregroundStyle(.green)
                    Text("−\(diff.deletedLineCount)")
                        .foregroundStyle(.red)
                }
                .font(.caption.monospacedDigit().weight(.medium))
            }

            Picker("Review Tab", selection: $tab) {
                ForEach(ReviewTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 250)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var fileNavigator: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Changed Files")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(visibleChanges.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)

            FileFilterField(text: $filterText)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            Divider()

            if visibleChanges.isEmpty {
                ContentUnavailableView {
                    Label(
                        filterText.isEmpty ? "No \(tab.title) Changes" : "No Matching Files",
                        systemImage: filterText.isEmpty ? "checkmark.circle" : "magnifyingglass"
                    )
                }
            } else {
                List(visibleChanges, selection: $selectedChangeID) { change in
                    ChangedFileRow(change: change, scope: scope)
                        .tag(change.id)
                        .contextMenu {
                            Button("Reveal in Finder") {
                                revealInFinder(
                                    snapshot.worktree.rootURL
                                        .appendingPathComponent(change.path)
                                )
                            }
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
    private var diffContent: some View {
        if isLoading {
            ProgressView("Loading diff…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ContentUnavailableView {
                Label("Unable to Read Diff", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
                    .textSelection(.enabled)
            }
        } else if let diff {
            UnifiedDiffView(diff: diff)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ContentUnavailableView {
                Label("Select a File", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("Choose a changed file to review its \(tab.title.lowercased()) diff.")
            }
        }
    }

    private var scope: GitDiffScope {
        tab == .staged ? .staged : .working
    }

    private var visibleChanges: [GitFileChange] {
        guard tab != .history else {
            return []
        }
        return snapshot.status.changes
            .filter { change in
                switch scope {
                case .working:
                    change.isUnstaged || change.isUntracked
                case .staged:
                    change.isStaged
                }
            }
            .filter { change in
                filterText.isEmpty
                    || change.path.localizedCaseInsensitiveContains(filterText)
            }
            .sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
    }

    private var selectedChange: GitFileChange? {
        visibleChanges.first { $0.id == selectedChangeID }
    }

    private var loadKey: DiffLoadKey {
        DiffLoadKey(
            worktreeID: snapshot.id,
            activityDate: snapshot.lastActivityAt,
            tab: tab,
            changeID: selectedChangeID
        )
    }

    private func resetSelection() {
        selectedChangeID = visibleChanges.first?.id
        diff = nil
        errorMessage = nil
    }

    private func loadSelectedDiff() async {
        guard let selectedChange else {
            diff = nil
            errorMessage = nil
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil
        do {
            let loadedDiff = try await model.loadDiff(
                worktree: snapshot.worktree,
                change: selectedChange,
                scope: scope
            )
            try Task.checkCancellation()
            diff = loadedDiff
        } catch is CancellationError {
            return
        } catch {
            diff = nil
            errorMessage = String(describing: error)
        }
        isLoading = false
    }
}

private struct DiffLoadKey: Hashable {
    let worktreeID: GitWorktreeSnapshot.ID
    let activityDate: Date
    let tab: ReviewTab
    let changeID: GitFileChange.ID?
}

enum ReviewTab: String, CaseIterable, Identifiable {
    case working
    case staged
    case history

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .working: "Working"
        case .staged: "Staged"
        case .history: "History"
        }
    }
}

struct ChangedFileRow: View {
    let change: GitFileChange
    let scope: GitDiffScope

    var body: some View {
        HStack(spacing: 9) {
            Text(statusLabel)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(statusColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text((change.path as NSString).lastPathComponent)
                    .lineLimit(1)
                let parent = (change.path as NSString).deletingLastPathComponent
                if !parent.isEmpty {
                    Text(parent)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .help(change.path)
    }

    private var statusLabel: String {
        if change.isUntracked {
            return "U"
        }
        let value = scope == .staged ? change.indexStatus : change.worktreeStatus
        return String(value)
    }

    private var statusColor: Color {
        switch statusLabel {
        case "A", "?", "U": .green
        case "D": .red
        case "R", "C": .blue
        default: .orange
        }
    }
}

struct UnifiedDiffView: View {
    let diff: GitFileDiff

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                Text(diff.change.path)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Spacer()
                Text("\(diff.hunks.count) hunks")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            if let message = diff.message, diff.hunks.isEmpty {
                ContentUnavailableView {
                    Label(message, systemImage: "doc.questionmark")
                }
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(diff.hunks) { hunk in
                            HunkHeaderRow(header: hunk.header)
                            ForEach(hunk.lines) { line in
                                DiffLineRow(line: line)
                            }
                        }
                    }
                    .frame(minWidth: 760, alignment: .topLeading)
                    .textSelection(.enabled)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct HunkHeaderRow: View {
    let header: String

    var body: some View {
        Text(header)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.blue)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.08))
    }
}

struct DiffLineRow: View {
    let line: GitDiffLine

    var body: some View {
        HStack(spacing: 0) {
            LineNumber(value: line.oldLineNumber)
            LineNumber(value: line.newLineNumber)

            Text(marker)
                .foregroundStyle(markerColor)
                .frame(width: 18, alignment: .center)

            Text(line.content.isEmpty ? " " : line.content)
                .font(.system(size: 12.5, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 12)
        }
        .frame(minHeight: 20)
        .background(backgroundColor)
    }

    private var marker: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "−"
        case .metadata: "·"
        case .context: " "
        }
    }

    private var markerColor: Color {
        switch line.kind {
        case .addition: .green
        case .deletion: .red
        case .metadata: .secondary
        case .context: .clear
        }
    }

    private var backgroundColor: Color {
        switch line.kind {
        case .addition: Color.green.opacity(0.10)
        case .deletion: Color.red.opacity(0.10)
        case .metadata: Color.secondary.opacity(0.05)
        case .context: .clear
        }
    }
}

struct LineNumber: View {
    let value: Int?

    var body: some View {
        Text(value.map(String.init) ?? "")
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: 48, alignment: .trailing)
            .padding(.trailing, 8)
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
    }
}

struct FileFilterField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.tertiary)

            TextField("Filter files", text: $text)
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
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }
}
