import AgentGitCore
import SwiftUI

struct WorktreeSwitcherProject: Identifiable {
    let project: GitProject
    let worktrees: [GitWorktreeSnapshot]

    var id: GitProject.ID { project.id }
}

func worktreeSwitcherProjects(
    from states: [ProjectState],
    query: String
) -> [WorktreeSwitcherProject] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return states.compactMap { state in
        guard let snapshot = state.snapshot else {
            return nil
        }
        let projectMatches = projectMatchesSidebarFilter(
            state.project,
            query: normalizedQuery
        )
        let worktrees = normalizedQuery.isEmpty || projectMatches
            ? snapshot.worktrees
            : snapshot.worktrees.filter {
                worktreeMatchesSidebarFilter($0, query: normalizedQuery)
            }
        guard !worktrees.isEmpty else {
            return nil
        }
        return WorktreeSwitcherProject(
            project: state.project,
            worktrees: worktrees
        )
    }
}

func adjacentWorktreeSwitcherSelection(
    in projects: [WorktreeSwitcherProject],
    current: GitWorktreeSnapshot.ID?,
    offset: Int
) -> GitWorktreeSnapshot.ID? {
    let worktreeIDs = projects.flatMap { $0.worktrees.map(\.id) }
    guard !worktreeIDs.isEmpty else {
        return nil
    }
    guard let current,
          let currentIndex = worktreeIDs.firstIndex(of: current) else {
        return offset < 0 ? worktreeIDs.last : worktreeIDs.first
    }
    let nextIndex = min(
        max(currentIndex + offset, worktreeIDs.startIndex),
        worktreeIDs.index(before: worktreeIDs.endIndex)
    )
    return worktreeIDs[nextIndex]
}

struct WorktreeSwitcherView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: GitWorktreeSnapshot.ID?
    @FocusState private var isSearchFocused: Bool

    init(initialQuery: String = "") {
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(12)
            Divider()
            if projects.isEmpty {
                ContentUnavailableView {
                    Label(
                        query.isEmpty ? "No Worktrees" : "No Matching Worktrees",
                        systemImage: query.isEmpty
                            ? "point.3.connected.trianglepath.dotted"
                            : "line.3.horizontal.decrease.circle"
                    )
                } description: {
                    if !query.isEmpty {
                        Text("No project or worktree matches “\(query)”.")
                    }
                } actions: {
                    if !query.isEmpty {
                        Button("Clear Filter") {
                            query = ""
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { scrollProxy in
                    List(selection: $selection) {
                        ForEach(projects) { project in
                            Section(project.project.displayName) {
                                ForEach(project.worktrees) { worktree in
                                    WorktreeSwitcherRow(snapshot: worktree)
                                        .id(worktree.id)
                                        .tag(worktree.id)
                                        .contentShape(Rectangle())
                                        .onTapGesture(count: 2) {
                                            open(worktree.id)
                                        }
                                }
                            }
                        }
                    }
                    .onChange(of: selection) { _, worktreeID in
                        guard let worktreeID else {
                            return
                        }
                        scrollProxy.scrollTo(worktreeID, anchor: .center)
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack(spacing: 10) {
                Text("Type to filter · Return to open")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: dismiss.callAsFunction)
                    .keyboardShortcut(.cancelAction)
                Button("Open") {
                    if let selection {
                        open(selection)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!contains(selection))
            }
            .padding(12)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 380, idealHeight: 440)
        .onAppear {
            let selectedWorktreeID = model.selectedWorktreeID
            selection = contains(selectedWorktreeID)
                ? selectedWorktreeID
                : adjacentWorktreeSwitcherSelection(
                    in: projects,
                    current: nil,
                    offset: 1
                )
            isSearchFocused = true
        }
        .onChange(of: query) {
            guard !contains(selection) else {
                return
            }
            selection = projects.lazy.flatMap(\.worktrees).first?.id
        }
        .onExitCommand {
            dismiss()
        }
    }

    private var projects: [WorktreeSwitcherProject] {
        worktreeSwitcherProjects(from: model.projects, query: query)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField("Search projects and worktrees", text: $query)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onMoveCommand { direction in
                    switch direction {
                    case .up:
                        moveSelection(by: -1)
                    case .down:
                        moveSelection(by: 1)
                    default:
                        break
                    }
                }
                .onSubmit {
                    if let selection {
                        open(selection)
                    }
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Filter")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(.separator.opacity(0.7))
        }
    }

    private func contains(_ worktreeID: GitWorktreeSnapshot.ID?) -> Bool {
        guard let worktreeID else {
            return false
        }
        return projects.contains { project in
            project.worktrees.contains(where: { $0.id == worktreeID })
        }
    }

    private func moveSelection(by offset: Int) {
        selection = adjacentWorktreeSwitcherSelection(
            in: projects,
            current: selection,
            offset: offset
        )
    }

    private func open(_ worktreeID: GitWorktreeSnapshot.ID) {
        let requiresRefresh = model.selectWorktree(id: worktreeID)
        dismiss()
        guard requiresRefresh else {
            return
        }
        Task {
            _ = await model.refreshWorktree(id: worktreeID)
        }
    }
}

private struct WorktreeSwitcherRow: View {
    let snapshot: GitWorktreeSnapshot

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: snapshot.worktree.isDetached ? "link" : "arrow.triangle.branch")
                .foregroundStyle(snapshot.status.changedFileCount > 0 ? .orange : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(snapshot.worktree.displayName)
                        .lineLimit(1)
                    if snapshot.status.changedFileCount > 0 {
                        Text("\(snapshot.status.changedFileCount)")
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.16), in: Capsule())
                    }
                }
                HStack(spacing: 5) {
                    Text(snapshot.worktree.rootURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let shortHeadOID = snapshot.worktree.shortHeadOID {
                        Text("·")
                        Text(shortHeadOID)
                            .monospaced()
                    }
                    if snapshot.lastActivityAt != .distantPast {
                        Text("·")
                        Text(compactRelativeTime(snapshot.lastActivityAt))
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !snapshot.diffStat.isEmpty {
                HStack(spacing: 4) {
                    Text("+\(snapshot.diffStat.addedLineCount)")
                        .foregroundStyle(.green)
                    Text("−\(snapshot.diffStat.deletedLineCount)")
                        .foregroundStyle(.red)
                }
                .font(.caption.monospacedDigit().weight(.medium))
            }
        }
        .padding(.vertical, 3)
        .help(worktreeRowHelpText(snapshot))
    }
}
