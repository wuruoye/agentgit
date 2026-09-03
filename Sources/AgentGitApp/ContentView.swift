import AgentGitCore
import AppKit
import SwiftUI

enum SidebarLayoutMetrics {
    static let visibleWidth: CGFloat = 360
    // NavigationSplitView adds an 8pt sidebar container inset on macOS.
    static let navigationContentWidth = visibleWidth - 8
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var projectsShowingAllWorktrees: Set<GitProject.ID> = []
    @State private var sidebarFilterText = ""
    @State private var showsOnlyPendingWorktrees = false
    @State private var projectDropTargetID: GitProject.ID?

    init(initialSidebarFilterText: String = "") {
        _sidebarFilterText = State(initialValue: initialSidebarFilterText)
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                AgentGitSidebarBrandView(
                    isRefreshing: model.projects.contains(where: \.isLoading),
                    hasIssues: sidebarHasIssues,
                    pendingWorktreeCount: pendingWorktreeCount,
                    showsOnlyPendingWorktrees: $showsOnlyPendingWorktrees
                )
                .padding(.horizontal, 14)
                .padding(.top, 11)
                .padding(.bottom, 7)

                SidebarSearchField(text: $sidebarFilterText)

                ScrollView {
                    LazyVStack(spacing: 8) {
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
                                    .padding(.bottom, 4)
                                }
                            }
                            .background(
                                Color.secondary.opacity(0.022),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(
                                        Color.secondary.opacity(0.11),
                                        lineWidth: 1
                                    )
                            }
                            .clipShape(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .shadow(
                                color: Color.black.opacity(0.025),
                                radius: 4,
                                y: 1
                            )
                            .padding(.horizontal, 8)
                        }
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 10)
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
                AgentGitWorkspaceEmptyState(
                    title: "No Git Projects",
                    detail: "Add a Git project to discover and review all of its worktrees.",
                    systemImage: "folder.badge.plus",
                    actionTitle: "Add Project",
                    action: model.chooseProject
                )
            } else if model.projects.contains(where: { $0.isLoading })
                        && model.projects.allSatisfy({ $0.snapshot == nil }) {
                AgentGitWorkspaceEmptyState(
                    title: "Reading Worktrees…",
                    detail: "AgentGit is restoring saved repository snapshots.",
                    systemImage: "clock",
                    isLoading: true
                )
            } else {
                AgentGitWorkspaceEmptyState(
                    title: "Select a Worktree",
                    detail: "Choose a worktree from the sidebar to review its changes.",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task {
                        await model.refreshSelectedWorktree()
                    }
                } label: {
                    Label("Refresh Current Worktree", systemImage: "arrow.clockwise")
                }
                .disabled(model.selectedWorktree == nil)
                .help("Refresh Current Worktree (⌘R)")

                Button(action: model.chooseProject) {
                    Label("Add Project", systemImage: "plus")
                }
                .help("Add Project (⌘O)")
            }
        }
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

    /// 置顶的排最前，其余保持原顺序。搜索和「只看待办」两条路径都要用，
    /// 否则置顶项会散落在结果中间。
    private func pinnedFirst(
        _ worktrees: [GitWorktreeSnapshot]
    ) -> [GitWorktreeSnapshot] {
        guard !model.pinnedWorktreeIDs.isEmpty else {
            return worktrees
        }
        return worktrees.filter { model.pinnedWorktreeIDs.contains($0.id) }
            + worktrees.filter { !model.pinnedWorktreeIDs.contains($0.id) }
    }

    /// 只显示需要处理的 worktree：有未提交改动、有没推的提交、落后上游或读不出来。
    private func visibleWorktrees(
        _ worktrees: [GitWorktreeSnapshot]
    ) -> [GitWorktreeSnapshot] {
        guard showsOnlyPendingWorktrees else {
            return worktrees
        }
        return worktrees.filter {
            worktreeReviewStatus($0).needsAttention
                || $0.id == model.selectedWorktreeID
                || model.isWorktreePinned(id: $0.id)
        }
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

    private var sidebarWorktrees: [GitWorktreeSnapshot] {
        model.projects.compactMap(\.snapshot).flatMap(\.worktrees)
    }

    private var pendingWorktreeCount: Int {
        sidebarWorktrees.count { worktreeReviewStatus($0).needsAttention }
    }

    private var sidebarHasIssues: Bool {
        model.projectAdditionError != nil
            || model.cacheErrorMessage != nil
            || model.agentAssociations.errorMessage != nil
            || model.projects.contains { $0.errorMessage != nil }
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
            let presentation = if showsOnlyPendingWorktrees {
                ProjectWorktreePresentation(
                    visibleWorktrees: pinnedFirst(
                        visibleWorktrees(
                            sidebarFilterQuery.isEmpty || projectMatches
                                ? snapshot.worktrees
                                : snapshot.worktrees.filter {
                                    worktreeMatchesSidebarFilter(
                                        $0,
                                        query: sidebarFilterQuery
                                    )
                                }
                        )
                    ),
                    hiddenWorktreeCount: 0
                )
            } else if sidebarFilterQuery.isEmpty {
                projectWorktreePresentation(
                    snapshot: snapshot,
                    selectedWorktreeID: model.selectedWorktreeID,
                    pinnedWorktreeIDs: model.pinnedWorktreeIDs,
                    showsAll: projectsShowingAllWorktrees.contains(state.id),
                    now: Date()
                )
            } else {
                ProjectWorktreePresentation(
                    visibleWorktrees: pinnedFirst(
                        projectMatches
                            ? snapshot.worktrees
                            : snapshot.worktrees.filter {
                                worktreeMatchesSidebarFilter(
                                    $0,
                                    query: sidebarFilterQuery
                                )
                            }
                    ),
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
                        isSelected: model.selectedWorktreeID == worktree.id,
                        isPinned: model.isWorktreePinned(id: worktree.id)
                    )
                }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 7)
                    .contextMenu {
                        Button(
                            model.isWorktreePinned(id: worktree.id)
                                ? "Unpin from Top"
                                : "Pin to Top"
                        ) {
                            model.toggleWorktreePinned(id: worktree.id)
                        }
                        Divider()
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

struct AgentGitSidebarBrandView: View {
    let isRefreshing: Bool
    let hasIssues: Bool
    var pendingWorktreeCount: Int = 0
    var showsOnlyPendingWorktrees: Binding<Bool>?

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)

            Text("AgentGit")
                .font(.system(size: 12.5, weight: .semibold))

            Spacer(minLength: 6)

            if pendingWorktreeCount > 0 {
                pendingCountLabel
            }

            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .help(statusLabel)
                .accessibilityLabel(statusLabel)
        }
    }

    /// 这个计数以前只是展示。它是侧栏里唯一「现在该我做点什么」的信号，做成筛选开关：
    /// 点一下只留下待处理的 worktree，再点一下恢复全部。
    @ViewBuilder
    private var pendingCountLabel: some View {
        let title = "\(pendingWorktreeCount) pending"
        if let showsOnlyPendingWorktrees {
            let isOn = showsOnlyPendingWorktrees.wrappedValue
            Button {
                showsOnlyPendingWorktrees.wrappedValue.toggle()
            } label: {
                Text(title)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(
                        isOn ? Color.white : Color(nsColor: .systemOrange)
                    )
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        isOn
                            ? Color(nsColor: .systemOrange)
                            : Color(nsColor: .systemOrange).opacity(0.13),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .help(
                isOn
                    ? "Showing only worktrees that need attention"
                    : "Show only worktrees that need attention"
            )
            .accessibilityLabel(
                isOn
                    ? "Showing only the \(pendingWorktreeCount) worktrees that need attention"
                    : "Show only the \(pendingWorktreeCount) worktrees that need attention"
            )
        } else {
            Text(title)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Color(nsColor: .systemOrange))
        }
    }

    private var statusColor: Color {
        if hasIssues {
            return .orange
        }
        return isRefreshing ? .blue : .green
    }

    private var statusLabel: String {
        if hasIssues {
            return "Repository attention required"
        }
        return isRefreshing ? "Refreshing repositories" : "Repositories ready"
    }
}

struct SidebarSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(.secondary)
            TextField("Filter projects and worktrees", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
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
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.78))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 7)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
    }
}

struct AgentGitWorkspaceEmptyState: View {
    let title: String
    let detail: String
    let systemImage: String
    var isLoading = false
    var actionTitle: String?
    var action: (() -> Void)?

    init(
        title: String,
        detail: String,
        systemImage: String,
        isLoading: Bool = false,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.isLoading = isLoading
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: AgentGitPalette.canvas),
                    Color.accentColor.opacity(0.018)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.accentColor.opacity(0.09))
                    if isLoading {
                        ProgressView()
                            .controlSize(.regular)
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(width: 54, height: 54)

                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)

                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .controlSize(.regular)
                }
            }
            .padding(28)
            .background(
                Color(nsColor: AgentGitPalette.reviewControlBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.secondary.opacity(0.09), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.025), radius: 10, y: 2)
        }
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
    pinnedWorktreeIDs: Set<GitWorktreeSnapshot.ID> = [],
    showsAll: Bool,
    now: Date
) -> ProjectWorktreePresentation {
    let recentCutoff = now.addingTimeInterval(-24 * 60 * 60)
    // 置顶的排在本项目最前，其余保持按活动时间的顺序。
    let orderedWorktrees = snapshot.worktrees.sorted { lhs, rhs in
        let lhsPinned = pinnedWorktreeIDs.contains(lhs.id)
        let rhsPinned = pinnedWorktreeIDs.contains(rhs.id)
        guard lhsPinned == rhsPinned else {
            return lhsPinned
        }
        return compareWorktreeSnapshots(lhs, rhs)
    }
    let pinned = orderedWorktrees.filter { pinnedWorktreeIDs.contains($0.id) }
    let unpinned = orderedWorktrees.filter { !pinnedWorktreeIDs.contains($0.id) }
    // 折叠时置顶的永远露出来，不占“最近四个”的名额，也不会被选中项挤掉。
    var recentWorktrees = Array(
        unpinned.filter { worktree in
            worktree.status.changedFileCount > 0
                || !worktree.diffStat.isEmpty
                || worktree.lastActivityAt >= recentCutoff
        }.prefix(4)
    )
    if let selected = unpinned.first(where: { $0.id == selectedWorktreeID }),
       !recentWorktrees.contains(where: { $0.id == selected.id }) {
        if recentWorktrees.count == 4 {
            recentWorktrees.removeLast()
        }
        recentWorktrees.append(selected)
    }
    let defaultWorktrees = pinned + recentWorktrees
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
            .padding(.leading, 32)
            .frame(height: 27)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
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
                Image(systemName: "folder.fill")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.accentColor.opacity(0.76))
                    .frame(width: 13)
                Text(projectState.project.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.84))
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
                        .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.07), in: Capsule())
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 7)
            .frame(height: 31)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isHovered
                            ? Color(nsColor: AgentGitPalette.sidebarHover)
                            : Color.clear
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .padding(.top, showsDivider ? 1 : 0)
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
    var isPinned = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 7) {
            worktreeStateIndicator
                .frame(width: 10, alignment: .center)

            VStack(alignment: .leading, spacing: 0) {
                Text(snapshot.worktree.displayName)
                    .font(
                        .system(
                            size: 12,
                            weight: isSelected ? .medium : .regular
                        )
                    )
                    .foregroundStyle(primaryForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(snapshot.worktree.rootURL.lastPathComponent)
                    .font(.system(size: 10))
                    .foregroundStyle(
                        isSelected
                            ? primaryForeground.opacity(0.72)
                            : Color.secondary.opacity(0.78)
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }

            trailingStatus
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.leading, 15)
        .padding(.trailing, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 32)
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
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color(nsColor: AgentGitPalette.sidebarSelectionBorder))
                    .frame(width: 3, height: 20)
                    .padding(.leading, 1)
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
        .primary
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
        } else if let indicator = reviewStatus.compactIndicator {
            Text(indicator)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Color(nsColor: AgentGitPalette.worktreeTracking))
                .accessibilityLabel(reviewStatus.accessibilityDescription)
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

    private var reviewStatus: WorktreeReviewStatus {
        worktreeReviewStatus(snapshot)
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
        if isPinned {
            components.append("Pinned to top")
        }
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
