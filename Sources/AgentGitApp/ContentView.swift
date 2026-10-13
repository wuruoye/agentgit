import AgentGitCore
import AppKit
import SwiftUI

enum SidebarLayoutMetrics {
    static let visibleWidth: CGFloat = 280
    // NavigationSplitView adds an 8pt sidebar container inset on macOS.
    static let navigationContentWidth = visibleWidth - 8
}

private enum SidebarDestination: Hashable {
    case overview
    case worktree(String)
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.fontScaleSettings) private var suppliedFontSettings
    @State private var viewportWidth = CGFloat.infinity
    private var fontSettings: FontScaleSettings { suppliedFontSettings ?? .shared }
    private var usesCompactFontLayout: Bool { viewportWidth / fontSettings.scale < 1_100 }
    @State private var sidebarBeforeFontScale: NavigationSplitViewVisibility?
    @State private var projectsShowingAllWorktrees: Set<GitProject.ID> = []
    @State private var sidebarFilterText = ""
    @State private var showsOnlyPendingWorktrees = false
    @State private var projectDropTargetID: GitProject.ID?
    @State private var showsOverview = false
    @State private var isReviewFocused = false
    @State private var sidebarBeforeFocus: NavigationSplitViewVisibility = .all
    // 项目列表是进入一切的入口，启动一律显示；上次被拖到隐藏也要回来。
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    init(initialSidebarFilterText: String = "") {
        _sidebarFilterText = State(initialValue: initialSidebarFilterText)
    }

    var body: some View {
        VStack(spacing: 0) {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            FontScaleViewport {
            VStack(spacing: 0) {
                AgentGitSidebarBrandView(
                    isRefreshing: model.projects.contains(where: \.isLoading),
                    hasIssues: sidebarHasIssues,
                    pendingWorktreeCount: pendingWorktreeCount,
                    showsOnlyPendingWorktrees: $showsOnlyPendingWorktrees
                )
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 5)
                SidebarSearchField(text: $sidebarFilterText)

                List(selection: sidebarSelection) {
                    Label {
                        HStack {
                            Text("All Worktrees")
                            Spacer()
                            Text(sidebarWorktrees.count.formatted())
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    } icon: {
                        Image(systemName: "square.grid.2x2")
                    }
                    .tag(SidebarDestination.overview)
                    .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 8))

                    Section {
                        ForEach(Array(filteredProjects.enumerated()), id: \.element.id) {
                            projectIndex, projectState in
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
                                .listRowInsets(EdgeInsets(top: 6, leading: 2, bottom: 0, trailing: 2))

                                if !model.collapsedProjectIDs.contains(projectState.id)
                                    || !sidebarFilterQuery.isEmpty {
                                    projectContents(projectState)
                                }
                        }
                    } header: {
                        HStack {
                            Text("Projects")
                            Spacer()
                            Button(action: model.chooseProject) {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.plain)
                            .help("Add Project (⌘O)")
                            .accessibilityLabel("Add Project")
                        }
                    }
                }
                .listStyle(.sidebar)
                .listRowSeparator(.hidden)
                .environment(\.defaultMinListRowHeight, 28)
                .overlay {
                    if !sidebarFilterQuery.isEmpty, filteredProjects.isEmpty {
                        SidebarNoResultsView(query: sidebarFilterQuery) {
                            sidebarFilterText = ""
                        }
                    }
                }
                sidebarFooter
            }
            }
            .navigationSplitViewColumnWidth(
                min: 240 * fontSettings.scale,
                ideal: SidebarLayoutMetrics.navigationContentWidth * fontSettings.scale,
                max: 360 * fontSettings.scale
            )
            .tint(Color(nsColor: AgentGitPalette.sidebarSelectionBorder))
        } detail: {
            FontScaleViewport {
            VStack(spacing: 0) {
                ZStack {
                    reviewContent
                        .environment(\.isReviewVisible, !showsOverview)
                        .opacity(showsOverview ? 0 : 1)
                        .allowsHitTesting(!showsOverview)
                        .disabled(showsOverview)
                        .accessibilityHidden(showsOverview)
                    if showsOverview {
                        WorktreeOverview(select: openWorktree)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onChange(of: geometry.size.width, initial: true) { _, width in viewportWidth = width }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.isWorktreeSwitcherPresented = true
                } label: {
                    Label("Worktrees", systemImage: "rectangle.on.rectangle")
                }
                .labelStyle(.titleAndIcon)
                .help("Switch Worktree (⌘P)")
                .disabled(!model.hasAvailableWorktrees)
            }
        }
        .onChange(of: usesCompactFontLayout, initial: true) { _, compact in
            if compact {
                if sidebarBeforeFontScale == nil {
                    sidebarBeforeFontScale = isReviewFocused ? sidebarBeforeFocus : sidebarVisibility
                }
                if isReviewFocused { sidebarBeforeFocus = .detailOnly }
                else { sidebarVisibility = .detailOnly }
            } else if let saved = sidebarBeforeFontScale {
                if isReviewFocused { sidebarBeforeFocus = saved }
                else { sidebarVisibility = saved }
                sidebarBeforeFontScale = nil
            }
        }
        .onChange(of: isReviewFocused) { _, focused in
            if focused {
                sidebarBeforeFocus = sidebarVisibility
                sidebarVisibility = .detailOnly
            } else {
                sidebarVisibility = sidebarBeforeFocus
            }
        }
        .onChange(of: showsOverview) { _, visible in
            if visible { isReviewFocused = false }
        }
        .onChange(of: model.selectedWorktreeID) { _, id in
            if id != nil {
                showsOverview = false
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
            WorktreeSwitcherView(onOpen: openWorktree)
                .environment(model)
                .scaledFontPresentation(width: 620, height: 500)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 路径和错误提示栏与 split view 并列，避免被 diff 覆盖。
            VStack(spacing: 0) {
                if model.projectAdditionError != nil
                    || model.agentAssociations.errorMessage != nil
                    || model.cacheErrorMessage != nil {
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
                    Divider()
                }
                if let snapshot = model.selectedWorktree {
                    Divider()
                    FontScaleViewport { worktreePathBar(snapshot.worktree.rootURL) }
                        .frame(height: 28 * fontSettings.scale)
                }
            }
            .background(.bar)
        }
    }

    private var sidebarSelection: Binding<SidebarDestination?> {
        Binding(
            get: {
                showsOverview ? .overview : model.selectedWorktreeID.map(SidebarDestination.worktree)
            },
            set: { destination in
                switch destination {
                case .overview: showsOverview = true
                case let .worktree(id): openWorktree(id)
                case nil: break
                }
            }
        )
    }

    private var windowTitle: String {
        guard !showsOverview, let worktree = model.selectedWorktree else {
            return showsOverview ? "All Worktrees" : "AgentGit"
        }
        return model.projects.first(where: {
            $0.snapshot?.worktrees.contains(where: { $0.id == worktree.id }) == true
        })?.project.displayName ?? worktree.worktree.rootURL.lastPathComponent
    }

    private var windowSubtitle: String {
        showsOverview ? "\(sidebarWorktrees.count) worktrees" : model.selectedWorktree?.worktree.displayName ?? "Git Workspace"
    }

    @ViewBuilder
    private var reviewContent: some View {
            if let snapshot = model.selectedWorktree {
                WorktreeReviewView(snapshot: snapshot, focusMode: $isReviewFocused)
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

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            Spacer()
            Button {
                model.isWorktreeSwitcherPresented = true
            } label: {
                Text("⌘ P")
                    .font(.agentGitInterface(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("Quick switch worktree")
        }
        .font(.agentGitInterface(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 19)
        .frame(height: 36)
        .overlay(alignment: .top) { Color(nsColor: AgentGitPalette.separator).frame(height: 1) }
    }

    private func openWorktree(_ id: String) {
        guard sidebarWorktrees.contains(where: { $0.id == id }) else { return }
        showsOverview = false
        if model.selectWorktree(id: id) {
            Task { await model.refreshSelectedWorktree() }
        }
    }

    /// 显示当前 worktree 路径、数量和 Git 状态。
    private func worktreePathBar(_ url: URL) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.agentGitInterface(size: 10))
                .foregroundStyle(.secondary)
            Text((url.path as NSString).abbreviatingWithTildeInPath)
                .font(.agentGitInterface(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text(countedLabel(sidebarWorktrees.count, singular: "worktree"))
                .font(.agentGitInterface(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
            Circle().fill(Color(nsColor: AgentGitPalette.statusAdded)).frame(width: 5, height: 5)
            Text("Local Git").font(.agentGitInterface(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .contentShape(Rectangle())
        .help(url.path)
        .onTapGesture(count: 2) {
            revealInFinder(url)
        }
        .contextMenu {
            Button("Copy Path") {
                copyToPasteboard(url.path)
            }
            Button("Reveal in Finder") {
                revealInFinder(url)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Worktree path")
        .accessibilityValue(url.path)
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
                .font(.agentGitInterface(.caption))
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
        Toggle("Exclude from Automatic Cleanup", isOn: Binding(
            get: { model.isProjectExcludedFromCleanup(id: projectState.id) },
            set: { model.setProjectCleanupExcluded($0, id: projectState.id) }
        ))
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
            let locationLabels = worktreeLocationLabels(snapshot.worktrees.map(\.worktree))
            ForEach(presentation.visibleWorktrees) { worktree in
                Button {
                    openWorktree(worktree.id)
                } label: {
                    WorktreeRow(
                        snapshot: worktree,
                        locationLabel: locationLabels[worktree.id],
                        isSelected: !showsOverview && model.selectedWorktreeID == worktree.id,
                        isPinned: model.isWorktreePinned(id: worktree.id)
                    )
                }
                    .buttonStyle(.plain)
                    .tag(SidebarDestination.worktree(worktree.id))
                    .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
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
                .frame(width: 22, height: 22)

            Text("AgentGit")
                .font(.agentGitInterface(size: 13, weight: .semibold))

            Spacer(minLength: 6)

            // 筛选开着时计数归零也要留着按钮，否则没有地方关掉筛选。
            if pendingWorktreeCount > 0 || showsOnlyPendingWorktrees?.wrappedValue == true {
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
                    .font(.agentGitInterface(size: 10.5).monospacedDigit())
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
                .font(.agentGitInterface(size: 10.5).monospacedDigit())
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
                .font(.agentGitInterface(size: 12.5, weight: .regular))
                .foregroundStyle(.secondary)
            TextField("Filter worktrees…", text: $text)
                .accessibilityLabel("Filter projects and worktrees")
                .textFieldStyle(.plain)
                .font(.agentGitInterface(size: 12))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.agentGitInterface(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Filter")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
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
                            .font(.agentGitInterface(size: 22, weight: .regular))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(width: 54, height: 54)

                Text(title)
                    .font(.agentGitInterface(size: 17, weight: .semibold))
                Text(detail)
                    .font(.agentGitInterface(size: 11.5))
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
                .font(.agentGitInterface(size: 25, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No Matching Worktrees")
                .font(.agentGitInterface(.headline))
            Text("No project or worktree matches “\(query)”.")
                .font(.agentGitInterface(.caption))
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
                .font(.agentGitInterface(.caption).weight(.semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.agentGitInterface(.caption2))
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
    let hasChanges = { (worktree: GitWorktreeSnapshot) in
        worktree.status.changedFileCount > 0 || !worktree.diffStat.isEmpty
    }
    // 折叠时置顶的永远露出来，不占“最近四个”的名额，也不会被选中项挤掉。
    var recentWorktrees = Array(
        unpinned.filter { worktree in
            hasChanges(worktree) || worktree.lastActivityAt >= recentCutoff
        }.prefix(4)
    )
    // 选中项本来就会显示（有改动）时不占名额，否则换选中项会让别的行时隐时现。
    if let selected = unpinned.first(where: { $0.id == selectedWorktreeID }),
       !hasChanges(selected),
       !recentWorktrees.contains(where: { $0.id == selected.id }) {
        if recentWorktrees.count == 4 {
            recentWorktrees.removeLast()
        }
        recentWorktrees.append(selected)
    }
    // 有改动的 worktree 不受四条上限影响，也不能被选中项挤出折叠列表。
    let retainedIDs = Set((pinned + recentWorktrees).map(\.id))
    let defaultWorktrees = orderedWorktrees.filter {
        retainedIDs.contains($0.id) || hasChanges($0)
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
                    .font(.agentGitInterface(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.agentGitInterface(size: 10.5))
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
                    .font(.agentGitInterface(.caption2).weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
                Image(systemName: "folder")
                    .font(.agentGitInterface(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.accentColor.opacity(0.76))
                    .frame(width: 13)
                Text(projectState.project.displayName)
                    .font(.agentGitInterface(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                    .lineLimit(1)
                if projectState.errorMessage != nil {
                    Image(
                        systemName: projectState.snapshot == nil
                            ? "xmark.octagon.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .font(.agentGitInterface(.caption2))
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
                        .font(.agentGitInterface(size: 9.5, weight: .semibold).monospacedDigit())
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
    var locationLabel: String? = nil
    var isSelected = false
    var isPinned = false

    var body: some View {
        HStack(spacing: 9) {
            worktreeStateIndicator.frame(width: 12)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(snapshot.worktree.displayName)
                        .font(.agentGitInterface(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(primaryForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if isPinned {
                        Image(systemName: "pin.fill").font(.agentGitInterface(size: 8)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text(location)
                        .font(.agentGitInterface(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 2)
                    trailingStatus.fixedSize()
                }
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 42)
        .contentShape(Rectangle())
        .help(worktreeRowHelpText(snapshot))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(worktreeAccessibilityLabel)
        .accessibilityHint(worktreeRowHelpText(snapshot))
    }

    @ViewBuilder
    private var worktreeStateIndicator: some View {
        if snapshot.errorMessage != nil {
            Image(systemName: issueIconName)
                .font(.agentGitInterface(size: 8, weight: .semibold))
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
            .font(.agentGitInterface(size: 10.5).monospacedDigit())
            .accessibilityLabel(
                "+\(snapshot.diffStat.addedLineCount), −\(snapshot.diffStat.deletedLineCount)"
            )
        } else if snapshot.status.changedFileCount > 0 {
            Text("\(snapshot.status.changedFileCount)")
                .font(.agentGitInterface(size: 10.5).monospacedDigit())
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
                .font(.agentGitInterface(size: 10.5).monospacedDigit())
                .foregroundStyle(Color(nsColor: AgentGitPalette.worktreeTracking))
                .accessibilityLabel(reviewStatus.accessibilityDescription)
        } else if snapshot.lastActivityAt == .distantPast {
            Text("—")
                .font(.agentGitInterface(size: 10.5))
                .foregroundStyle(Color(nsColor: AgentGitPalette.sidebarMetadata))
        } else {
            Text(compactRelativeTime(snapshot.lastActivityAt))
                .font(.agentGitInterface(size: 10.5).monospacedDigit())
                .foregroundStyle(Color(nsColor: AgentGitPalette.sidebarMetadata))
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
        components.append(location)
        return components.joined(separator: ", ")
    }

    private var location: String {
        locationLabel ?? snapshot.worktree.rootURL.lastPathComponent
    }
}

/// 列表第二行显示的目录名。同一项目里目录名重复时带上父目录，比如 `worktree-test/agentgit`。
func worktreeLocationLabels(_ worktrees: [GitWorktree]) -> [GitWorktree.ID: String] {
    let nameCounts = Dictionary(grouping: worktrees, by: \.rootURL.lastPathComponent)
        .mapValues(\.count)
    return Dictionary(uniqueKeysWithValues: worktrees.map { worktree in
        let name = worktree.rootURL.lastPathComponent
        guard nameCounts[name, default: 0] > 1 else {
            return (worktree.id, name)
        }
        return (worktree.id, worktree.rootURL.deletingLastPathComponent().lastPathComponent + "/" + name)
    })
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
