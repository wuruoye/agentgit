import AgentGitCore
import AppKit
import SwiftUI

struct WorkspaceIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ReviewToolbarButtonStyle(iconOnly: true).makeBody(configuration: configuration)
    }
}

struct WorktreeOverview: View {
    @Environment(AppModel.self) private var model
    let select: (String) -> Void
    @State private var query = ""
    @State private var attentionOnly = false
    @FocusState private var isSearchFocused: Bool

    private var allWorktrees: [GitWorktreeSnapshot] {
        model.projects.compactMap(\.snapshot).flatMap(\.worktrees)
    }

    private var projects: [WorktreeSwitcherProject] {
        worktreeSwitcherProjects(from: model.projects, query: query, pinnedWorktreeIDs: model.pinnedWorktreeIDs)
            .compactMap { project in
                let worktrees = attentionOnly
                    ? project.worktrees.filter { worktreeReviewStatus($0).needsAttention }
                    : project.worktrees
                return worktrees.isEmpty ? nil : WorktreeSwitcherProject(project: project.project, worktrees: worktrees)
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Worktrees").font(.system(size: 22, weight: .semibold))
                Text(allWorktrees.count.formatted())
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color(nsColor: AgentGitPalette.sidebarMetadata))
                Spacer()
                Text("\(model.projects.count) projects · \(allWorktrees.count { $0.status.changedFileCount > 0 }) with changes")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: AgentGitPalette.sidebarMetadata))
                Button(action: model.chooseProject) {
                    Label("Add Project", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 16)

            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a project or branch…", text: $query)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Clear Overview Filter")
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color(nsColor: AgentGitPalette.inputBackground), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 360)
                Spacer(minLength: 0)
                Toggle("Needs attention", isOn: $attentionOnly)
                    .toggleStyle(.button)
                    .controlSize(.regular)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 22)
            .padding(.bottom, 16)

            HStack(spacing: 16) {
                Text("BRANCH / WORKTREE").frame(maxWidth: .infinity, alignment: .leading)
                Text("FILES").frame(width: 48, alignment: .trailing)
                Text("DIFF").frame(width: 108, alignment: .trailing)
                Text("SYNC").frame(width: 130, alignment: .leading)
                Text("ACTIVITY").frame(width: 64, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Color(nsColor: AgentGitPalette.sidebarMetadata))
            .padding(.horizontal, 22)
            .frame(height: 32)
            .background(Color(nsColor: AgentGitPalette.canvas))

            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(projects) { project in
                        Section {
                            ForEach(project.worktrees) { snapshot in
                                OverviewWorktreeRow(
                                    snapshot: snapshot,
                                    isPinned: model.isWorktreePinned(id: snapshot.id),
                                    isSelected: model.selectedWorktreeID == snapshot.id,
                                    open: { select(snapshot.id) }
                                )
                                .contextMenu {
                                    Button("Open Worktree") { select(snapshot.id) }
                                    Button(model.isWorktreePinned(id: snapshot.id) ? "Unpin from Top" : "Pin to Top") {
                                        model.toggleWorktreePinned(id: snapshot.id)
                                    }
                                    Divider()
                                    Button("Open in Terminal") { openInTerminal(snapshot.worktree.rootURL) }
                                    Button("Reveal in Finder") { revealInFinder(snapshot.worktree.rootURL) }
                                    Button("Copy Path") { copyToPasteboard(snapshot.worktree.rootURL.path) }
                                }
                            }
                        } header: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                                Text(project.project.displayName).fontWeight(.semibold)
                                Text(project.worktrees.count.formatted()).foregroundStyle(.secondary)
                                Spacer()
                                Text((project.project.rootURL.path as NSString).abbreviatingWithTildeInPath)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color(nsColor: AgentGitPalette.sidebarMetadata))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 22)
                            .frame(height: 36)
                            .background(Color(nsColor: AgentGitPalette.canvas))
                        }
                    }
                    if projects.isEmpty {
                        ContentUnavailableView {
                            Label("No Matching Worktrees", systemImage: "magnifyingglass")
                        } description: {
                            Text("Try another branch name or clear the filters.")
                        } actions: {
                            Button("Clear Filters") { query = ""; attentionOnly = false }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, 16)
            }
            .background(Color(nsColor: AgentGitPalette.card))
        }
        .background(Color(nsColor: AgentGitPalette.card))
        .focusedSceneValue(\.workspaceSearchAction, { isSearchFocused = true })
    }
}

struct OverviewWorktreeRow: View {
    let snapshot: GitWorktreeSnapshot
    let isPinned: Bool
    let isSelected: Bool
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(isSelected ? Color.accentColor : Color(nsColor: AgentGitPalette.sidebarMetadata))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(snapshot.worktree.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if isPinned {
                                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                        Text(snapshot.worktree.rootURL.lastPathComponent)
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: AgentGitPalette.sidebarMetadata))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(snapshot.hasUsableState ? snapshot.status.changedFileCount.formatted() : "—")
                    .font(.system(size: 12, weight: snapshot.status.changedFileCount > 0 ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(snapshot.status.changedFileCount > 0 ? Color.primary : Color(nsColor: AgentGitPalette.sidebarMetadata))
                    .frame(width: 48, alignment: .trailing)
                Group {
                    if !snapshot.diffStat.isEmpty {
                        DiffCountLabel(added: snapshot.diffStat.addedLineCount, deleted: snapshot.diffStat.deletedLineCount)
                    } else {
                        Text("—").foregroundStyle(Color(nsColor: AgentGitPalette.sidebarMetadata))
                    }
                }
                .frame(width: 108, alignment: .trailing)
                Text(syncLabel)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(syncColor)
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)
                Text(snapshot.lastActivityAt == .distantPast ? "—" : compactRelativeTime(snapshot.lastActivityAt))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color(nsColor: AgentGitPalette.sidebarMetadata))
                    .frame(width: 64, alignment: .trailing)
            }
            .padding(.horizontal, 22)
            .frame(height: 54)
            .background(isHovered ? Color(nsColor: AgentGitPalette.sidebarHover) : isSelected ? Color.accentColor.opacity(0.05) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(worktreeRowHelpText(snapshot))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(snapshot.worktree.displayName), \(snapshot.worktree.rootURL.lastPathComponent), \(snapshot.status.changedFileCount) changed files, +\(snapshot.diffStat.addedLineCount), −\(snapshot.diffStat.deletedLineCount), \(syncLabel)")
    }

    private var syncLabel: String {
        if !snapshot.hasUsableState { return "Unavailable" }
        if snapshot.errorMessage != nil { return "Refresh warning" }
        guard let branch = snapshot.status.branch,
              let upstream = branch.upstreamRef, !upstream.isEmpty else { return "Local only" }
        if branch.aheadCount == 0 && branch.behindCount == 0 { return "Up to date" }
        return [branch.aheadCount > 0 ? "↑ \(branch.aheadCount)" : nil,
                branch.behindCount > 0 ? "↓ \(branch.behindCount)" : nil]
            .compactMap { $0 }.joined(separator: "   ")
    }

    private var syncColor: Color {
        if snapshot.errorMessage != nil { return Color(nsColor: AgentGitPalette.statusModified) }
        guard let branch = snapshot.status.branch,
              let upstream = branch.upstreamRef, !upstream.isEmpty else {
            return Color(nsColor: AgentGitPalette.sidebarMetadata)
        }
        return branch.aheadCount > 0 || branch.behindCount > 0
            ? Color(nsColor: AgentGitPalette.worktreeTracking)
            : Color(nsColor: AgentGitPalette.statusAdded)
    }
}
