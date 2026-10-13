import AgentGitCore
import SwiftUI

struct WorktreeSwitcherProject: Identifiable {
    let project: GitProject
    let worktrees: [GitWorktreeSnapshot]

    var id: GitProject.ID { project.id }
}

func worktreeSwitcherProjects(
    from states: [ProjectState],
    query: String,
    pinnedWorktreeIDs: Set<GitWorktreeSnapshot.ID> = []
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
        // 置顶在切换器里同样生效，否则同一个 worktree 在侧栏和 ⌘ 切换器里位置对不上。
        let orderedWorktrees = pinnedWorktreeIDs.isEmpty
            ? worktrees
            : worktrees.filter { pinnedWorktreeIDs.contains($0.id) }
                + worktrees.filter { !pinnedWorktreeIDs.contains($0.id) }
        return WorktreeSwitcherProject(
            project: state.project,
            worktrees: orderedWorktrees
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
    private let onOpen: ((String) -> Void)?
    @State private var query = ""
    @State private var selection: GitWorktreeSnapshot.ID?
    @FocusState private var isSearchFocused: Bool

    init(initialQuery: String = "", onOpen: ((String) -> Void)? = nil) {
        _query = State(initialValue: initialQuery)
        self.onOpen = onOpen
    }

    var body: some View {
        VStack(spacing: 0) {
            switcherHeader
            Divider()
            searchField
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            if projects.isEmpty {
                WorktreeSwitcherEmptyState(
                    query: query,
                    clearFilter: { query = "" }
                )
            } else {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                        ForEach(projects) { project in
                                VStack(spacing: 2) {
                                    HStack(spacing: 7) {
                                        Image(systemName: "folder.fill")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(Color.accentColor.opacity(0.78))
                                        Text(project.project.displayName)
                                            .font(.system(size: 12, weight: .semibold))
                                        Spacer()
                                        Text("\(project.worktrees.count)")
                                            .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.secondary.opacity(0.07), in: Capsule())
                                    }
                                    .padding(.horizontal, 10)
                                    .frame(height: 32)

                                ForEach(project.worktrees) { worktree in
                                        Button {
                                            open(worktree.id)
                                        } label: {
                                            WorktreeSwitcherRow(
                                                snapshot: worktree,
                                                isSelected: selection == worktree.id
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.horizontal, 4)
                                        .id(worktree.id)

                                    }
                                }
                                .padding(.bottom, 4)
                                .background(
                                    Color(nsColor: AgentGitPalette.sidebarCardBackground),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(
                                            Color(nsColor: AgentGitPalette.sidebarCardBorder),
                                            lineWidth: 1
                                        )
                                }
                                .clipShape(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                                }
                            }
                            .padding(12)
                        }
                    .onChange(of: selection) { _, worktreeID in
                        guard let worktreeID else {
                            return
                        }
                        scrollProxy.scrollTo(worktreeID, anchor: .center)
                    }
                }
            }
            Divider()
            HStack(spacing: 10) {
                Text("↑ ↓ to navigate · Return to open · Esc to close")
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
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: AgentGitPalette.reviewChrome))
        }
        .frame(minWidth: 580, idealWidth: 620, minHeight: 420, idealHeight: 500)
        .background(Color(nsColor: AgentGitPalette.canvas))
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
        worktreeSwitcherProjects(
            from: model.projects,
            query: query,
            pinnedWorktreeIDs: model.pinnedWorktreeIDs
        )
    }

    private var switcherHeader: some View {
        HStack(spacing: 11) {
            Image(systemName: "rectangle.stack.badge.person.crop")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(
                    Color.accentColor.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("Switch Worktree")
                    .font(.system(size: 20, weight: .semibold))
                Text("Jump to any branch across your projects.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text("\(projects.flatMap(\.worktrees).count)")
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.07), in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField("Search projects and worktrees", text: $query)
                .font(.system(size: 15))
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Color(nsColor: AgentGitPalette.inputBackground),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color(nsColor: AgentGitPalette.reviewControlBorder), lineWidth: 1)
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
        if let onOpen {
            onOpen(worktreeID)
            dismiss()
            return
        }
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

private struct WorktreeSwitcherEmptyState: View {
    let query: String
    let clearFilter: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(
                systemName: query.isEmpty
                    ? "point.3.connected.trianglepath.dotted"
                    : "line.3.horizontal.decrease.circle"
            )
            .font(.system(size: 24, weight: .regular))
            .foregroundStyle(.tertiary)
            .frame(width: 46, height: 46)
            .background(Color.secondary.opacity(0.055), in: Circle())

            Text(query.isEmpty ? "No Worktrees" : "No Matching Worktrees")
                .font(.system(size: 14, weight: .semibold))

            if !query.isEmpty {
                Text("No project or worktree matches “\(query)”.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Button("Clear Filter", action: clearFilter)
                    .controlSize(.small)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WorktreeSwitcherRow: View {
    let snapshot: GitWorktreeSnapshot
    var isSelected = false
    @State private var isHovered = false

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
                        .foregroundStyle(Color(nsColor: AgentGitPalette.additionText))
                    Text("−\(snapshot.diffStat.deletedLineCount)")
                        .foregroundStyle(Color(nsColor: AgentGitPalette.deletionText))
                }
                .font(.caption.monospacedDigit().weight(.medium))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.08)
                : isHovered ? Color.secondary.opacity(0.045) : Color.clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 30)
                    .padding(.leading, 1)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(worktreeRowHelpText(snapshot))
    }
}
