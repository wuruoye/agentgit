import AgentGitCore
import AppKit
import SwiftUI

enum SidebarLayoutMetrics {
    static let visibleWidth: CGFloat = 360
    static let headerHeight: CGFloat = 46
    static let headerIdentifier = NSUserInterfaceItemIdentifier(
        "AgentGitSidebarHeader"
    )
    // NavigationSplitView adds an 8pt sidebar container inset on macOS.
    static let navigationContentWidth = visibleWidth - 8
    static let navigationTopInset: CGFloat = 8
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var projectsShowingAllWorktrees: Set<GitProject.ID> = []
    @State private var sidebarFilterText = ""
    @State private var projectDropTargetID: GitProject.ID?
    @State private var windowTitlebarInset: CGFloat = 32

    init(initialSidebarFilterText: String = "") {
        _sidebarFilterText = State(initialValue: initialSidebarFilterText)
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Color.clear
                    .frame(
                        height: max(
                            0,
                            SidebarLayoutMetrics.headerHeight
                                - windowTitlebarInset
                                - SidebarLayoutMetrics.navigationTopInset
                        )
                    )
                SidebarSearchField(text: $sidebarFilterText)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredProjects.enumerated()), id: \.element.id) {
                            projectIndex, projectState in
                            VStack(spacing: 0) {
                                ProjectHeader(
                                    projectState: projectState,
                                    isCollapsed: model.collapsedProjectIDs.contains(projectState.id),
                                    showsDivider: projectIndex > 0,
                                    toggle: {
                                        model.toggleProjectCollapsed(id: projectState.id)
                                    }
                                )
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(
                                            projectDropTargetID == projectState.id
                                                ? Color(nsColor: AgentGitPalette.sidebarSelection)
                                                : Color.clear
                                        )
                                )
                                .padding(.horizontal, 7)
                                .draggable(projectState.id) {
                                    Label(
                                        projectState.project.displayName,
                                        systemImage: "folder"
                                    )
                                }
                                .dropDestination(
                                    for: String.self,
                                    action: { projectIDs, location in
                                        projectDropTargetID = nil
                                        guard let projectID = projectIDs.first,
                                              model.projects.contains(where: {
                                                  $0.id == projectID
                                              }) else {
                                            return false
                                        }
                                        model.moveProject(
                                            id: projectID,
                                            relativeTo: projectState.id,
                                            placeAfterTarget: location.y >= 15
                                        )
                                        return true
                                    },
                                    isTargeted: { isTargeted in
                                        if isTargeted {
                                            projectDropTargetID = projectState.id
                                        } else if projectDropTargetID == projectState.id {
                                            projectDropTargetID = nil
                                        }
                                    }
                                )
                                .contextMenu {
                                    projectContextMenu(projectState)
                                }

                                if !model.collapsedProjectIDs.contains(projectState.id)
                                    || !sidebarFilterQuery.isEmpty {
                                    VStack(spacing: 0) {
                                        projectContents(projectState)
                                    }
                                    .padding(.vertical, 1)
                                }
                            }
                            .padding(.bottom, 4)
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                }
                .overlay {
                    if !sidebarFilterQuery.isEmpty, filteredProjects.isEmpty {
                        SidebarNoResultsView(query: sidebarFilterQuery) {
                            sidebarFilterText = ""
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(
                min: SidebarLayoutMetrics.navigationContentWidth,
                ideal: SidebarLayoutMetrics.navigationContentWidth,
                max: SidebarLayoutMetrics.navigationContentWidth
            )
            .background(Color(nsColor: AgentGitPalette.sidebarBackground))
            .tint(Color(nsColor: AgentGitPalette.sidebarSelectionBorder))
            .toolbar(removing: .sidebarToggle)
        } detail: {
            if let snapshot = model.selectedWorktree {
                WorktreeReviewView(snapshot: snapshot)
            } else if model.projects.isEmpty {
                ContentUnavailableView {
                    Label("No Git Projects", systemImage: "folder.badge.plus")
                } description: {
                    Text("Add a Git project to discover all of its worktrees.")
                } actions: {
                    Button("Add Project", action: model.chooseProject)
                }
            } else if model.projects.contains(where: { $0.isLoading })
                        && model.projects.allSatisfy({ $0.snapshot == nil }) {
                ContentUnavailableView {
                    Label("Reading Worktrees…", systemImage: "clock")
                } description: {
                    Text("AgentGit is reading the saved projects.")
                }
            } else {
                ContentUnavailableView {
                    Label(
                        "Select a Worktree",
                        systemImage: "point.3.connected.trianglepath.dotted"
                    )
                } description: {
                    Text("Choose a worktree from the sidebar to review its changes.")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .background(
            WindowTitleVisibilityConfigurator(
                titlebarInset: $windowTitlebarInset,
                refreshDisabled: model.selectedWorktree == nil,
                refresh: {
                    Task {
                        await model.refreshSelectedWorktree()
                    }
                },
                addProject: model.chooseProject
            )
        )
        .task {
            model.setApplicationActive(NSApp.isActive)
            await model.loadProjectsIfNeeded()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            model.setApplicationActive(true)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didResignActiveNotification
            )
        ) { _ in
            model.setApplicationActive(false)
        }
        .onDisappear {
            model.setApplicationActive(false)
        }
        .sheet(
            isPresented: Binding(
                get: { model.isWorktreeSwitcherPresented },
                set: { model.isWorktreeSwitcherPresented = $0 }
            )
        ) {
            WorktreeSwitcherView()
                .environment(model)
        }
        .safeAreaInset(edge: .bottom) {
            if model.projectAdditionError != nil
                || model.agentAssociations.errorMessage != nil
                || model.cacheErrorMessage != nil {
                VStack(spacing: 0) {
                    if let errorMessage = model.projectAdditionError {
                        appErrorBar(
                            errorMessage,
                            accessibilityLabel: "Dismiss Project Error",
                            dismiss: model.clearProjectAdditionError
                        )
                    }
                    if model.projectAdditionError != nil,
                       model.agentAssociations.errorMessage != nil
                        || model.cacheErrorMessage != nil {
                        Divider()
                    }
                    if let errorMessage = model.agentAssociations.errorMessage {
                        appErrorBar(
                            errorMessage,
                            accessibilityLabel: "Dismiss Agent Error",
                            dismiss: model.agentAssociations.clearError
                        )
                    }
                    if model.agentAssociations.errorMessage != nil,
                       model.cacheErrorMessage != nil {
                        Divider()
                    }
                    if let errorMessage = model.cacheErrorMessage {
                        appErrorBar(
                            "Unable to update the cache: \(errorMessage)",
                            accessibilityLabel: "Dismiss Cache Error",
                            dismiss: model.clearCacheErrors
                        )
                    }
                }
                .background(.bar)
            }
        }
    }

    private func appErrorBar(
        _ message: String,
        accessibilityLabel: String,
        dismiss: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .lineLimit(2)
                .textSelection(.enabled)
                .help(message)
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var sidebarFilterQuery: String {
        sidebarFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredProjects: [ProjectState] {
        guard !sidebarFilterQuery.isEmpty else {
            return model.projects
        }
        return model.projects.filter { state in
            projectMatchesSidebarFilter(
                state.project,
                query: sidebarFilterQuery
            ) || state.snapshot?.worktrees.contains(where: {
                worktreeMatchesSidebarFilter($0, query: sidebarFilterQuery)
            }) == true
        }
    }

    @ViewBuilder
    private func projectContextMenu(_ projectState: ProjectState) -> some View {
        let projectIndex = model.projects.firstIndex(where: {
            $0.id == projectState.id
        })
        Button(
            model.collapsedProjectIDs.contains(projectState.id)
                ? "Expand Project"
                : "Collapse Project"
        ) {
            model.toggleProjectCollapsed(id: projectState.id)
        }
        Divider()
        Button("Refresh") {
            Task {
                await model.refreshProject(id: projectState.id)
            }
        }
        Button("Reveal in Finder") {
            revealInFinder(projectState.project.rootURL)
        }
        Button("Copy Path") {
            copyToPasteboard(projectState.project.rootURL.path)
        }
        Divider()
        Button("Move Up") {
            guard let projectIndex, projectIndex > 0 else {
                return
            }
            model.moveProject(
                id: projectState.id,
                relativeTo: model.projects[projectIndex - 1].id,
                placeAfterTarget: false
            )
        }
        .disabled(projectIndex == nil || projectIndex == 0)
        Button("Move Down") {
            guard let projectIndex,
                  projectIndex + 1 < model.projects.count else {
                return
            }
            model.moveProject(
                id: projectState.id,
                relativeTo: model.projects[projectIndex + 1].id,
                placeAfterTarget: true
            )
        }
        .disabled(
            projectIndex == nil
                || projectIndex == model.projects.count - 1
        )
        Divider()
        Button("Remove Project", role: .destructive) {
            model.removeProject(id: projectState.id)
        }
    }

    @ViewBuilder
    private func projectContents(_ state: ProjectState) -> some View {
        if state.isLoading, state.snapshot == nil {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading worktrees…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .frame(minHeight: 32)
        }

        if let errorMessage = state.errorMessage {
            ProjectErrorRow(
                title: state.snapshot == nil ? "Project Unavailable" : "Refresh Failed",
                message: errorMessage,
                canRemove: state.snapshot == nil,
                retry: {
                    Task {
                        await model.refreshProject(id: state.id)
                    }
                },
                dismiss: {
                    model.clearProjectError(id: state.id)
                },
                remove: {
                    model.removeProject(id: state.id)
                }
            )
            .padding(.horizontal, 28)
        }

        if let snapshot = state.snapshot {
            let projectMatches = projectMatchesSidebarFilter(
                state.project,
                query: sidebarFilterQuery
            )
            let presentation = if sidebarFilterQuery.isEmpty {
                projectWorktreePresentation(
                    snapshot: snapshot,
                    selectedWorktreeID: model.selectedWorktreeID,
                    showsAll: projectsShowingAllWorktrees.contains(state.id),
                    now: Date()
                )
            } else {
                ProjectWorktreePresentation(
                    visibleWorktrees: projectMatches
                        ? snapshot.worktrees
                        : snapshot.worktrees.filter {
                            worktreeMatchesSidebarFilter(
                                $0,
                                query: sidebarFilterQuery
                            )
                        },
                    hiddenWorktreeCount: 0
                )
            }
            ForEach(presentation.visibleWorktrees) { worktree in
                Button {
                    if model.selectWorktree(id: worktree.id) {
                        Task {
                            await model.refreshSelectedWorktree()
                        }
                    }
                } label: {
                    WorktreeRow(
                        snapshot: worktree,
                        isSelected: model.selectedWorktreeID == worktree.id
                    )
                }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 7)
                    .contextMenu {
                        Button("Refresh Worktree") {
                            Task {
                                await model.refreshWorktree(id: worktree.id)
                            }
                        }
                        Divider()
                        Button("Reveal in Finder") {
                            revealInFinder(worktree.worktree.rootURL)
                        }
                        Button("Open in Terminal") {
                            openInTerminal(worktree.worktree.rootURL)
                        }
                        let visualStudioCodeURL = visualStudioCodeApplicationURL()
                        Button("Open with Visual Studio Code") {
                            if let visualStudioCodeURL {
                                openInVisualStudioCode(
                                    worktree.worktree.rootURL,
                                    applicationURL: visualStudioCodeURL
                                )
                            }
                        }
                        .disabled(visualStudioCodeURL == nil)
                        Divider()
                        Button("Copy Path") {
                            copyToPasteboard(worktree.worktree.rootURL.path)
                        }
                        if let headOID = worktree.worktree.headOID,
                           !worktree.worktree.isUnborn {
                            Button("Copy HEAD SHA") {
                                copyToPasteboard(headOID)
                            }
                        }
                    }
            }
            if presentation.hiddenWorktreeCount > 0 {
                ProjectWorktreeDisclosureRow(
                    title: projectsShowingAllWorktrees.contains(state.id)
                        ? "Show Recent Only"
                        : "Show " + countedLabel(
                            presentation.hiddenWorktreeCount,
                            singular: "More Worktree",
                            plural: "More Worktrees"
                        ),
                    isExpanded: projectsShowingAllWorktrees.contains(state.id)
                ) {
                    if projectsShowingAllWorktrees.contains(state.id) {
                        projectsShowingAllWorktrees.remove(state.id)
                    } else {
                        projectsShowingAllWorktrees.insert(state.id)
                    }
                }
                .padding(.horizontal, 7)
            }
        }
    }
}

struct WindowTitleVisibilityConfigurator: NSViewRepresentable {
    @Binding var titlebarInset: CGFloat
    let refreshDisabled: Bool
    let refresh: () -> Void
    let addProject: () -> Void

    init(
        titlebarInset: Binding<CGFloat> = .constant(0),
        refreshDisabled: Bool = false,
        refresh: @escaping () -> Void = {},
        addProject: @escaping () -> Void = {}
    ) {
        _titlebarInset = titlebarInset
        self.refreshDisabled = refreshDisabled
        self.refresh = refresh
        self.addProject = addProject
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configure(from: view, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(from: nsView, coordinator: context.coordinator)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeHeader()
    }

    private func configure(from view: NSView, coordinator: Coordinator) {
        guard let window = view.window else {
            return
        }
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        let measuredInset = window.styleMask.contains(.fullScreen)
            ? 0
            : max(0, window.frame.height - window.contentLayoutRect.height)
        if abs(titlebarInset - measuredInset) > 0.5 {
            titlebarInset = measuredInset
        }
        coordinator.installHeader(
            in: window,
            refreshDisabled: refreshDisabled,
            refresh: refresh,
            addProject: addProject
        )
    }

    @MainActor
    final class Coordinator {
        private var headerView: NSHostingView<AnyView>?
        private weak var containerView: NSView?
        private var constraints: [NSLayoutConstraint] = []

        func installHeader(
            in window: NSWindow,
            refreshDisabled: Bool,
            refresh: @escaping () -> Void,
            addProject: @escaping () -> Void
        ) {
            guard let nextContentView = window.contentView else {
                return
            }
            let nextContainerView = nextContentView.superview ?? nextContentView
            let rootView = AnyView(
                SidebarHeader(
                    refreshDisabled: refreshDisabled,
                    refresh: refresh,
                    addProject: addProject
                )
                .ignoresSafeArea(.container, edges: .top)
            )
            if containerView !== nextContainerView || headerView == nil {
                removeHeader()
                let hostingView = NSHostingView(rootView: rootView)
                hostingView.identifier = SidebarLayoutMetrics.headerIdentifier
                hostingView.translatesAutoresizingMaskIntoConstraints = false
                nextContainerView.addSubview(
                    hostingView,
                    positioned: .above,
                    relativeTo: nextContentView.superview === nextContainerView
                        ? nextContentView
                        : nil
                )
                constraints = [
                    hostingView.leadingAnchor.constraint(
                        equalTo: nextContainerView.leadingAnchor
                    ),
                    hostingView.topAnchor.constraint(
                        equalTo: nextContainerView.topAnchor
                    ),
                    hostingView.widthAnchor.constraint(
                        equalToConstant: SidebarLayoutMetrics.visibleWidth
                    ),
                    hostingView.heightAnchor.constraint(
                        equalToConstant: SidebarLayoutMetrics.headerHeight
                    )
                ]
                NSLayoutConstraint.activate(constraints)
                headerView = hostingView
                containerView = nextContainerView
            } else {
                headerView?.rootView = rootView
            }
        }

        func removeHeader() {
            NSLayoutConstraint.deactivate(constraints)
            constraints.removeAll()
            headerView?.removeFromSuperview()
            headerView = nil
            containerView = nil
        }
    }
}

struct SidebarHeader: View {
    let refreshDisabled: Bool
    let refresh: () -> Void
    let addProject: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text("Projects")
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: 12)
            SidebarHeaderActionButton(
                systemName: "arrow.clockwise",
                help: "Refresh Current Worktree (⌘R)",
                disabled: refreshDisabled,
                action: refresh
            )
            SidebarHeaderActionButton(
                systemName: "plus",
                help: "Add Project (⌘O)",
                action: addProject
            )
        }
        .padding(.leading, 78)
        .padding(.trailing, 11)
        .frame(height: 46)
        .background(Color(nsColor: AgentGitPalette.sidebarChrome))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: AgentGitPalette.sidebarDivider))
                .frame(height: 1)
        }
    }
}

private struct SidebarHeaderActionButton: View {
    let systemName: String
    let help: String
    var disabled = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .regular))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            isHovered && !disabled
                                ? Color(nsColor: AgentGitPalette.sidebarHover)
                                : Color.clear
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .onHover { isHovered = $0 }
    }
}

struct SidebarSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
            TextField("Filter projects and worktrees", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Filter")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: AgentGitPalette.sidebarInputBackground))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color(nsColor: AgentGitPalette.sidebarDivider), lineWidth: 1)
        }
        .padding(.horizontal, 9)
        .padding(.top, 8)
        .padding(.bottom, 7)
        .accessibilityElement(children: .contain)
    }
}

struct SidebarNoResultsView: View {
    let query: String
    let clearFilter: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 25, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No Matching Worktrees")
                .font(.headline)
            Text("No project or worktree matches “\(query)”.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button("Clear Filter", action: clearFilter)
                .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

func projectMatchesSidebarFilter(
    _ project: GitProject,
    query: String
) -> Bool {
    guard !query.isEmpty else {
        return true
    }
    return [project.displayName, project.rootURL.path].contains {
        $0.localizedCaseInsensitiveContains(query)
    }
}

func worktreeMatchesSidebarFilter(
    _ snapshot: GitWorktreeSnapshot,
    query: String
) -> Bool {
    guard !query.isEmpty else {
        return true
    }
    return [
        snapshot.worktree.displayName,
        snapshot.worktree.rootURL.path,
        snapshot.worktree.branchRef ?? "",
        snapshot.worktree.shortHeadOID ?? ""
    ].contains {
        $0.localizedCaseInsensitiveContains(query)
    }
}

private struct ProjectErrorRow: View {
    let title: String
    let message: String
    let canRemove: Bool
    let retry: () -> Void
    let dismiss: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
                .help(message)
            HStack(spacing: 10) {
                Button("Retry", action: retry)
                    .buttonStyle(.borderless)
                if canRemove {
                    Button("Remove", role: .destructive, action: remove)
                        .buttonStyle(.borderless)
                }
                Spacer(minLength: 4)
                if !canRemove {
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss Project Error")
                }
            }
        }
        .padding(.vertical, 5)
    }
}

struct ProjectWorktreePresentation {
    let visibleWorktrees: [GitWorktreeSnapshot]
    let hiddenWorktreeCount: Int
}

func projectWorktreePresentation(
    snapshot: GitProjectSnapshot,
    selectedWorktreeID: GitWorktreeSnapshot.ID?,
    showsAll: Bool,
    now: Date
) -> ProjectWorktreePresentation {
    let recentCutoff = now.addingTimeInterval(-24 * 60 * 60)
    let orderedWorktrees = snapshot.worktrees.sorted(by: compareWorktreeSnapshots)
    var defaultWorktrees = Array(
        orderedWorktrees.filter { worktree in
            worktree.status.changedFileCount > 0
                || !worktree.diffStat.isEmpty
                || worktree.lastActivityAt >= recentCutoff
        }.prefix(4)
    )
    if let selected = orderedWorktrees.first(where: { $0.id == selectedWorktreeID }),
       !defaultWorktrees.contains(where: { $0.id == selected.id }) {
        if defaultWorktrees.count == 4 {
            defaultWorktrees.removeLast()
        }
        defaultWorktrees.append(selected)
    }
    return ProjectWorktreePresentation(
        visibleWorktrees: showsAll ? orderedWorktrees : defaultWorktrees,
        hiddenWorktreeCount: orderedWorktrees.count - defaultWorktrees.count
    )
}

private struct ProjectWorktreeDisclosureRow: View {
    let title: String
    let isExpanded: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 37)
            .frame(height: 25)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        isHovered
                            ? Color(nsColor: AgentGitPalette.sidebarHover)
                            : Color.clear
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct ProjectHeader: View {
    let projectState: ProjectState
    let isCollapsed: Bool
    let showsDivider: Bool
    let toggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
                Text(projectState.project.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.74))
                    .lineLimit(1)
                if projectState.errorMessage != nil {
                    Image(
                        systemName: projectState.snapshot == nil
                            ? "xmark.octagon.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(
                        projectState.snapshot == nil ? Color.red : Color.orange
                    )
                    .accessibilityLabel(
                        projectState.snapshot == nil
                            ? "Project unavailable"
                            : "Project refresh warning"
                    )
                }
                if projectState.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer(minLength: 4)
                if let count = projectState.snapshot?.worktrees.count {
                    Text("\(count)")
                        .font(.system(size: 10.5).monospacedDigit())
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        isHovered
                            ? Color(nsColor: AgentGitPalette.sidebarHover)
                            : Color.clear
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .padding(.top, showsDivider ? 5 : 0)
        .overlay(alignment: .top) {
            if showsDivider {
                Rectangle()
                    .fill(Color(nsColor: AgentGitPalette.sidebarDivider))
                    .frame(height: 1)
            }
        }
        .help(projectHeaderHelpText(projectState))
        .accessibilityLabel(
            "\(isCollapsed ? "Expand" : "Collapse") \(projectState.project.displayName)"
        )
    }
}

func projectHeaderHelpText(_ state: ProjectState) -> String {
    let path = state.project.rootURL.path
    guard let errorMessage = state.errorMessage?.trimmingCharacters(
        in: .whitespacesAndNewlines
    ), !errorMessage.isEmpty else {
        return path
    }
    let title = state.snapshot == nil ? "Project unavailable" : "Refresh warning"
    return "\(path)\n\n\(title): \(errorMessage)"
}

struct WorktreeRow: View {
    let snapshot: GitWorktreeSnapshot
    var isSelected = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 7) {
            worktreeStateIndicator
                .frame(width: 10, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.worktree.displayName)
                    .font(
                        .system(
                            size: 12.5,
                            weight: isSelected ? .medium : .regular
                        )
                    )
                    .foregroundStyle(primaryForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(snapshot.worktree.rootURL.lastPathComponent)
                    .font(.system(size: 10.5))
                    .foregroundStyle(
                        isSelected
                            ? primaryForeground.opacity(0.72)
                            : Color.secondary.opacity(0.78)
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailingStatus
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    isSelected
                        ? Color(nsColor: AgentGitPalette.sidebarSelection)
                        : isHovered
                            ? Color(nsColor: AgentGitPalette.sidebarHover)
                            : Color.clear
                )
        )
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color(nsColor: AgentGitPalette.sidebarSelectionBorder))
                    .frame(width: 2, height: 30)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(worktreeRowHelpText(snapshot))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(worktreeAccessibilityLabel)
        .accessibilityHint(worktreeRowHelpText(snapshot))
    }

    @ViewBuilder
    private var worktreeStateIndicator: some View {
        if snapshot.errorMessage != nil {
            Image(systemName: issueIconName)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(issueIconColor)
        } else {
            Circle()
                .fill(isDirty ? dirtyIndicatorForeground : Color.clear)
                .overlay {
                    Circle()
                        .stroke(
                            isDirty ? dirtyIndicatorForeground : Color.secondary.opacity(0.52),
                            lineWidth: 1
                        )
                }
                .frame(width: 6, height: 6)
        }
    }

    private var primaryForeground: Color {
        isSelected
            ? Color(nsColor: AgentGitPalette.sidebarSelectionBorder)
            : .primary
    }

    private var isDirty: Bool {
        snapshot.status.changedFileCount > 0 || !snapshot.diffStat.isEmpty
    }

    private var dirtyIndicatorForeground: Color {
        Color(nsColor: .systemOrange)
    }

    @ViewBuilder
    private var trailingStatus: some View {
        if !snapshot.diffStat.isEmpty {
            HStack(spacing: 4) {
                Text("+\(snapshot.diffStat.addedLineCount)")
                    .foregroundStyle(Color(nsColor: AgentGitPalette.statusAdded))
                Text("−\(snapshot.diffStat.deletedLineCount)")
                    .foregroundStyle(Color(nsColor: AgentGitPalette.statusDeleted))
            }
            .font(.system(size: 10.5).monospacedDigit())
            .accessibilityLabel(
                "+\(snapshot.diffStat.addedLineCount), −\(snapshot.diffStat.deletedLineCount)"
            )
        } else if snapshot.status.changedFileCount > 0 {
            Text("\(snapshot.status.changedFileCount)")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(dirtyIndicatorForeground)
                .accessibilityLabel(
                    countedLabel(
                        snapshot.status.changedFileCount,
                        singular: "changed file",
                        plural: "changed files"
                    )
                )
        } else if snapshot.lastActivityAt == .distantPast {
            Text("—")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        } else {
            Text(compactRelativeTime(snapshot.lastActivityAt))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private var issueIconName: String {
        snapshot.hasUsableState
            ? "exclamationmark.triangle.fill"
            : "xmark.octagon.fill"
    }

    private var issueIconColor: Color {
        snapshot.hasUsableState ? .orange : .red
    }

    private var worktreeAccessibilityLabel: String {
        var components = [snapshot.worktree.displayName]
        if snapshot.worktree.isDetached {
            components.append("Detached HEAD")
        }
        if snapshot.status.changedFileCount > 0 {
            components.append(
                countedLabel(
                    snapshot.status.changedFileCount,
                    singular: "changed file",
                    plural: "changed files"
                )
            )
        }
        if !snapshot.diffStat.isEmpty {
            components.append(
                "+\(snapshot.diffStat.addedLineCount), −\(snapshot.diffStat.deletedLineCount)"
            )
        }
        components.append(snapshot.worktree.rootURL.lastPathComponent)
        return components.joined(separator: ", ")
    }
}

func worktreeRowHelpText(_ snapshot: GitWorktreeSnapshot) -> String {
    var sections = [snapshot.worktree.rootURL.path]
    if let branch = snapshot.status.branch,
       branch.upstreamError == nil,
       let tracking = branchTrackingDescription(branch) {
        sections.append(tracking)
    }
    if let errorMessage = snapshot.errorMessage?.trimmingCharacters(
        in: .whitespacesAndNewlines
    ), !errorMessage.isEmpty {
        let title = snapshot.hasUsableState
            ? "Refresh warning"
            : "Repository unavailable"
        sections.append("\(title): \(errorMessage)")
    }
    return sections.joined(separator: "\n\n")
}

func branchTrackingDescription(_ branch: GitBranchStatus) -> String? {
    if let error = branch.upstreamError?.trimmingCharacters(
        in: .whitespacesAndNewlines
    ), !error.isEmpty {
        return error
    }
    guard let upstream = branch.upstreamRef, !upstream.isEmpty else {
        return nil
    }
    if branch.isSynced {
        return "Up to date with \(upstream)."
    }
    var descriptions: [String] = []
    if branch.aheadCount > 0 {
        descriptions.append(
            countedLabel(branch.aheadCount, singular: "commit")
                + " ahead of \(upstream)"
        )
    }
    if branch.behindCount > 0 {
        descriptions.append(
            countedLabel(branch.behindCount, singular: "commit")
                + " behind \(upstream)"
        )
    }
    return descriptions.isEmpty
        ? nil
        : descriptions.joined(separator: " · ") + "."
}
