import AgentGitCore
import AgentGitIntegrationShared
import AppKit
import SwiftUI

struct WorkspacePanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: AgentGitPalette.card))
            .clipShape(RoundedRectangle(cornerRadius: AgentGitPalette.cardCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AgentGitPalette.cardCornerRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: AgentGitPalette.cardBorder), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }
}

struct WorkspaceSearchFieldStyle: ViewModifier {
    var isFocused = false
    var isQuiet = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(isQuiet ? Color.clear : Color(nsColor: AgentGitPalette.inputBackground), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isFocused ? Color(nsColor: AgentGitPalette.focusIndicator) : isQuiet ? .clear : Color(nsColor: AgentGitPalette.cardBorder),
                        lineWidth: isFocused ? 1 : 0.5
                    )
                    .allowsHitTesting(false)
            }
            .animation(WorkspaceMotion.hover(reduceMotion: reduceMotion), value: isFocused)
    }
}

struct WorkspaceSelectionBackground: View {
    var isSelected: Bool
    var isHovered = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: ReviewWorkspaceStyle.selection))
                .opacity(isSelected ? 1 : 0)
            InteractionBackground(color: ReviewWorkspaceStyle.hover, isVisible: isHovered && !isSelected)
        }
            .padding(.horizontal, 4)
            .background(WorkspaceListSelectionStyle())
            .accessibilityHidden(true)
            .animation(nil, value: isSelected)
    }
}

private struct WorkspaceListSelectionStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> WorkspaceListSelectionView {
        WorkspaceListSelectionView()
    }

    func updateNSView(_ view: WorkspaceListSelectionView, context: Context) {
        view.applySelectionStyle()
    }
}

private final class WorkspaceListSelectionView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applySelectionStyle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applySelectionStyle()
    }

    func applySelectionStyle() {
        var ancestor = superview
        while let view = ancestor {
            if let table = view as? NSTableView {
                // 选中背景由 WorkspaceSelectionBackground 绘制，避免系统鼠标高亮另铺一层蓝色。
                if table.selectionHighlightStyle != .none {
                    table.selectionHighlightStyle = .none
                }
                return
            }
            ancestor = view.superview
        }
    }
}

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
                VStack(alignment: .leading, spacing: 5) {
                    Text("Worktrees")
                        .font(.agentGitInterface(size: 24, weight: .semibold))
                    Text("\(model.projects.count) projects · \(allWorktrees.count) worktrees · \(allWorktrees.count { $0.status.changedFileCount > 0 }) with changes")
                        .font(.agentGitInterface(size: 12))
                        .foregroundStyle(Color(nsColor: AgentGitPalette.sidebarMetadata))
                }
                Spacer()
                Button(action: model.chooseProject) {
                    Label("Add Project", systemImage: "plus")
                }
                .buttonStyle(ReviewToolbarButtonStyle(kind: .primary))
            }
            .padding(.horizontal, 26)
            .padding(.top, 28)
            .padding(.bottom, 22)

            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a project or branch…", text: $query)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear Overview Filter")
                        .workspaceControlSlot(isVisible: !query.isEmpty)
                }
                .modifier(WorkspaceSearchFieldStyle(isFocused: isSearchFocused))
                .frame(maxWidth: 360)
                Spacer(minLength: 0)
                Toggle("Needs attention", isOn: $attentionOnly)
                    .toggleStyle(.button)
                    .buttonStyle(ReviewToolbarButtonStyle(kind: attentionOnly ? .selected : .normal))
                    .controlSize(.regular)
            }
            .font(.agentGitInterface(size: 12))
            .padding(.horizontal, 26)
            .padding(.bottom, 16)

            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Text("Branch / Worktree").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Files").frame(width: 48, alignment: .trailing)
                    Text("Changes").frame(width: 108, alignment: .trailing)
                    Text("Sync").frame(width: 130, alignment: .leading)
                    Text("Activity").frame(width: 64, alignment: .trailing)
                }
                .font(.agentGitInterface(size: 11, weight: .medium))
                .foregroundStyle(Color(nsColor: AgentGitPalette.sidebarMetadata))
                .padding(.horizontal, 22)
                .frame(height: 36)
                .background(Color(nsColor: AgentGitPalette.inputBackground))

                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(projects) { project in
                            // 重名按整个项目判断，筛选后也保持同样的显示。
                            let locationLabels = worktreeLocationLabels(
                                (model.projects.first { $0.id == project.id }?.snapshot?.worktrees
                                    ?? project.worktrees).map(\.worktree)
                            )
                            Section {
                                ForEach(project.worktrees) { snapshot in
                                    let creator = creatorAssociation(for: snapshot)
                                    OverviewWorktreeRow(
                                        snapshot: snapshot,
                                        locationLabel: locationLabels[snapshot.id],
                                        creator: creator.map {
                                            OverviewWorktreeCreator(
                                                association: $0,
                                                title: model.agentAssociations.displayTitle(for: $0),
                                                availability: model.agentAssociations.navigationAvailability(for: $0)
                                            )
                                        },
                                        isPinned: model.isWorktreePinned(id: snapshot.id),
                                        isSelected: model.selectedWorktreeID == snapshot.id,
                                        open: { select(snapshot.id) }
                                    )
                                    .contextMenu {
                                        Button("Open Worktree") { select(snapshot.id) }
                                        if let creator {
                                            Button("Open Creator Session") {
                                                model.agentAssociations.open(creator)
                                            }
                                        }
                                        Button(model.isWorktreePinned(id: snapshot.id) ? "Unpin from Top" : "Pin to Top") {
                                            model.toggleWorktreePinned(id: snapshot.id)
                                        }
                                        Divider()
                                        Button("Open in Terminal") { openInTerminal(snapshot.worktree.rootURL) }
                                        Button("Reveal in Finder") { revealInFinder(snapshot.worktree.rootURL) }
                                        WorktreeOpenWithMenuItems(
                                            entries: model.openWithSettings.entries(for: project.id),
                                            worktreeRootURL: snapshot.worktree.rootURL
                                        )
                                        Button("Copy Path") { copyToPasteboard(snapshot.worktree.rootURL.path) }
                                    }
                                }
                            } header: {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder").foregroundStyle(Color(nsColor: AgentGitPalette.sidebarMetadata))
                                    Text(project.project.displayName).fontWeight(.semibold)
                                    Text(project.worktrees.count.formatted()).foregroundStyle(.secondary)
                                    Spacer()
                                    Text((project.project.rootURL.path as NSString).abbreviatingWithTildeInPath)
                                        .font(.agentGitInterface(size: 11))
                                        .foregroundStyle(Color(nsColor: AgentGitPalette.sidebarMetadata))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .font(.agentGitInterface(size: 12))
                                .padding(.horizontal, 22)
                                .frame(height: 40)
                                .background(Color(nsColor: AgentGitPalette.card))
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
            .modifier(WorkspacePanelStyle())
            .padding(.horizontal, 22)
            .padding(.bottom, 20)
        }
        .background(Color(nsColor: AgentGitPalette.canvas))
        .focusedSceneValue(\.workspaceSearchAction, { isSearchFocused = true })
    }

    private func creatorAssociation(for snapshot: GitWorktreeSnapshot) -> AgentAssociation? {
        model.agentAssociations.creatorAssociation(forWorktreeAt: snapshot.id)
    }
}

struct OverviewWorktreeCreator {
    let association: AgentAssociation
    let title: String
    let availability: AgentSessionNavigationAvailability

    var provider: AgentProvider { association.provider }

    var helpText: String {
        var lines = [
            "Created by \(provider.displayName) session",
            title,
            association.sessionID
        ]
        if association.updatedAt != .distantPast {
            lines.append(association.updatedAt.formatted(date: .abbreviated, time: .shortened))
        }
        switch availability {
        case .resolving, .available:
            lines.append("Right-click → Open Creator Session")
        case let .unavailable(reason):
            lines.append(reason)
        }
        return lines.joined(separator: "\n")
    }
}

struct OverviewWorktreeRow: View {
    let snapshot: GitWorktreeSnapshot
    var locationLabel: String? = nil
    var creator: OverviewWorktreeCreator? = nil
    let isPinned: Bool
    let isSelected: Bool
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(Color(nsColor: AgentGitPalette.sidebarMetadata))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(snapshot.worktree.displayName)
                                .font(.agentGitInterface(size: 13, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if isPinned {
                                Image(systemName: "pin.fill").font(.agentGitInterface(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: 5) {
                            Text(location)
                            if let creator {
                                Text("·")
                                HStack(spacing: 4) {
                                    Image(systemName: creator.provider.systemImageName)
                                        .foregroundStyle(creator.provider.tintColor)
                                    Text(creator.title)
                                        .truncationMode(.tail)
                                }
                                .help(creator.helpText)
                            }
                        }
                        .font(.agentGitInterface(size: 11))
                        .foregroundStyle(Color(nsColor: AgentGitPalette.sidebarMetadata))
                        .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(snapshot.hasUsableState ? snapshot.status.changedFileCount.formatted() : "—")
                    .font(.agentGitInterface(size: 12, weight: snapshot.status.changedFileCount > 0 ? .semibold : .regular).monospacedDigit())
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
                    .font(.agentGitInterface(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(syncColor)
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)
                Text(snapshot.lastActivityAt == .distantPast ? "—" : compactRelativeTime(snapshot.lastActivityAt))
                    .font(.agentGitInterface(size: 11).monospacedDigit())
                    .foregroundStyle(Color(nsColor: AgentGitPalette.sidebarMetadata))
                    .frame(width: 64, alignment: .trailing)
            }
            .padding(.horizontal, 22)
            .frame(height: 58)
            .background {
                InteractionBackground(
                    color: isSelected ? AgentGitPalette.sidebarSelection : AgentGitPalette.sidebarHover,
                    isVisible: isSelected || isHovered,
                    cornerRadius: 8
                )
                    .animation(nil, value: isSelected)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(worktreeRowHelpText(snapshot))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(snapshot.worktree.displayName), \(location),\(creator.map { " created by \($0.provider.displayName) session \($0.title)," } ?? "") \(snapshot.status.changedFileCount) changed files, +\(snapshot.diffStat.addedLineCount), −\(snapshot.diffStat.deletedLineCount), \(syncLabel)")
    }

    private var location: String {
        locationLabel ?? snapshot.worktree.rootURL.lastPathComponent
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
