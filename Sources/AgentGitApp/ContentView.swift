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
    @Environment(\.fontScaleSettings) private var suppliedFontSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
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
    @FocusState private var isSidebarListFocused: Bool
    @State private var sidebarKeyboardTargetID: String?

    init(initialSidebarFilterText: String = "") {
        _sidebarFilterText = State(initialValue: initialSidebarFilterText)
    }

    var body: some View {
        VStack(spacing: 0) {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            FontScaleViewport { sidebar }
            .navigationSplitViewColumnWidth(
                min: 240 * fontSettings.scale,
                ideal: SidebarLayoutMetrics.navigationContentWidth * fontSettings.scale,
                max: 480 * fontSettings.scale
            )
            .tint(Color(nsColor: AgentGitPalette.sidebarSelectionBorder))
        } detail: {
            VStack(spacing: 0) {
                ZStack {
                    reviewContent
                        .environment(\.isReviewVisible, !showsOverview)
                        .opacity(showsOverview ? 0 : 1)
                        .allowsHitTesting(!showsOverview)
                        .disabled(showsOverview)
                        .accessibilityHidden(showsOverview)
                    if showsOverview {
                        FontScaleViewport { WorktreeOverview(select: openWorktree) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .toolbarBackground(Color(nsColor: AgentGitPalette.canvas), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.isWorktreeSwitcherPresented = true
                } label: {
                    Label("Worktrees", systemImage: "rectangle.on.rectangle")
                }
                .labelStyle(.iconOnly)
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
            withAnimation(WorkspaceMotion.layout(reduceMotion: reduceMotion)) {
                if focused {
                    sidebarBeforeFocus = sidebarVisibility
                    sidebarVisibility = .detailOnly
                } else {
                    sidebarVisibility = sidebarBeforeFocus
                }
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
            .background(Color(nsColor: AgentGitPalette.canvas))
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            SidebarSearchField(text: $sidebarFilterText)
            sidebarNavigation
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(sidebarProjects) { state in
                            VStack(alignment: .leading, spacing: 0) {
                                sidebarProjectHeader(state)
                                if !model.collapsedProjectIDs.contains(state.id) || !sidebarFilterQuery.isEmpty {
                                    projectContents(state)
                                        .padding(.top, 2)
                                }
                            }
                        }
                    }
                    .padding(.leading, SidebarStyle.rowInset)
                    .padding(.trailing, SidebarStyle.rowTrailingInset)
                    .padding(.top, 25.5)
                    .padding(.bottom, 20)
                }
                .focusable()
                .focused($isSidebarListFocused)
                .focusEffectDisabled()
                .accessibilityLabel("Worktrees")
                .onKeyPress(.upArrow) { moveSidebarSelection(by: -1); return .handled }
                .onKeyPress(.downArrow) { moveSidebarSelection(by: 1); return .handled }
                .onChange(of: sidebarKeyboardTargetID) { _, id in
                    if let id { scrollProxy.scrollTo(id) }
                }
                .overlay {
                    if !sidebarFilterQuery.isEmpty, filteredProjects.isEmpty {
                        SidebarNoResultsView(query: sidebarFilterQuery) { sidebarFilterText = "" }
                    }
                }
            }
        }
        .background(Color(nsColor: SidebarStyle.background))
    }

    private var sidebarNavigation: some View {
        VStack(spacing: 0) {
            Button(action: model.chooseProject) {
                SidebarNavigationLabel(title: "New", icon: .plus, isNew: true)
            }
            .help("Add a Git repository (⌘O)")
            .accessibilityLabel("Add Project")
            Button { showsOverview = true } label: {
                SidebarNavigationLabel(title: "Projects", icon: .projects, isSelected: showsOverview)
            }
            .buttonStyle(SidebarRowButtonStyle(isSelected: showsOverview))
            .help("All projects and worktrees")
            Button { model.isWorktreeSwitcherPresented = true } label: {
                SidebarNavigationLabel(title: "Worktrees", icon: .worktrees)
            }
            .help("Switch Worktree (⌘P)")
            SettingsLink {
                SidebarNavigationLabel(title: "Customize", icon: .briefcase)
            }
            .help("Settings (⌘,)")
            Menu {
                Toggle("Only Worktrees Needing Attention", isOn: $showsOnlyPendingWorktrees)
                Button("Refresh All Projects") { Task { await model.refreshAll() } }
                Button("Switch Worktree") { model.isWorktreeSwitcherPresented = true }
            } label: {
                SidebarNavigationLabel(title: "More", icon: .more)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(SidebarRowButtonStyle(showsPressedState: false))
            .help(showsOnlyPendingWorktrees ? "Showing \(pendingWorktreeCount) worktrees needing attention" : "More options")
        }
        .buttonStyle(SidebarRowButtonStyle())
        .padding(.leading, SidebarStyle.rowInset)
        .padding(.trailing, SidebarStyle.rowTrailingInset)
    }

    private func sidebarProjectHeader(_ state: ProjectState) -> some View {
        return HStack(spacing: 0) {
            ProjectHeader(
                projectState: state,
                isCollapsed: model.collapsedProjectIDs.contains(state.id),
                toggle: { model.toggleProjectCollapsed(id: state.id) }
            )
        }
        .background(projectDropTargetID == state.id ? Color(nsColor: SidebarStyle.selection) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .draggable(state.id)
        .dropDestination(for: String.self) { projectIDs, location in
            projectDropTargetID = nil
            guard let projectID = projectIDs.first, model.projects.contains(where: { $0.id == projectID }) else { return false }
            model.moveProject(id: projectID, relativeTo: state.id, placeAfterTarget: location.y >= 14)
            return true
        } isTargeted: { targeted in
            projectDropTargetID = targeted ? state.id : nil
        }
        .contextMenu { projectContextMenu(state) }
    }

    private var sidebarProjects: [ProjectState] {
        filteredProjects.filter { state in
            let presentation = sidebarPresentation(state)
            return state.snapshot == nil || state.errorMessage != nil || state.isLoading
                || !presentation.visibleWorktrees.isEmpty || presentation.hiddenWorktreeCount > 0
        }
    }

    private func moveSidebarSelection(by offset: Int) {
        let items = sidebarProjects.flatMap { state in
            model.collapsedProjectIDs.contains(state.id) && sidebarFilterQuery.isEmpty
                ? [] : sidebarPresentation(state).visibleWorktrees
        }
        guard !items.isEmpty else { return }
        let current = items.firstIndex(where: { $0.id == model.selectedWorktreeID }) ?? (offset > 0 ? -1 : items.count)
        let target = items[min(items.count - 1, max(0, current + offset))]
        openWorktree(target.id)
        sidebarKeyboardTargetID = target.id
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
            } else {
                FontScaleViewport { emptyReviewContent }
            }
    }

    @ViewBuilder
    private var emptyReviewContent: some View {
            if model.projects.isEmpty {
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
                matchesSidebarFilter($0)
            }) == true
        }
    }

    private var sidebarWorktrees: [GitWorktreeSnapshot] {
        model.projects.compactMap(\.snapshot).flatMap(\.worktrees)
    }

    private func matchesSidebarFilter(_ snapshot: GitWorktreeSnapshot) -> Bool {
        if worktreeMatchesSidebarFilter(snapshot, query: sidebarFilterQuery) { return true }
        let sessions = model.agentAssociations.associations(for: snapshot.worktree)
        let creator = model.agentAssociations.creatorAssociation(forWorktreeAt: snapshot.id)
        return (sessions + (creator.map { [$0] } ?? [])).contains {
            model.agentAssociations.displayTitle(for: $0).localizedStandardContains(sidebarFilterQuery)
                || $0.provider.displayName.localizedStandardContains(sidebarFilterQuery)
        }
    }

    private var pendingWorktreeCount: Int {
        sidebarWorktrees.count { worktreeReviewStatus($0).needsAttention }
    }

    private func openOpenWithSettings(projectID: GitProject.ID) {
        model.requestedSettingsDestination = AgentGitSettingsDestination(
            section: .openWith,
            projectID: projectID
        )
        openSettings()
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
        Button("Customize Open With…") {
            openOpenWithSettings(projectID: projectState.id)
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

        if state.snapshot != nil {
            let presentation = sidebarPresentation(state)
            ForEach(presentation.visibleWorktrees) { worktree in
                sidebarWorktreeButton(worktree, projectID: state.id)
            }
            if presentation.hiddenWorktreeCount > 0 {
                let showsAll = projectsShowingAllWorktrees.contains(state.id)
                Button {
                    if showsAll { projectsShowingAllWorktrees.remove(state.id) }
                    else { projectsShowingAllWorktrees.insert(state.id) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showsAll ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .regular))
                            .frame(width: 12)
                        Text(showsAll ? "Show Less" : "Show \(presentation.hiddenWorktreeCount) More Worktrees")
                            .font(SidebarStyle.font(SidebarStyle.detailSize))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Color(nsColor: SidebarStyle.secondary))
                    .padding(.horizontal, SidebarStyle.rowContentInset)
                    .frame(height: SidebarStyle.groupHeight)
                }
                .buttonStyle(SidebarRowButtonStyle())
                .help(showsAll ? "Show recent worktrees only" : "Show all worktrees in \(state.project.displayName)")
                .accessibilityLabel("\(showsAll ? "Show Less" : "Show More Worktrees") in \(state.project.displayName)")
            }
        }
    }

    private func sidebarPresentation(_ state: ProjectState) -> ProjectWorktreePresentation {
        guard let snapshot = state.snapshot else { return ProjectWorktreePresentation(visibleWorktrees: [], hiddenWorktreeCount: 0) }
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
                                matchesSidebarFilter($0)
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
                            matchesSidebarFilter($0)
                        }
                ),
                hiddenWorktreeCount: 0
            )
        }
        return presentation
    }

    private func sidebarWorktreeButton(
        _ worktree: GitWorktreeSnapshot,
        projectID: GitProject.ID
    ) -> some View {
        Button {
            openWorktree(worktree.id)
            isSidebarListFocused = true
        } label: {
            WorktreeRow(
                snapshot: worktree,
                isPinned: model.isWorktreePinned(id: worktree.id),
                isSelected: !showsOverview && model.selectedWorktreeID == worktree.id
            )
        }
            .buttonStyle(SidebarRowButtonStyle(isSelected: !showsOverview && model.selectedWorktreeID == worktree.id))
            .id(worktree.id)
            .accessibilityAddTraits(!showsOverview && model.selectedWorktreeID == worktree.id ? .isSelected : [])
            .contextMenu {
                let linkedSessions = model.agentAssociations.sessionAssociations(for: worktree.worktree)
                ForEach(linkedSessions) { association in
                    Button("Open \(model.agentAssociations.displayTitle(for: association))") {
                        model.agentAssociations.open(association)
                    }
                }
                if !linkedSessions.isEmpty { Divider() }
                Button(
                    model.isWorktreePinned(id: worktree.id)
                        ? "Unpin in Project"
                        : "Pin to Top of Project"
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
                WorktreeOpenWithMenuItems(
                    entries: model.openWithSettings.entries(for: projectID),
                    worktreeRootURL: worktree.worktree.rootURL
                )
                Button("Customize Open With…") {
                    openOpenWithSettings(projectID: projectID)
                }
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
}


struct SidebarSearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            SidebarIcon(kind: .search)
                .frame(width: 16, height: 16)
                .foregroundStyle(Color(nsColor: SidebarStyle.secondary))
            TextField("", text: $text)
                .accessibilityLabel("Filter projects and worktrees")
                .help("Search branches, sessions, or projects")
                .textFieldStyle(.plain)
                .font(SidebarStyle.font(SidebarStyle.bodySize))
                .foregroundStyle(Color(nsColor: SidebarStyle.primary))
                .focused($isFocused)
                .overlay(alignment: .leading) {
                    if text.isEmpty {
                        Text("Search")
                            .font(SidebarStyle.font(SidebarStyle.bodySize))
                            .foregroundStyle(Color(nsColor: SidebarStyle.secondary))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            Button {
                text = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.agentGitInterface(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear Filter")
            .workspaceControlSlot(isVisible: !text.isEmpty)
        }
        .padding(.horizontal, 12)
        .frame(height: 31)
        .background(Color(nsColor: SidebarStyle.searchBackground), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color(nsColor: SidebarStyle.searchBorder), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.065), radius: 1.5, y: 1)
        .padding(.leading, 12)
        .padding(.trailing, 15)
        .padding(.top, 21)
        .padding(.bottom, 9)
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
            Color(nsColor: AgentGitPalette.canvas).ignoresSafeArea()

            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color(nsColor: AgentGitPalette.inputBackground))
                    if isLoading {
                        ProgressView()
                            .controlSize(.regular)
                    } else {
                        Image(systemName: systemImage)
                            .font(.agentGitInterface(size: 22, weight: .regular))
                            .foregroundStyle(Color(nsColor: AgentGitPalette.activeControl))
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
                        .buttonStyle(ReviewToolbarButtonStyle(kind: .primary))
                }
            }
            .padding(28)
            .modifier(WorkspacePanelStyle())
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
    let activeCutoff = now.addingTimeInterval(-60 * 60)
    // 置顶的排在本项目最前，其余保持按活动时间的顺序。
    let orderedWorktrees = snapshot.worktrees.sorted { lhs, rhs in
        let lhsPinned = pinnedWorktreeIDs.contains(lhs.id)
        let rhsPinned = pinnedWorktreeIDs.contains(rhs.id)
        guard lhsPinned == rhsPinned else {
            return lhsPinned
        }
        return compareWorktreeSnapshots(lhs, rhs)
    }
    let hasChanges = { (worktree: GitWorktreeSnapshot) in
        worktree.status.changedFileCount > 0 || !worktree.diffStat.isEmpty
    }
    let retainedWorktrees = orderedWorktrees.filter {
        pinnedWorktreeIDs.contains($0.id)
            || hasChanges($0)
            || $0.id == selectedWorktreeID
            || $0.lastActivityAt >= activeCutoff
    }
    // 每个非空项目至少显示一个 worktree。
    let defaultWorktrees = retainedWorktrees.isEmpty
        ? Array(orderedWorktrees.prefix(1))
        : retainedWorktrees
    return ProjectWorktreePresentation(
        visibleWorktrees: showsAll ? orderedWorktrees : defaultWorktrees,
        hiddenWorktreeCount: orderedWorktrees.count - defaultWorktrees.count
    )
}


struct ProjectHeader: View {
    let projectState: ProjectState
    let isCollapsed: Bool
    let toggle: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Text(projectState.project.displayName)
                    .font(SidebarStyle.font(SidebarStyle.projectTitleSize))
                    .foregroundStyle(Color(nsColor: SidebarStyle.primary))
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
                Image(systemName: "chevron.right")
                    .font(.agentGitInterface(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12, height: 12)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .opacity(isHovered || isCollapsed ? 1 : 0)
                    .animation(WorkspaceMotion.layout(reduceMotion: reduceMotion), value: isCollapsed)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, SidebarStyle.rowContentInset)
            .frame(height: SidebarStyle.groupHeight)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(WorkspaceMotion.hover(reduceMotion: reduceMotion), value: isHovered)
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
    private static let activityDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    @Environment(AppModel.self) private var model
    let snapshot: GitWorktreeSnapshot
    var isPinned = false
    var isSelected = false

    var body: some View {
        let linkedTitle = linkedSessionTitle
        let sessionLabel = linkedTitle ?? "No linked session"
        let detailText = makeDetails(sessionLabel: sessionLabel)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(snapshot.worktree.displayName)
                    .font(SidebarStyle.font(SidebarStyle.titleSize))
                    .foregroundStyle(Color(nsColor: isSelected ? SidebarStyle.selectedText : SidebarStyle.primary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: SidebarStyle.secondary))
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 23, alignment: .leading)
            if let linkedTitle {
                Text(linkedTitle)
                    .font(SidebarStyle.font(SidebarStyle.detailSize))
                    .foregroundStyle(Color(nsColor: SidebarStyle.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: 21, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SidebarStyle.rowContentInset)
        .padding(.vertical, SidebarStyle.worktreeVerticalInset)
        .frame(
            height: linkedTitle == nil
                ? SidebarStyle.singleLineWorktreeHeight
                : SidebarStyle.worktreeHeight,
            alignment: .top
        )
        .contentShape(Rectangle())
        .help(detailText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(snapshot.worktree.displayName), \(sessionLabel)")
        .accessibilityHint(detailText)
    }

    private var linkedSessionTitle: String? {
        let association = model.agentAssociations.creatorAssociation(forWorktreeAt: snapshot.id)
            ?? model.agentAssociations.associations(for: snapshot.worktree).first
        guard let association else { return nil }
        return model.agentAssociations.displayTitle(for: association)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func makeDetails(sessionLabel: String) -> String {
        var sections = [sessionLabel, worktreeRowHelpText(snapshot)]
        if snapshot.status.changedFileCount > 0 {
            sections.append(countedLabel(snapshot.status.changedFileCount, singular: "changed file"))
        }
        if !snapshot.diffStat.isEmpty {
            sections.append("+\(snapshot.diffStat.addedLineCount), −\(snapshot.diffStat.deletedLineCount)")
        }
        if snapshot.lastActivityAt != .distantPast {
            sections.append("Last activity: \(Self.activityDateFormatter.string(from: snapshot.lastActivityAt))")
        }
        if isPinned { sections.append("Pinned to top of project") }
        return sections.joined(separator: "\n")
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
