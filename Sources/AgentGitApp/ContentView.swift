import AgentGitCore
import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var projectsShowingAllWorktrees: Set<GitProject.ID> = []
    @State private var sidebarFilterText = ""
    @State private var projectDropTargetID: GitProject.ID?

    init(initialSidebarFilterText: String = "") {
        _sidebarFilterText = State(initialValue: initialSidebarFilterText)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                ForEach(filteredProjects) { projectState in
                    Group {
                        ProjectHeader(
                            projectState: projectState,
                            isCollapsed: model.collapsedProjectIDs.contains(projectState.id),
                            toggle: {
                                model.toggleProjectCollapsed(id: projectState.id)
                            }
                        )
                        .tag(SidebarSelection.project(projectState.id))
                        .selectionDisabled()
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(
                                    projectDropTargetID == projectState.id
                                        ? Color(nsColor: AgentGitPalette.sidebarSelection)
                                        : Color(nsColor: AgentGitPalette.sidebarGroupHeader)
                                )
                        )
                        .listRowInsets(
                            EdgeInsets(top: 6, leading: 6, bottom: 2, trailing: 6)
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
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
                            projectContents(projectState)
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
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: AgentGitPalette.sidebarBackground))
            .tint(Color(nsColor: AgentGitPalette.sidebarSelectionBorder))
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
        .navigationSplitViewStyle(.balanced)
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

    private var sidebarSelection: Binding<SidebarSelection?> {
        Binding(
            get: { model.selectedWorktreeID.map(SidebarSelection.worktree) },
            set: { requestedSelection in
                guard let worktreeID = acceptedSidebarWorktreeSelection(
                    current: model.selectedWorktreeID,
                    requested: requestedSelection
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
            .selectionDisabled()
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
            .selectionDisabled()
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
                WorktreeRow(
                    snapshot: worktree,
                    isSelected: model.selectedWorktreeID == worktree.id
                )
                    .tag(SidebarSelection.worktree(worktree.id))
                    .listRowInsets(
                        EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8)
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
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
                        ? "Show Recent Worktrees"
                        : countedLabel(
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
                .tag(SidebarSelection.worktreeDisclosure(state.id))
                .selectionDisabled()
                .listRowInsets(
                    EdgeInsets(top: 0, leading: 8, bottom: 2, trailing: 8)
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
    }
}

enum SidebarSelection: Hashable {
    case worktree(GitWorktreeSnapshot.ID)
    case project(GitProject.ID)
    case worktreeDisclosure(GitProject.ID)
}

func acceptedSidebarWorktreeSelection(
    current: GitWorktreeSnapshot.ID?,
    requested: SidebarSelection?
) -> GitWorktreeSnapshot.ID? {
    guard case let .worktree(worktreeID) = requested else {
        return current
    }
    return worktreeID
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

    var body: some View {
        Button(action: action) {
            Label(
                title,
                systemImage: isExpanded ? "chevron.up" : "chevron.right"
            )
            .font(.caption2.weight(.medium))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .padding(.leading, 10)
    }
}

struct ProjectHeader: View {
    let projectState: ProjectState
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 9)
                Image(systemName: "folder.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(projectState.project.displayName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
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
                        .font(.caption2.monospacedDigit())
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .frame(height: 28)
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
    var isSelected = false

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(statusIndicatorColor)
                .frame(width: 3, height: 27)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if snapshot.errorMessage != nil {
                        Image(systemName: issueIconName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(issueIconColor)
                    } else if snapshot.worktree.isDetached {
                        Image(systemName: "link")
                            .font(.caption2)
                            .foregroundStyle(secondaryForeground)
                    }
                    Text(snapshot.worktree.displayName)
                        .font(.callout.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(primaryForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 4)

                    if !snapshot.diffStat.isEmpty {
                        HStack(spacing: 4) {
                            Text("+\(snapshot.diffStat.addedLineCount)")
                                .foregroundStyle(additionForeground)
                            Text("−\(snapshot.diffStat.deletedLineCount)")
                                .foregroundStyle(deletionForeground)
                        }
                        .font(.caption2.monospacedDigit().weight(.medium))
                    }
                }

                HStack(spacing: 4) {
                    Text(snapshot.worktree.rootURL.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if snapshot.status.changedFileCount > 0 {
                        metadataSeparator
                        Text(
                            countedLabel(
                                snapshot.status.changedFileCount,
                                singular: "file",
                                plural: "files"
                            )
                        )
                        .monospacedDigit()
                    }
                    if let branch = snapshot.status.branch, !branch.isSynced {
                        let description = branchTrackingDescription(branch) ?? ""
                        metadataSeparator
                        HStack(spacing: 3) {
                            if branch.aheadCount > 0 {
                                Text("↑\(branch.aheadCount)")
                            }
                            if branch.behindCount > 0 {
                                Text("↓\(branch.behindCount)")
                            }
                        }
                        .monospacedDigit()
                        .help(description)
                        .accessibilityLabel(description)
                    }
                    Spacer(minLength: 4)
                    if snapshot.lastActivityAt == .distantPast {
                        Text("Unknown")
                    } else {
                        Text(compactRelativeTime(snapshot.lastActivityAt))
                            .monospacedDigit()
                    }
                }
                .font(.caption2)
                .foregroundStyle(secondaryForeground)

            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .help(worktreeRowHelpText(snapshot))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(worktreeAccessibilityLabel)
        .accessibilityHint(worktreeRowHelpText(snapshot))
    }

    @ViewBuilder
    private var metadataSeparator: some View {
        Text("·")
    }

    private var primaryForeground: Color {
        .primary
    }

    private var secondaryForeground: Color {
        .secondary
    }

    private var additionForeground: Color {
        isSelected
            ? .primary.opacity(0.82)
            : Color(nsColor: AgentGitPalette.sidebarAdditionText)
    }

    private var deletionForeground: Color {
        isSelected
            ? .primary.opacity(0.82)
            : Color(nsColor: AgentGitPalette.sidebarDeletionText)
    }

    private var statusIndicatorColor: Color {
        if snapshot.errorMessage != nil {
            return snapshot.hasUsableState ? .orange : .red
        }
        if snapshot.status.changedFileCount > 0 || !snapshot.diffStat.isEmpty {
            return isSelected
                ? .primary.opacity(0.72)
                : Color(nsColor: AgentGitPalette.sidebarDirtyIndicator)
        }
        return isSelected
            ? .primary.opacity(0.28)
            : Color(nsColor: AgentGitPalette.separator).opacity(0.55)
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
