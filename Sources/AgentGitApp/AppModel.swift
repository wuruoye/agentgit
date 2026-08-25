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

    func refreshAll() async {
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
            scope: scope
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
}

private func compareProjects(_ lhs: GitProject, _ rhs: GitProject) -> Bool {
    lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
}
