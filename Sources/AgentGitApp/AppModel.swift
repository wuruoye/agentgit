import AgentGitCore
import AppKit
import Observation

struct ProjectState: Identifiable {
    let project: GitProject
    var snapshot: GitProjectSnapshot?
    var errorMessage: String?
    var isLoading = false

    var id: GitProject.ID {
        project.id
    }
}

@MainActor
@Observable
final class AppModel {
    private static let projectPathsKey = "agentgit.project-paths"

    private let defaults: UserDefaults
    private let repositoryService: GitRepositoryService
    private var hasLoadedProjects = false
    private var lastRefreshedAt: Date?

    /// Diff 呈现口径是全局偏好：换个提交不该又要重设一遍上下文行数。
    var diffOptions = GitDiffOptions()
    var diffLayout = DiffLayoutMode.unified

    /// 刻意放在观察体系之外：滚动位置每帧都变，进来会把整个工作区拖进重绘。
    let reviewStates = ReviewStateStore()

    private(set) var projects: [ProjectState]
    var selectedWorktreeID: GitWorktreeSnapshot.ID?

    init(
        defaults: UserDefaults = .standard,
        repositoryService: GitRepositoryService = GitRepositoryService()
    ) {
        self.defaults = defaults
        self.repositoryService = repositoryService
        self.projects = (defaults.stringArray(forKey: Self.projectPathsKey) ?? [])
            .map { ProjectState(project: GitProject(rootURL: URL(fileURLWithPath: $0))) }
            .sorted { compareProjects($0.project, $1.project) }
    }

    var selectedWorktree: GitWorktreeSnapshot? {
        projects.lazy
            .compactMap(\.snapshot)
            .flatMap(\.worktrees)
            .first { $0.id == selectedWorktreeID }
    }

    func loadProjectsIfNeeded() async {
        guard !hasLoadedProjects else {
            return
        }
        hasLoadedProjects = true
        await refreshAll()
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        let project = GitProject(rootURL: url)
        if !projects.contains(where: { $0.id == project.id }) {
            projects.append(ProjectState(project: project))
            projects.sort { compareProjects($0.project, $1.project) }
            persistProjects()
        }

        Task {
            await refreshProject(id: project.id)
        }
    }

    /// 窗口重新激活时刷新；短时间内重复激活不再重跑全部 git 命令。
    func refreshAllIfStale(minimumInterval: TimeInterval = 5) async {
        guard hasLoadedProjects else {
            return
        }
        if let lastRefreshedAt, Date().timeIntervalSince(lastRefreshedAt) < minimumInterval {
            return
        }
        await refreshAll()
    }

    func refreshAll() async {
        lastRefreshedAt = Date()
        let targets = projects.map(\.project)
        let service = repositoryService
        for index in projects.indices {
            projects[index].isLoading = true
            projects[index].errorMessage = nil
        }

        await withTaskGroup(
            of: (GitProject.ID, GitProjectSnapshot?, String?).self
        ) { group in
            for project in targets {
                group.addTask {
                    do {
                        let snapshot = try await service.loadProject(
                            at: project.rootURL
                        )
                        return (project.id, snapshot, nil)
                    } catch {
                        return (project.id, nil, String(describing: error))
                    }
                }
            }

            for await (id, snapshot, errorMessage) in group {
                applyLoadResult(id: id, snapshot: snapshot, errorMessage: errorMessage)
            }
        }
    }

    func refreshProject(id: GitProject.ID) async {
        guard let project = projects.first(where: { $0.id == id })?.project else {
            return
        }

        setLoading(true, for: id)
        do {
            let snapshot = try await repositoryService.loadProject(at: project.rootURL)
            applyLoadResult(id: id, snapshot: snapshot, errorMessage: nil)
        } catch {
            applyLoadResult(
                id: id,
                snapshot: nil,
                errorMessage: String(describing: error)
            )
        }
    }

    func loadDiff(
        worktree: GitWorktree,
        change: GitFileChange,
        scope: GitDiffScope
    ) async throws -> GitFileDiff {
        try await repositoryService.loadDiff(
            worktree: worktree,
            change: change,
            scope: scope,
            options: diffOptions
        )
    }

    func loadDiffs(
        worktree: GitWorktree,
        changes: [GitFileChange],
        scope: GitDiffScope
    ) async throws -> [GitFileDiff] {
        try await repositoryService.loadDiffs(
            worktree: worktree,
            changes: changes,
            scope: scope,
            options: diffOptions
        )
    }

    func applyFileAction(
        _ action: GitPendingSelectionAction,
        worktree: GitWorktree,
        change: GitFileChange
    ) async throws {
        switch action {
        case .stage:
            try await repositoryService.stageFile(worktree: worktree, change: change)
        case .unstage:
            try await repositoryService.unstageFile(worktree: worktree, change: change)
        case .discard:
            try await repositoryService.discardFile(worktree: worktree, change: change)
        }
        await refresh(worktree: worktree)
    }

    func applySelectionAction(
        _ action: GitPendingSelectionAction,
        worktree: GitWorktree,
        diff: GitFileDiff,
        selectedLineIDs: Set<GitDiffLine.ID>
    ) async throws {
        try await repositoryService.applySelection(
            action,
            worktree: worktree,
            diff: diff,
            selectedLineIDs: selectedLineIDs
        )
        await refresh(worktree: worktree)
    }

    func loadHistory(worktree: GitWorktree) async throws -> [GitCommit] {
        try await repositoryService.loadHistory(worktree: worktree)
    }

    func loadCommitMessage(worktree: GitWorktree, commit: GitCommit) async throws -> String {
        try await repositoryService.loadCommitMessage(worktree: worktree, commit: commit)
    }

    func loadCommitChanges(
        worktree: GitWorktree,
        commit: GitCommit
    ) async throws -> [GitFileChange] {
        try await repositoryService.loadCommitChanges(worktree: worktree, commit: commit)
    }

    func loadCommitDiff(
        worktree: GitWorktree,
        commit: GitCommit,
        change: GitFileChange
    ) async throws -> GitFileDiff {
        try await repositoryService.loadCommitDiff(
            worktree: worktree,
            commit: commit,
            change: change,
            options: diffOptions
        )
    }

    func loadCommitDiffs(
        worktree: GitWorktree,
        commit: GitCommit,
        changes: [GitFileChange]
    ) async throws -> [GitFileDiff] {
        try await repositoryService.loadCommitDiffs(
            worktree: worktree,
            commit: commit,
            changes: changes,
            options: diffOptions
        )
    }

    func loadRangeChanges(
        worktree: GitWorktree,
        baseOID: String,
        headOID: String
    ) async throws -> [GitFileChange] {
        try await repositoryService.loadRangeChanges(
            worktree: worktree,
            baseOID: baseOID,
            headOID: headOID
        )
    }

    func loadRangeDiffs(
        worktree: GitWorktree,
        baseOID: String,
        headOID: String,
        changes: [GitFileChange]
    ) async throws -> [GitFileDiff] {
        try await repositoryService.loadRangeDiffs(
            worktree: worktree,
            baseOID: baseOID,
            headOID: headOID,
            changes: changes,
            options: diffOptions
        )
    }

    func removeProject(id: GitProject.ID) {
        let removedWorktreeIDs = Set(
            projects.first(where: { $0.id == id })?.snapshot?.worktrees.map(\.id) ?? []
        )
        projects.removeAll { $0.id == id }
        if let selectedWorktreeID, removedWorktreeIDs.contains(selectedWorktreeID) {
            self.selectedWorktreeID = firstAvailableWorktreeID()
        }
        persistProjects()
    }

    private func applyLoadResult(
        id: GitProject.ID,
        snapshot: GitProjectSnapshot?,
        errorMessage: String?
    ) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            return
        }

        projects[index].snapshot = snapshot ?? projects[index].snapshot
        projects[index].errorMessage = errorMessage
        projects[index].isLoading = false

        if selectedWorktreeID == nil {
            selectedWorktreeID = firstAvailableWorktreeID()
        }
    }

    private func setLoading(_ isLoading: Bool, for id: GitProject.ID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            return
        }
        projects[index].isLoading = isLoading
        projects[index].errorMessage = nil
    }

    private func firstAvailableWorktreeID() -> GitWorktreeSnapshot.ID? {
        projects.lazy.compactMap(\.snapshot).flatMap(\.worktrees).first?.id
    }

    private func persistProjects() {
        defaults.set(projects.map { $0.project.rootURL.path }, forKey: Self.projectPathsKey)
    }

    private func refresh(worktree: GitWorktree) async {
        guard let projectID = projects.first(where: { projectState in
            projectState.snapshot?.worktrees.contains(where: { $0.id == worktree.id }) == true
        })?.id else {
            return
        }
        await refreshProject(id: projectID)
    }
}

private func compareProjects(_ lhs: GitProject, _ rhs: GitProject) -> Bool {
    lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
}
