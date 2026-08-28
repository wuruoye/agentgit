import AgentGitCore
import AgentGitIntegrationShared
import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var projectsShowingAllWorktrees: Set<GitProject.ID> = []
    @State private var sidebarFilterText = ""

    init(initialSidebarFilterText: String = "") {
        _sidebarFilterText = State(initialValue: initialSidebarFilterText)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: worktreeSelection) {
                ForEach(filteredProjects) { projectState in
                    Section {
                        if !model.collapsedProjectIDs.contains(projectState.id)
                            || !sidebarFilterQuery.isEmpty {
                            projectContents(projectState)
                        }
                    } header: {
                        ProjectHeader(
                            projectState: projectState,
                            isCollapsed: model.collapsedProjectIDs.contains(projectState.id),
                            toggle: {
                                model.toggleProjectCollapsed(id: projectState.id)
                            }
                        )
                            .frame(minHeight: 22)
                            .draggable(projectState.id) {
                                Label(
                                    projectState.project.displayName,
                                    systemImage: "folder"
                                )
                            }
                            .dropDestination(for: String.self) {
                                projectIDs,
                                location in
                                guard let projectID = projectIDs.first else {
                                    return false
                                }
                                model.moveProject(
                                    id: projectID,
                                    relativeTo: projectState.id,
                                    placeAfterTarget: location.y >= 11
                                )
                                return true
                            }
                            .contextMenu {
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
                    }
                }
            }
            .overlay {
                if !sidebarFilterQuery.isEmpty, filteredProjects.isEmpty {
                    SidebarNoResultsView(query: sidebarFilterQuery) {
                        sidebarFilterText = ""
                    }
                }
            }
            .navigationTitle("Worktrees")
            .searchable(
                text: $sidebarFilterText,
                placement: .sidebar,
                prompt: "Filter projects and worktrees"
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        Task {
                            await model.refreshSelectedWorktree()
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.selectedWorktree == nil)
                    .help("Refresh Current Worktree (⌘R)")

                    Button(action: model.chooseProject) {
                        Label("Add Project", systemImage: "plus")
                    }
                    .help("Add Project (⌘O)")
                }
            }
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

    private var worktreeSelection: Binding<GitWorktreeSnapshot.ID?> {
        Binding(
            get: { model.selectedWorktreeID },
            set: { requestedWorktreeID in
                guard let worktreeID = acceptedSidebarWorktreeSelection(
                    current: model.selectedWorktreeID,
                    requested: requestedWorktreeID
                ) else {
                    return
                }
                if model.selectWorktree(id: worktreeID) {
                    Task {
                        await model.refreshSelectedWorktree()
                    }
                }
            }
        )
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
    private func projectContents(_ state: ProjectState) -> some View {
        if state.isLoading, state.snapshot == nil {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading worktrees…")
                    .foregroundStyle(.secondary)
            }
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
                let agentAssociations = model.agentAssociations.associations(
                    for: worktree.worktree
                )
                WorktreeRow(
                    snapshot: worktree,
                    agentAssociations: agentAssociations,
                    openAgentSession: model.agentAssociations.open,
                    navigationAvailability: model.agentAssociations.navigationAvailability
                )
                    .tag(worktree.id)
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
                        if !agentAssociations.isEmpty {
                            Divider()
                            Menu("Agent Sessions") {
                                ForEach(agentAssociations) { association in
                                    Button(agentAssociationTitle(association)) {
                                        model.agentAssociations.open(association)
                                    }
                                }
                            }
                        }
                    }
            }
            if presentation.hiddenWorktreeCount > 0 {
                ProjectWorktreeDisclosureRow(
                    title: projectsShowingAllWorktrees.contains(state.id)
                        ? "Show Fewer Worktrees"
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
            }
        }
    }
}

func acceptedSidebarWorktreeSelection(
    current: GitWorktreeSnapshot.ID?,
    requested: GitWorktreeSnapshot.ID?
) -> GitWorktreeSnapshot.ID? {
    requested ?? current
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
    var defaultWorktrees = Array(
        snapshot.worktrees.filter { worktree in
            worktree.status.changedFileCount > 0
                || !worktree.diffStat.isEmpty
                || worktree.lastActivityAt >= recentCutoff
        }.prefix(4)
    )
    if let selected = snapshot.worktrees.first(where: { $0.id == selectedWorktreeID }),
       !defaultWorktrees.contains(where: { $0.id == selected.id }) {
        if defaultWorktrees.count == 4 {
            defaultWorktrees.removeLast()
        }
        defaultWorktrees.append(selected)
    }
    return ProjectWorktreePresentation(
        visibleWorktrees: showsAll ? snapshot.worktrees : defaultWorktrees,
        hiddenWorktreeCount: snapshot.worktrees.count - defaultWorktrees.count
    )
}

private struct ProjectWorktreeDisclosureRow: View {
    let title: String
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(
                title,
                systemImage: isExpanded ? "chevron.up" : "chevron.down"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }
}

struct ProjectHeader: View {
    let projectState: ProjectState
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 9)
                Text(projectState.project.displayName)
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
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    let agentAssociations: [AgentAssociation]
    let openAgentSession: (AgentAssociation) -> Void
    let navigationAvailability: (
        AgentAssociation
    ) -> AgentSessionNavigationAvailability

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 16)
                .accessibilityLabel(issueAccessibilityLabel)

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

                    ForEach(agentAssociations.prefix(3)) { association in
                        AgentAssociationBadge(
                            association: association,
                            availability: navigationAvailability(association),
                            action: { openAgentSession(association) }
                        )
                    }
                    if agentAssociations.count > 3 {
                        Menu {
                            ForEach(agentAssociations.dropFirst(3)) { association in
                                Button(agentAssociationTitle(association)) {
                                    openAgentSession(association)
                                }
                            }
                        } label: {
                            Text("+\(agentAssociations.count - 3)")
                                .font(.caption2.monospacedDigit().weight(.medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }

                    Spacer(minLength: 4)

                    if !snapshot.diffStat.isEmpty {
                        HStack(spacing: 4) {
                            Text("+\(snapshot.diffStat.addedLineCount)")
                                .foregroundStyle(.green)
                            Text("−\(snapshot.diffStat.deletedLineCount)")
                                .foregroundStyle(.red)
                        }
                        .font(.caption2.monospacedDigit().weight(.medium))
                    }
                }

                HStack(spacing: 5) {
                    if let branch = snapshot.status.branch, !branch.isSynced {
                        let description = branchTrackingDescription(branch) ?? ""
                        HStack(spacing: 3) {
                            if branch.aheadCount > 0 {
                                Text("↑\(branch.aheadCount)")
                            }
                            if branch.behindCount > 0 {
                                Text("↓\(branch.behindCount)")
                            }
                        }
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.blue)
                        .help(description)
                        .accessibilityLabel(description)
                        Text("·")
                    }

                    Text(snapshot.worktree.rootURL.lastPathComponent)
                        .lineLimit(1)
                    if let shortHeadOID = snapshot.worktree.shortHeadOID {
                        Text("·")
                        Text(shortHeadOID)
                            .font(.caption.monospaced())
                    }
                    Text("·")
                    if snapshot.lastActivityAt == .distantPast {
                        Text("Unknown activity")
                    } else {
                        Text(compactRelativeTime(snapshot.lastActivityAt))
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

            }
        }
        .padding(.vertical, 3)
        .help(worktreeRowHelpText(snapshot))
        .accessibilityHint(worktreeRowHelpText(snapshot))
    }

    private var iconName: String {
        if snapshot.errorMessage != nil {
            return snapshot.hasUsableState
                ? "exclamationmark.triangle.fill"
                : "xmark.octagon.fill"
        }
        return snapshot.worktree.isDetached ? "link" : "arrow.triangle.branch"
    }

    private var iconColor: Color {
        if snapshot.errorMessage != nil {
            return snapshot.hasUsableState ? .orange : .red
        }
        return snapshot.status.changedFileCount == 0 ? .secondary : .orange
    }

    private var issueAccessibilityLabel: String {
        guard snapshot.errorMessage != nil else {
            return snapshot.worktree.isDetached ? "Detached HEAD" : "Git branch"
        }
        return snapshot.hasUsableState ? "Refresh warning" : "Repository unavailable"
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

private struct AgentAssociationBadge: View {
    let association: AgentAssociation
    let availability: AgentSessionNavigationAvailability
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tintColor)
                .frame(width: 16, height: 16)
                .background(
                    tintColor.opacity(0.11),
                    in: RoundedRectangle(cornerRadius: 4)
                )
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel("Open \(association.provider.rawValue) session")
    }

    private var iconName: String {
        switch availability {
        case .resolving:
            "ellipsis"
        case .available:
            association.provider == .codex ? "terminal" : "sparkles"
        case .unavailable:
            "exclamationmark.triangle.fill"
        }
    }

    private var tintColor: Color {
        switch availability {
        case .resolving: .secondary
        case .available: .accentColor
        case .unavailable: .orange
        }
    }

    private var helpText: String {
        switch availability {
        case .resolving:
            "\(agentAssociationTitle(association))\nChecking session availability…"
        case .available:
            agentAssociationTitle(association)
        case let .unavailable(reason):
            "\(agentAssociationTitle(association))\n\(reason)"
        }
    }
}

private func agentAssociationTitle(_ association: AgentAssociation) -> String {
    let provider = association.provider.displayName
    return association.title.isEmpty
        ? "\(provider) · \(association.sessionID.prefix(8))"
        : "\(provider) · \(association.title)"
}
