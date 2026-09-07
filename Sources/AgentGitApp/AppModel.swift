import AgentGitCore
import AgentGitIntegrationShared
import AppKit
import CoreServices
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

private struct ActiveWorktreeRefresh {
    let sequence: UInt64
    let task: Task<GitWorktreeSnapshot, Never>
}

private struct ProjectRefreshResult: Sendable {
    let snapshot: GitProjectSnapshot?
    let errorMessage: String?
}

private struct ProjectRefreshRequest {
    let token: RepositoryRefreshToken
    let baselineSnapshot: GitProjectSnapshot?
    let task: Task<ProjectRefreshResult, Never>
}

private struct ActiveProjectRefresh {
    let sequence: UInt64
    let task: Task<ProjectRefreshResult, Never>
}

private struct ProjectResolutionResult: Sendable {
    let index: Int
    let project: GitProject?
    let errorMessage: String?
}

private struct ProjectMembershipCheck: Sendable {
    let projectID: GitProject.ID
    let worktrees: [GitWorktree]?
    let errorMessage: String?
    let wasCancelled: Bool
}

enum WorktreeRefreshOutcome: Equatable, Sendable {
    case updated
    case superseded
    case failed(String)
}

struct GitMutationRefreshError: LocalizedError, CustomStringConvertible, Equatable, Sendable {
    let detail: String

    var errorDescription: String? {
        "Git operation completed, but repository status could not be refreshed: \(detail)"
    }

    var description: String {
        errorDescription ?? detail
    }
}

@MainActor
@Observable
final class AppModel {
    private static let projectPathsKey = "agentgit.project-paths"
    private static let diffContextKey = "agentgit.diff-context"
    private static let ignoresWhitespaceKey = "agentgit.diff-ignore-whitespace"
    private static let diffLayoutKey = "agentgit.diff-layout"
    private static let collapsedProjectIDsKey = "agentgit.collapsed-project-ids"
    private static let pinnedWorktreeIDsKey = "agentgit.pinned-worktree-ids"
    private static let selectedWorktreeIDKey = "agentgit.selected-worktree-id"
    private static let selectedWorktreeProjectIDKey = "agentgit.selected-worktree-project-id"
    private static let projectIdentityVersionKey = "agentgit.project-identity-version"
    private static let currentProjectIdentityVersion = 1
    private static let cleanupSettingsKey = "agentgit.worktree-cleanup-settings"
    private static let cleanupReportKey = "agentgit.worktree-cleanup-report"
    private static let cleanupExcludedProjectsKey = "agentgit.worktree-cleanup-excluded-projects"
    private static let maximumConcurrentProjectRefreshes = 2
    private static let maximumConcurrentWorktreeRefreshes = 2
    private static let maximumConcurrentEventRefreshes = 2

    private let defaults: UserDefaults
    private let repositoryService: GitRepositoryService
    private let snapshotStore: ProjectSnapshotStore?
    private let reviewContentStore: ReviewContentStore?
    private var restoredStartupReviewContent: StartupReviewContent?
    private var hasLoadedProjects = false
    private var hasNormalizedProjects = false
    private var lastRefreshedAt: Date?
    private var repositoryFileMonitor: RepositoryFileMonitor?
    private var pendingEventProjectIDs: Set<GitProject.ID> = []
    private var pendingEventWorktreeIDs: Set<GitWorktree.ID> = []
    private var pendingEventMetadataWorktreeIDs: Set<GitWorktree.ID> = []
    private var pendingEventContentPathsByWorktreeID: [
        GitWorktree.ID: Set<String>
    ] = [:]
    private var eventDebounceTask: Task<Void, Never>?
    private var isProcessingRepositoryEvents = false
    private var selectedWorktreeProjectID: GitProject.ID?
    private var refreshCoordinator = RepositoryRefreshCoordinator()
    private var worktreeRefreshTasks: [GitWorktree.ID: ActiveWorktreeRefresh] = [:]
    private var projectRefreshTasks: [GitProject.ID: ActiveProjectRefresh] = [:]
    private var foregroundRefreshTask: Task<Void, Never>?
    private var foregroundRefreshSequence: UInt64 = 0
    private var snapshotCacheEventID: FSEventStreamEventId
    private var completeProjectSnapshotIDs: Set<GitProject.ID>
    private var pendingRepositoryEventID: FSEventStreamEventId?
    private var snapshotCacheSaveTask: Task<Void, Never>?
    private let cleanupService: GitWorktreeCleanupService
    private var cleanupTimerTask: Task<Void, Never>?
    private var cleanupRunTask: Task<Void, Never>?
    private var isTerminating = false
    private var mutationWorktreeIDs: Set<GitWorktree.ID> = []
    private var cleanupRemovalWorktreeID: GitWorktree.ID?
    private(set) var isCleaningWorktrees = false
    private(set) var cleanupReport: WorktreeCleanupReport?
    private(set) var cleanupExcludedProjectIDs: Set<GitProject.ID> {
        didSet {
            defaults.set(cleanupExcludedProjectIDs.sorted(), forKey: Self.cleanupExcludedProjectsKey)
        }
    }
    var cleanupSettings: WorktreeCleanupSettings {
        didSet {
            if let data = try? JSONEncoder().encode(cleanupSettings) {
                defaults.set(data, forKey: Self.cleanupSettingsKey)
            }
            scheduleWorktreeCleanup()
        }
    }

    /// Diff 设置在 worktree 和提交之间共用。
    var diffOptions: GitDiffOptions {
        didSet { persistDiffPreferences() }
    }
    var diffLayout: DiffLayoutMode {
        didSet { persistDiffPreferences() }
    }
    var collapsedProjectIDs: Set<GitProject.ID> {
        didSet {
            defaults.set(
                collapsedProjectIDs.sorted(),
                forKey: Self.collapsedProjectIDsKey
            )
        }
    }
    /// 置顶的 worktree。ID 就是 worktree 路径，跨项目天然唯一，所以一个集合就够，
    /// 排序时只在各自项目内生效。
    var pinnedWorktreeIDs: Set<GitWorktreeSnapshot.ID> {
        didSet {
            defaults.set(
                pinnedWorktreeIDs.sorted(),
                forKey: Self.pinnedWorktreeIDsKey
            )
        }
    }
    /// 刻意放在观察体系之外：滚动位置每帧都变，进来会把整个工作区拖进重绘。
    let reviewStates: ReviewStateStore
    let agentAssociations: AgentAssociationController
    let agentPluginConfigurator = AgentPluginConfigurator()

    private(set) var projects: [ProjectState]
    private(set) var repositoryMonitorError: String?
    private(set) var projectAdditionError: String?
    private(set) var snapshotCacheError: String?
    private(set) var reviewContentCacheError: String?
    private(set) var blockingGitRefreshErrors: [
        GitWorktree.ID: String
    ] = [:]
    private(set) var isApplicationActive = true
    var isWorktreeSwitcherPresented = false
    var selectedWorktreeID: GitWorktreeSnapshot.ID? {
        didSet {
            persistSelectedWorktreeSelection()
        }
    }

    convenience init() {
        self.init(
            defaults: .standard,
            repositoryService: GitRepositoryService(),
            snapshotStore: ProjectSnapshotStore(
                fileURL: ProjectSnapshotStore.defaultFileURL
            ),
            reviewContentStore: ReviewContentStore(
                directoryURL: ReviewContentStore.defaultDirectoryURL
            )
        )
    }

    init(
        defaults: UserDefaults,
        repositoryService: GitRepositoryService = GitRepositoryService(),
        snapshotStore: ProjectSnapshotStore? = nil,
        reviewContentStore: ReviewContentStore? = nil,
        agentAssociations: AgentAssociationController? = nil,
        cleanupService: GitWorktreeCleanupService = GitWorktreeCleanupService()
    ) {
        self.defaults = defaults
        self.repositoryService = repositoryService
        self.cleanupService = cleanupService
        self.cleanupExcludedProjectIDs = Set(
            defaults.stringArray(forKey: Self.cleanupExcludedProjectsKey) ?? []
        )
        self.cleanupSettings = defaults.data(forKey: Self.cleanupSettingsKey)
            .flatMap { try? JSONDecoder().decode(WorktreeCleanupSettings.self, from: $0) }
            ?? WorktreeCleanupSettings()
        self.cleanupReport = defaults.data(forKey: Self.cleanupReportKey)
            .flatMap { try? JSONDecoder().decode(WorktreeCleanupReport.self, from: $0) }
        self.snapshotStore = snapshotStore
        self.reviewContentStore = reviewContentStore
        self.agentAssociations = agentAssociations ?? AgentAssociationController()
        let cachedPayload = snapshotStore?.initialPayload
        self.snapshotCacheEventID = cachedPayload?.eventID
            ?? FSEventsGetCurrentEventId()
        self.completeProjectSnapshotIDs = cachedPayload?.completeProjectIDs ?? []
        self.snapshotCacheError = snapshotStore?.initialErrorMessage
        self.reviewStates = ReviewStateStore(defaults: defaults)
        self.diffOptions = GitDiffOptions(
            context: Self.diffContext(from: defaults),
            ignoresWhitespace: defaults.bool(forKey: Self.ignoresWhitespaceKey)
        )
        self.diffLayout = DiffLayoutMode(
            rawValue: defaults.string(forKey: Self.diffLayoutKey) ?? ""
        ) ?? .unified
        self.collapsedProjectIDs = Set(
            defaults.stringArray(forKey: Self.collapsedProjectIDsKey) ?? []
        )
        self.pinnedWorktreeIDs = Set(
            defaults.stringArray(forKey: Self.pinnedWorktreeIDsKey) ?? []
        )
        let cachedByProjectID = Dictionary(
            (cachedPayload?.projects ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let storedProjectPaths = defaults.stringArray(
            forKey: Self.projectPathsKey
        ) ?? []
        var seenProjectIDs: Set<GitProject.ID> = []
        self.projects = storedProjectPaths.compactMap { path in
            let project = GitProject(rootURL: URL(fileURLWithPath: path))
            guard seenProjectIDs.insert(project.id).inserted else {
                return nil
            }
            return ProjectState(
                project: project,
                snapshot: cachedByProjectID[project.id]
            )
        }
        let storedSelectedWorktreeID = defaults.string(
            forKey: Self.selectedWorktreeIDKey
        )
        let storedSelectedProjectID = defaults.string(
            forKey: Self.selectedWorktreeProjectIDKey
        )
        let cachedWorktreeSelection = projects.lazy.compactMap { state in
            state.snapshot?.worktrees.first(where: {
                $0.id == storedSelectedWorktreeID
            }).map { (projectID: state.id, worktree: $0) }
        }.first
        let fallbackCachedWorktreeSelection = projects.lazy.compactMap { state in
            state.snapshot?.worktrees.first.map {
                (projectID: state.id, worktree: $0)
            }
        }.first
        let awaitsIncompleteSelectedProject = storedSelectedWorktreeID != nil
            && storedSelectedProjectID.map { projectID in
                projects.contains(where: { $0.id == projectID })
                    && !completeProjectSnapshotIDs.contains(projectID)
            } == true
        let initialCachedSelection = cachedWorktreeSelection
            ?? (awaitsIncompleteSelectedProject ? nil : fallbackCachedWorktreeSelection)
        self.selectedWorktreeProjectID = initialCachedSelection?.projectID
            ?? storedSelectedProjectID
        self.selectedWorktreeID = initialCachedSelection?.worktree.id
            ?? storedSelectedWorktreeID
        if cachedWorktreeSelection == nil,
           !awaitsIncompleteSelectedProject,
           let initialCachedSelection {
            defaults.set(
                initialCachedSelection.worktree.id,
                forKey: Self.selectedWorktreeIDKey
            )
            defaults.set(
                initialCachedSelection.projectID,
                forKey: Self.selectedWorktreeProjectIDKey
            )
        }
        if let selectedWorktreeID,
           let selectedSnapshot = projects.lazy
            .compactMap(\.snapshot)
            .flatMap(\.worktrees)
            .first(where: { $0.id == selectedWorktreeID }) {
            let restoredContext = reviewStates.lastContext(
                for: selectedSnapshot.id
            ).context
            self.restoredStartupReviewContent = reviewContentStore?.startupContent(
                snapshot: selectedSnapshot,
                options: diffOptions,
                historicalContext: restoredContext
            )
        } else {
            self.restoredStartupReviewContent = nil
        }
        self.hasNormalizedProjects = defaults.integer(
            forKey: Self.projectIdentityVersionKey
        ) >= Self.currentProjectIdentityVersion
        if projects.count != storedProjectPaths.count {
            defaults.set(
                projects.map { $0.project.rootURL.path },
                forKey: Self.projectPathsKey
            )
        }
    }

    private static func diffContext(from defaults: UserDefaults) -> GitDiffContext {
        switch defaults.string(forKey: diffContextKey) {
        case "lines:8": .lines(8)
        case "lines:25": .lines(25)
        case "whole-file": .wholeFile
        default: .lines(3)
        }
    }

    private func persistDiffPreferences() {
        let context = switch diffOptions.context {
        case .lines(8): "lines:8"
        case .lines(25): "lines:25"
        case .wholeFile: "whole-file"
        default: "lines:3"
        }
        defaults.set(context, forKey: Self.diffContextKey)
        defaults.set(diffOptions.ignoresWhitespace, forKey: Self.ignoresWhitespaceKey)
        defaults.set(diffLayout.rawValue, forKey: Self.diffLayoutKey)
    }

    var selectedWorktree: GitWorktreeSnapshot? {
        projects.lazy
            .compactMap(\.snapshot)
            .flatMap(\.worktrees)
            .first { $0.id == selectedWorktreeID }
    }

    var hasAvailableWorktrees: Bool {
        projects.contains { $0.snapshot?.worktrees.isEmpty == false }
    }

    /// 已缓存且可用的快照由 FSEvents 继续维护，切换列表项时可以立即复用。
    /// 缺少完整快照时返回 true，让调用方安排一次真实状态读取。
    @discardableResult
    func selectWorktree(id: GitWorktreeSnapshot.ID) -> Bool {
        guard cleanupRemovalWorktreeID != id else { return false }
        guard selectedWorktreeID != id else {
            return false
        }
        guard let nextWorktree = projects.lazy
            .compactMap(\.snapshot)
            .flatMap(\.worktrees)
            .first(where: { $0.id == id }) else {
            return false
        }
        selectedWorktreeID = id
        return nextWorktree.refreshedAt == nil
            || !nextWorktree.hasUsableState
    }

    func startupReviewContent(
        for snapshot: GitWorktreeSnapshot
    ) -> StartupReviewContent? {
        guard let restoredStartupReviewContent,
              restoredStartupReviewContent.matches(
                  snapshot: snapshot,
                  options: diffOptions
              ) else {
            return nil
        }
        return restoredStartupReviewContent
    }

    func loadProjectsIfNeeded() async {
        guard !hasLoadedProjects else {
            return
        }
        hasLoadedProjects = true
        agentAssociations.start()
        if isApplicationActive {
            await normalizeStoredProjects()
            updateRepositoryMonitor()
            await validateSelectedSnapshotIfNeeded()
            _ = await reconcileProjectWorktreeMembership(
                projectIDs: projectIDsNeedingMembershipValidation
            )
            await refreshProjectsMissingSnapshots()
            lastRefreshedAt = Date()
            updateRepositoryMonitor()
        }
        scheduleWorktreeCleanup()
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

        Task {
            await addProject(at: url)
        }
    }

    func addProject(at url: URL) async {
        do {
            let project = try await repositoryService.resolveProject(at: url)
            projectAdditionError = nil
            if !projects.contains(where: { $0.id == project.id }) {
                projects.append(ProjectState(project: project))
                persistProjects()
            }
            await refreshProject(id: project.id)
            let selectedPath = url.standardizedFileURL.path
            if let selected = projects.first(where: { $0.id == project.id })?
                .snapshot?.worktrees.first(where: { $0.id == selectedPath }) {
                selectedWorktreeID = selected.id
            }
        } catch {
            projectAdditionError = String(describing: error)
        }
    }

    func clearProjectAdditionError() {
        projectAdditionError = nil
    }

    var cacheErrorMessage: String? {
        let messages = [
            snapshotCacheError.map { "Project snapshots: \($0)" },
            reviewContentCacheError.map { "Review content: \($0)" }
        ].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    func clearCacheErrors() {
        snapshotCacheError = nil
        reviewContentCacheError = nil
    }

    func blockingGitRefreshError(
        for worktreeID: GitWorktree.ID
    ) -> String? {
        blockingGitRefreshErrors[worktreeID]
    }

    func setBlockingGitRefreshError(
        _ message: String?,
        for worktreeID: GitWorktree.ID
    ) {
        blockingGitRefreshErrors[worktreeID] = message
    }

    func clearProjectError(id: GitProject.ID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            return
        }
        projects[index].errorMessage = nil
    }

    /// 窗口重新激活时刷新；短时间内重复激活不再重跑全部 git 命令。
    func refreshAllIfStale(minimumInterval: TimeInterval = 5) async {
        guard hasLoadedProjects, isApplicationActive else {
            return
        }
        await normalizeStoredProjects()
        updateRepositoryMonitor()
        await validateSelectedSnapshotIfNeeded()
        if let lastRefreshedAt, Date().timeIntervalSince(lastRefreshedAt) < minimumInterval {
            return
        }
        _ = await reconcileProjectWorktreeMembership(
            projectIDs: projectIDsNeedingMembershipValidation
        )
        guard isApplicationActive, !Task.isCancelled else {
            return
        }
        await refreshProjectsMissingSnapshots()
        lastRefreshedAt = Date()
        updateRepositoryMonitor()
    }

    @discardableResult
    func reconcileProjectWorktreeMembership(
        projectIDs requestedProjectIDs: Set<GitProject.ID>? = nil
    ) async -> Set<GitProject.ID> {
        guard isApplicationActive, !Task.isCancelled else {
            return []
        }
        let service = repositoryService
        let indexedProjectValues = projects.enumerated().compactMap {
            index, state -> (index: Int, project: GitProject)? in
            guard state.snapshot != nil else {
                return nil
            }
            if let requestedProjectIDs,
               !requestedProjectIDs.contains(state.id) {
                return nil
            }
            return (index, state.project)
        }
        let projectValues = indexedProjectValues.sorted { lhs, rhs in
            let lhsSelected = lhs.project.id == selectedWorktreeProjectID
            let rhsSelected = rhs.project.id == selectedWorktreeProjectID
            if lhsSelected != rhsSelected {
                return lhsSelected
            }
            return lhs.index < rhs.index
        }.map(\.project)
        let checks = await withTaskGroup(of: ProjectMembershipCheck.self) { group in
            let concurrency = min(
                Self.maximumConcurrentProjectRefreshes,
                projectValues.count
            )
            for project in projectValues.prefix(concurrency) {
                group.addTask {
                    await Self.checkProjectMembership(project, using: service)
                }
            }

            var values: [ProjectMembershipCheck] = []
            var nextIndex = concurrency
            while let check = await group.next() {
                values.append(check)
                if nextIndex < projectValues.count {
                    let project = projectValues[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        await Self.checkProjectMembership(project, using: service)
                    }
                }
            }
            return values
        }
        guard isApplicationActive, !Task.isCancelled else {
            return []
        }

        var changedWorktreesByProjectID: [GitProject.ID: [GitWorktree]] = [:]
        var verifiedProjectIDs: Set<GitProject.ID> = []
        for check in checks where !check.wasCancelled {
            guard let index = projects.firstIndex(where: { $0.id == check.projectID }) else {
                continue
            }
            if let errorMessage = check.errorMessage {
                projects[index].errorMessage = errorMessage
                continue
            }
            projects[index].errorMessage = nil
            guard let discoveredWorktrees = check.worktrees,
                  let current = projects[index].snapshot else {
                continue
            }
            verifiedProjectIDs.insert(check.projectID)
            let discoveredIDs = Set(discoveredWorktrees.map(\.id))
            let currentIDs = Set(current.worktrees.map(\.id))
            if currentIDs != discoveredIDs {
                changedWorktreesByProjectID[check.projectID] = discoveredWorktrees
            }
        }

        let changedProjectIDs = Set(changedWorktreesByProjectID.keys)
        let unchangedVerifiedProjectIDs = verifiedProjectIDs.subtracting(
            changedProjectIDs
        )
        if !unchangedVerifiedProjectIDs.isEmpty {
            completeProjectSnapshotIDs.formUnion(unchangedVerifiedProjectIDs)
            scheduleSnapshotCacheSave()
        }
        for project in projects where changedProjectIDs.contains(project.id) {
            guard isApplicationActive, !Task.isCancelled else {
                return changedProjectIDs
            }
            guard let current = projects.first(where: { $0.id == project.id })?.snapshot,
                  let discoveredWorktrees = changedWorktreesByProjectID[project.id] else {
                continue
            }
            let request = startProjectMembershipRefresh(
                project.project,
                current: current,
                discoveredWorktrees: discoveredWorktrees
            )
            await completeProjectRefresh(request)
        }
        fallbackToAvailableWorktreeIfSelectionIsResolved()
        return changedProjectIDs
    }

    private var projectIDsNeedingMembershipValidation: Set<GitProject.ID> {
        Set(
            projects.compactMap { state in
                guard state.snapshot != nil,
                      !completeProjectSnapshotIDs.contains(state.id) else {
                    return nil
                }
                return state.id
            }
        )
    }

    private func validateSelectedSnapshotIfNeeded() async {
        guard selectedWorktree?.refreshedAt == nil else {
            return
        }
        await refreshSelectedWorktree()
    }

    private nonisolated static func checkProjectMembership(
        _ project: GitProject,
        using service: GitRepositoryService
    ) async -> ProjectMembershipCheck {
        do {
            let worktrees = try await service.listWorktrees(at: project.rootURL)
            try Task.checkCancellation()
            return ProjectMembershipCheck(
                projectID: project.id,
                worktrees: worktrees,
                errorMessage: nil,
                wasCancelled: false
            )
        } catch is CancellationError {
            return ProjectMembershipCheck(
                projectID: project.id,
                worktrees: nil,
                errorMessage: nil,
                wasCancelled: true
            )
        } catch {
            return ProjectMembershipCheck(
                projectID: project.id,
                worktrees: nil,
                errorMessage: String(describing: error),
                wasCancelled: false
            )
        }
    }

    private func normalizeStoredProjects() async {
        guard !hasNormalizedProjects else {
            return
        }
        hasNormalizedProjects = true
        let originalStates = projects
        let originalCompleteProjectIDs = completeProjectSnapshotIDs
        guard !originalStates.isEmpty else {
            defaults.set(
                Self.currentProjectIdentityVersion,
                forKey: Self.projectIdentityVersionKey
            )
            return
        }
        let service = repositoryService
        let results = await withTaskGroup(of: ProjectResolutionResult.self) { group in
            for (index, state) in originalStates.enumerated() {
                group.addTask {
                    do {
                        return ProjectResolutionResult(
                            index: index,
                            project: try await service.resolveProject(
                                at: state.project.rootURL
                            ),
                            errorMessage: nil
                        )
                    } catch {
                        return ProjectResolutionResult(
                            index: index,
                            project: nil,
                            errorMessage: String(describing: error)
                        )
                    }
                }
            }
            var values: [ProjectResolutionResult] = []
            for await result in group {
                values.append(result)
            }
            return values.sorted { $0.index < $1.index }
        }

        var normalizedStates: [ProjectState] = []
        var normalizedCompleteProjectIDs: Set<GitProject.ID> = []
        var seenProjectIDs: Set<GitProject.ID> = []
        var normalizedCollapsedIDs = collapsedProjectIDs
        var normalizedCleanupExcludedIDs = cleanupExcludedProjectIDs
        for result in results {
            let original = originalStates[result.index]
            guard let resolved = result.project else {
                if originalCompleteProjectIDs.contains(original.id) {
                    normalizedCompleteProjectIDs.insert(original.id)
                }
                normalizedStates.append(
                    ProjectState(
                        project: original.project,
                        snapshot: original.snapshot,
                        errorMessage: result.errorMessage,
                        isLoading: false
                    )
                )
                continue
            }
            if collapsedProjectIDs.contains(original.id) {
                normalizedCollapsedIDs.remove(original.id)
                normalizedCollapsedIDs.insert(resolved.id)
            }
            if cleanupExcludedProjectIDs.contains(original.id) {
                normalizedCleanupExcludedIDs.remove(original.id)
                normalizedCleanupExcludedIDs.insert(resolved.id)
            }
            if selectedWorktreeProjectID == original.id {
                selectedWorktreeProjectID = resolved.id
            }
            if originalCompleteProjectIDs.contains(original.id) {
                normalizedCompleteProjectIDs.insert(resolved.id)
            }
            guard seenProjectIDs.insert(resolved.id).inserted else {
                continue
            }
            normalizedStates.append(
                ProjectState(
                    project: resolved,
                    snapshot: original.id == resolved.id ? original.snapshot : nil,
                    errorMessage: nil,
                    isLoading: false
                )
            )
        }
        projects = normalizedStates
        completeProjectSnapshotIDs = normalizedCompleteProjectIDs.intersection(
            Set(normalizedStates.map(\.id))
        )
        collapsedProjectIDs = normalizedCollapsedIDs
        cleanupExcludedProjectIDs = normalizedCleanupExcludedIDs
        persistProjects()
        defaults.set(
            Self.currentProjectIdentityVersion,
            forKey: Self.projectIdentityVersionKey
        )
        persistSelectedWorktreeSelection()
    }

    func refreshAll() async {
        lastRefreshedAt = Date()
        let orderedProjects = projects.sorted { lhs, rhs in
            let lhsSelected = lhs.snapshot?.worktrees.contains {
                $0.id == selectedWorktreeID
            } == true
            let rhsSelected = rhs.snapshot?.worktrees.contains {
                $0.id == selectedWorktreeID
            } == true
            if lhsSelected != rhsSelected {
                return lhsSelected
            }
            let lhsIndex = projects.firstIndex(where: { $0.id == lhs.id }) ?? .max
            let rhsIndex = projects.firstIndex(where: { $0.id == rhs.id }) ?? .max
            return lhsIndex < rhsIndex
        }
        var startIndex = 0
        while startIndex < orderedProjects.count, !Task.isCancelled {
            let endIndex = min(
                startIndex + Self.maximumConcurrentProjectRefreshes,
                orderedProjects.count
            )
            let requests = orderedProjects[startIndex..<endIndex].map {
                startProjectRefresh($0.project)
            }
            await withTaskCancellationHandler {
                for request in requests {
                    await completeProjectRefresh(request)
                }
            } onCancel: {
                for request in requests {
                    request.task.cancel()
                }
            }
            startIndex = endIndex
        }
        fallbackToAvailableWorktreeIfSelectionIsResolved()
        persistSelectedWorktreeSelection()
        updateRepositoryMonitor()
    }

    private func refreshProjectsMissingSnapshots() async {
        let coverageEventID = FSEventsGetCurrentEventId()
        let missingProjects = projects
            .filter { $0.snapshot == nil }
            .sorted { lhs, rhs in
                let lhsSelected = lhs.id == selectedWorktreeProjectID
                let rhsSelected = rhs.id == selectedWorktreeProjectID
                if lhsSelected != rhsSelected {
                    return lhsSelected
                }
                let lhsIndex = projects.firstIndex(where: { $0.id == lhs.id }) ?? .max
                let rhsIndex = projects.firstIndex(where: { $0.id == rhs.id }) ?? .max
                return lhsIndex < rhsIndex
            }
        var startIndex = 0
        while startIndex < missingProjects.count,
              isApplicationActive,
              !Task.isCancelled {
            let endIndex = min(
                startIndex + Self.maximumConcurrentProjectRefreshes,
                missingProjects.count
            )
            let requests = missingProjects[startIndex..<endIndex].map {
                startProjectRefresh($0.project)
            }
            await withTaskCancellationHandler {
                for request in requests {
                    await completeProjectRefresh(request)
                }
            } onCancel: {
                for request in requests {
                    request.task.cancel()
                }
            }
            startIndex = endIndex
        }
        fallbackToAvailableWorktreeIfSelectionIsResolved()
        persistSelectedWorktreeSelection()
        let missingProjectIDs = Set(missingProjects.map(\.id))
        if !missingProjectIDs.isEmpty,
           missingProjectIDs.isSubset(of: completeProjectSnapshotIDs) {
            snapshotCacheSaveTask?.cancel()
            snapshotCacheSaveTask = nil
            _ = await saveSnapshotCache(eventID: coverageEventID)
        }
    }

    @discardableResult
    func refreshSelectedWorktree() async -> WorktreeRefreshOutcome {
        guard let selectedWorktree else {
            return .failed("The selected worktree is unavailable.")
        }
        lastRefreshedAt = Date()
        return await refresh(
            worktree: selectedWorktree.worktree,
            submoduleScanMode: .allChanges
        )
    }

    func isRefreshing(worktreeID: GitWorktree.ID) -> Bool {
        guard isApplicationActive else {
            return false
        }
        guard let project = projects.first(where: { state in
            state.snapshot?.worktrees.contains(where: { $0.id == worktreeID }) == true
        }) else {
            return false
        }
        return pendingEventProjectIDs.contains(project.id)
            || pendingEventWorktreeIDs.contains(worktreeID)
            || projectRefreshTasks[project.id] != nil
            || worktreeRefreshTasks[worktreeID] != nil
    }

    @discardableResult
    func refreshWorktree(id: GitWorktree.ID) async -> WorktreeRefreshOutcome {
        guard let worktree = projects.lazy
            .compactMap(\.snapshot)
            .flatMap(\.worktrees)
            .first(where: { $0.id == id })?.worktree else {
            return .failed("The worktree is unavailable.")
        }
        lastRefreshedAt = Date()
        return await refresh(
            worktree: worktree,
            submoduleScanMode: id == selectedWorktreeID ? .allChanges : .commitsOnly
        )
    }

    func refreshProject(id: GitProject.ID) async {
        guard let project = projects.first(where: { $0.id == id })?.project else {
            return
        }

        let request = startProjectRefresh(project)
        await completeProjectRefresh(request)
        fallbackToAvailableWorktreeIfSelectionIsResolved()
        updateRepositoryMonitor()
    }

    func loadDiff(
        worktree: GitWorktree,
        change: GitFileChange,
        scope: GitDiffScope,
        options: GitDiffOptions? = nil
    ) async throws -> GitFileDiff {
        try await repositoryService.loadDiff(
            worktree: worktree,
            change: change,
            scope: scope,
            options: options ?? diffOptions
        )
    }

    func loadDiffs(
        worktree: GitWorktree,
        changes: [GitFileChange],
        scope: GitDiffScope,
        options: GitDiffOptions? = nil
    ) async throws -> [GitFileDiff] {
        try await repositoryService.loadDiffs(
            worktree: worktree,
            changes: changes,
            scope: scope,
            options: options ?? diffOptions
        )
    }

    func loadDiffBatches(
        worktree: GitWorktree,
        changes: [GitFileChange],
        scope: GitDiffScope,
        options: GitDiffOptions? = nil
    ) -> AsyncThrowingStream<[GitFileDiff], any Error> {
        repositoryService.loadDiffBatches(
            worktree: worktree,
            changes: changes,
            scope: scope,
            options: options ?? diffOptions
        )
    }

    func loadPendingDiffBatches(
        worktree: GitWorktree,
        workingChanges: [GitFileChange],
        stagedChanges: [GitFileChange],
        options: GitDiffOptions? = nil
    ) -> AsyncThrowingStream<GitPendingDiffBatch, any Error> {
        repositoryService.loadPendingDiffBatches(
            worktree: worktree,
            workingChanges: workingChanges,
            stagedChanges: stagedChanges,
            options: options ?? diffOptions
        )
    }

    func loadImageDiff(
        worktree: GitWorktree,
        change: GitFileChange,
        scope: GitDiffScope
    ) async throws -> GitImageDiff {
        try await repositoryService.loadImageDiff(
            worktree: worktree,
            change: change,
            scope: scope
        )
    }

    func applyFileAction(
        _ action: GitPendingSelectionAction,
        worktree: GitWorktree,
        change: GitFileChange
    ) async throws {
        try beginWorktreeMutation(worktree.id)
        defer { mutationWorktreeIDs.remove(worktree.id) }
        switch action {
        case .stage:
            try await repositoryService.stageFile(worktree: worktree, change: change)
        case .unstage:
            try await repositoryService.unstageFile(worktree: worktree, change: change)
        case .discard:
            try await repositoryService.discardFile(worktree: worktree, change: change)
        }
        try requireSuccessfulMutationRefresh(
            await refresh(worktree: worktree, submoduleScanMode: .allChanges)
        )
    }

    func applySelectionAction(
        _ action: GitPendingSelectionAction,
        worktree: GitWorktree,
        diff: GitFileDiff,
        selectedLineIDs: Set<GitDiffLine.ID>
    ) async throws {
        try beginWorktreeMutation(worktree.id)
        defer { mutationWorktreeIDs.remove(worktree.id) }
        try await repositoryService.applySelection(
            action,
            worktree: worktree,
            diff: diff,
            selectedLineIDs: selectedLineIDs
        )
        try requireSuccessfulMutationRefresh(
            await refresh(worktree: worktree, submoduleScanMode: .allChanges)
        )
    }

    func performRemoteAction(
        _ action: GitRemoteAction,
        worktree: GitWorktree
    ) async throws {
        try beginWorktreeMutation(worktree.id)
        defer { mutationWorktreeIDs.remove(worktree.id) }
        try await repositoryService.performRemoteAction(action, worktree: worktree)
        try requireSuccessfulMutationRefresh(
            await refresh(worktree: worktree, submoduleScanMode: .allChanges)
        )
    }

    private func requireSuccessfulMutationRefresh(
        _ outcome: WorktreeRefreshOutcome
    ) throws {
        if case let .failed(detail) = outcome {
            throw GitMutationRefreshError(detail: detail)
        }
    }

    private func beginWorktreeMutation(_ id: GitWorktree.ID) throws {
        guard cleanupRemovalWorktreeID != id else {
            throw NSError(
                domain: "AgentGit.WorktreeCleanup", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "This worktree is being removed."]
            )
        }
        mutationWorktreeIDs.insert(id)
    }

    func loadHistory(worktree: GitWorktree) async throws -> [GitCommit] {
        try await repositoryService.loadHistory(worktree: worktree)
    }

    func loadHistoryPage(
        worktree: GitWorktree,
        revision: String?,
        offset: Int,
        pageSize: Int
    ) async throws -> GitHistoryPage {
        try await repositoryService.loadHistoryPage(
            worktree: worktree,
            revision: revision,
            offset: offset,
            pageSize: pageSize
        )
    }

    func loadLineHistory(
        worktree: GitWorktree,
        revision: String?,
        path: String,
        startLine: Int,
        endLine: Int,
        limit: Int = 500
    ) async throws -> [GitCommit] {
        try await repositoryService.loadLineHistory(
            worktree: worktree,
            revision: revision,
            path: path,
            startLine: startLine,
            endLine: endLine,
            limit: limit
        )
    }

    func historyContainsCommits(
        worktree: GitWorktree,
        revision: String?,
        commitIDs: Set<GitCommit.ID>
    ) async throws -> Bool {
        try await repositoryService.historyContainsCommits(
            worktree: worktree,
            revision: revision,
            commitIDs: commitIDs
        )
    }

    func cachedHistoryPage(
        worktreeID: GitWorktree.ID,
        revision: String?,
        pageSize: Int
    ) async -> GitHistoryPage? {
        guard let reviewContentStore else {
            return nil
        }
        return await reviewContentStore.historyPage(
            for: HistoryReviewContentCacheKey(
                worktreeID: worktreeID,
                revision: revision,
                pageSize: pageSize
            )
        )
    }

    func cacheHistoryPage(
        _ page: GitHistoryPage,
        worktreeID: GitWorktree.ID,
        revision: String?,
        pageSize: Int
    ) async {
        guard let reviewContentStore else {
            return
        }
        await cacheReviewContent {
            try await reviewContentStore.saveHistoryPage(
                page,
                for: HistoryReviewContentCacheKey(
                    worktreeID: worktreeID,
                    revision: revision,
                    pageSize: pageSize
                )
            )
        }
    }

    func cachedPendingDiffEntry(
        snapshot: GitWorktreeSnapshot,
        options: GitDiffOptions
    ) async -> ReviewDiffCacheEntry? {
        guard let reviewContentStore else {
            return nil
        }
        return await reviewContentStore.pendingDiffEntry(
            for: PendingReviewContentCacheKey(
                snapshot: snapshot,
                options: options
            )
        )
    }

    func cachePendingDiffs(
        _ diffs: [GitFileDiff],
        snapshot: GitWorktreeSnapshot,
        options: GitDiffOptions,
        isComplete: Bool = true
    ) async {
        guard let reviewContentStore else {
            return
        }
        await cacheReviewContent {
            let key = PendingReviewContentCacheKey(
                snapshot: snapshot,
                options: options
            )
            if isComplete {
                try await reviewContentStore.savePendingDiffs(
                    diffs,
                    for: key
                )
            } else {
                try await reviewContentStore.savePartialPendingDiffs(
                    diffs,
                    for: key
                )
            }
        }
    }

    func cachedPendingDiff(
        snapshot: GitWorktreeSnapshot,
        changeID: GitFileChange.ID,
        scope: GitDiffScope,
        options: GitDiffOptions
    ) async -> GitFileDiff? {
        guard let reviewContentStore else {
            return nil
        }
        return await reviewContentStore.pendingDiff(
            changeID: changeID,
            scope: scope,
            for: PendingReviewContentCacheKey(
                snapshot: snapshot,
                options: options
            )
        )
    }

    func cachePendingDiff(
        _ diff: GitFileDiff,
        snapshot: GitWorktreeSnapshot,
        options: GitDiffOptions
    ) async {
        guard let reviewContentStore else {
            return
        }
        await cacheReviewContent {
            try await reviewContentStore.savePendingDiff(
                diff,
                for: PendingReviewContentCacheKey(
                    snapshot: snapshot,
                    options: options
                )
            )
        }
    }

    func cachedHistoricalDetails(
        worktreeID: GitWorktree.ID,
        context: ReviewContext
    ) async -> HistoricalReviewDetails? {
        guard let reviewContentStore,
              let key = HistoricalReviewDetailsCacheKey(
                  worktreeID: worktreeID,
                  context: context
              ) else {
            return nil
        }
        return await reviewContentStore.historicalDetails(for: key)
    }

    func cacheHistoricalDetails(
        _ details: HistoricalReviewDetails,
        worktreeID: GitWorktree.ID,
        context: ReviewContext
    ) async {
        guard let reviewContentStore,
              let key = HistoricalReviewDetailsCacheKey(
                  worktreeID: worktreeID,
                  context: context
              ) else {
            return
        }
        await cacheReviewContent {
            try await reviewContentStore.saveHistoricalDetails(details, for: key)
        }
    }

    func cachedHistoricalDiffEntry(
        worktreeID: GitWorktree.ID,
        context: ReviewContext,
        options: GitDiffOptions
    ) async -> ReviewDiffCacheEntry? {
        guard let reviewContentStore,
              let key = HistoricalReviewDiffCacheKey(
                  worktreeID: worktreeID,
                  context: context,
                  options: options
              ) else {
            return nil
        }
        return await reviewContentStore.historicalDiffEntry(for: key)
    }

    func cachedHistoricalDiff(
        worktreeID: GitWorktree.ID,
        context: ReviewContext,
        changeID: GitFileChange.ID,
        options: GitDiffOptions
    ) async -> GitFileDiff? {
        guard let reviewContentStore,
              let key = HistoricalReviewDiffCacheKey(
                  worktreeID: worktreeID,
                  context: context,
                  options: options
              ) else {
            return nil
        }
        return await reviewContentStore.historicalDiff(
            changeID: changeID,
            for: key
        )
    }

    func cacheHistoricalDiffs(
        _ diffs: [GitFileDiff],
        worktreeID: GitWorktree.ID,
        context: ReviewContext,
        options: GitDiffOptions,
        isComplete: Bool = true
    ) async {
        guard let reviewContentStore,
              let key = HistoricalReviewDiffCacheKey(
                  worktreeID: worktreeID,
                  context: context,
                  options: options
              ) else {
            return
        }
        await cacheReviewContent {
            if isComplete {
                try await reviewContentStore.saveHistoricalDiffs(diffs, for: key)
            } else {
                try await reviewContentStore.savePartialHistoricalDiffs(
                    diffs,
                    for: key
                )
            }
        }
    }

    func cacheHistoricalDiff(
        _ diff: GitFileDiff,
        worktreeID: GitWorktree.ID,
        context: ReviewContext,
        options: GitDiffOptions
    ) async {
        guard let reviewContentStore,
              let key = HistoricalReviewDiffCacheKey(
                  worktreeID: worktreeID,
                  context: context,
                  options: options
              ) else {
            return
        }
        await cacheReviewContent {
            try await reviewContentStore.saveHistoricalDiff(diff, for: key)
        }
    }

    private func cacheReviewContent(
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            reviewContentCacheError = nil
        } catch {
            reviewContentCacheError = String(describing: error)
        }
    }

    func searchHistoryPage(
        worktree: GitWorktree,
        revision: String?,
        query: GitHistorySearchQuery,
        offset: Int,
        pageSize: Int
    ) async throws -> GitHistoryPage {
        try await repositoryService.searchHistoryPage(
            worktree: worktree,
            revision: revision,
            query: query,
            offset: offset,
            pageSize: pageSize
        )
    }

    func loadCommitMessage(worktree: GitWorktree, commit: GitCommit) async throws -> String {
        try await repositoryService.loadCommitMessage(worktree: worktree, commit: commit)
    }

    func loadCommitMetadata(
        worktree: GitWorktree,
        commit: GitCommit
    ) async throws -> GitCommitMetadata {
        try await repositoryService.loadCommitMetadata(
            worktree: worktree,
            commit: commit
        )
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
        change: GitFileChange,
        options: GitDiffOptions? = nil
    ) async throws -> GitFileDiff {
        try await repositoryService.loadCommitDiff(
            worktree: worktree,
            commit: commit,
            change: change,
            options: options ?? diffOptions
        )
    }

    func loadCommitDiffs(
        worktree: GitWorktree,
        commit: GitCommit,
        changes: [GitFileChange],
        options: GitDiffOptions? = nil
    ) async throws -> [GitFileDiff] {
        try await repositoryService.loadCommitDiffs(
            worktree: worktree,
            commit: commit,
            changes: changes,
            options: options ?? diffOptions
        )
    }

    func loadCommitDiffBatches(
        worktree: GitWorktree,
        commit: GitCommit,
        changes: [GitFileChange],
        options: GitDiffOptions? = nil
    ) -> AsyncThrowingStream<[GitFileDiff], any Error> {
        repositoryService.loadCommitDiffBatches(
            worktree: worktree,
            commit: commit,
            changes: changes,
            options: options ?? diffOptions
        )
    }

    func loadCommitImageDiff(
        worktree: GitWorktree,
        commit: GitCommit,
        change: GitFileChange
    ) async throws -> GitImageDiff {
        try await repositoryService.loadCommitImageDiff(
            worktree: worktree,
            commit: commit,
            change: change
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
        changes: [GitFileChange],
        options: GitDiffOptions? = nil
    ) async throws -> [GitFileDiff] {
        try await repositoryService.loadRangeDiffs(
            worktree: worktree,
            baseOID: baseOID,
            headOID: headOID,
            changes: changes,
            options: options ?? diffOptions
        )
    }

    func loadRangeDiffBatches(
        worktree: GitWorktree,
        baseOID: String,
        headOID: String,
        changes: [GitFileChange],
        options: GitDiffOptions? = nil
    ) -> AsyncThrowingStream<[GitFileDiff], any Error> {
        repositoryService.loadRangeDiffBatches(
            worktree: worktree,
            baseOID: baseOID,
            headOID: headOID,
            changes: changes,
            options: options ?? diffOptions
        )
    }

    func loadRangeDiff(
        worktree: GitWorktree,
        baseOID: String,
        headOID: String,
        change: GitFileChange,
        options: GitDiffOptions? = nil
    ) async throws -> GitFileDiff {
        try await repositoryService.loadRangeDiff(
            worktree: worktree,
            baseOID: baseOID,
            headOID: headOID,
            change: change,
            options: options ?? diffOptions
        )
    }

    func loadRangeImageDiff(
        worktree: GitWorktree,
        baseOID: String,
        headOID: String,
        change: GitFileChange
    ) async throws -> GitImageDiff {
        try await repositoryService.loadRangeImageDiff(
            worktree: worktree,
            baseOID: baseOID,
            headOID: headOID,
            change: change
        )
    }

    func removeProject(id: GitProject.ID) {
        let removedWorktreeIDs = Set(
            projects.first(where: { $0.id == id })?.snapshot?.worktrees.map(\.id) ?? []
        )
        projects.removeAll { $0.id == id }
        completeProjectSnapshotIDs.remove(id)
        projectRefreshTasks[id]?.task.cancel()
        projectRefreshTasks[id] = nil
        for worktreeID in removedWorktreeIDs {
            worktreeRefreshTasks[worktreeID]?.task.cancel()
            worktreeRefreshTasks[worktreeID] = nil
            blockingGitRefreshErrors[worktreeID] = nil
        }
        refreshCoordinator.removeProject(id, worktreeIDs: removedWorktreeIDs)
        pendingEventProjectIDs.remove(id)
        pendingEventWorktreeIDs.subtract(removedWorktreeIDs)
        pendingEventMetadataWorktreeIDs.subtract(removedWorktreeIDs)
        for worktreeID in removedWorktreeIDs {
            pendingEventContentPathsByWorktreeID[worktreeID] = nil
        }
        collapsedProjectIDs.remove(id)
        pinnedWorktreeIDs.subtract(removedWorktreeIDs)
        if let selectedWorktreeID, removedWorktreeIDs.contains(selectedWorktreeID) {
            self.selectedWorktreeID = firstAvailableWorktreeID()
        }
        persistProjects()
        updateRepositoryMonitor()
    }

    func setApplicationActive(_ isActive: Bool) {
        guard isApplicationActive != isActive else {
            return
        }
        isApplicationActive = isActive
        agentAssociations.setApplicationActive(isActive)
        if isActive {
            scheduleForegroundRefresh()
            scheduleRepositoryEventRefresh()
            return
        }

        foregroundRefreshSequence &+= 1
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
        reviewStates.flush()
        snapshotCacheSaveTask?.cancel()
        snapshotCacheSaveTask = Task { [weak self] in
            await self?.saveSnapshotCache()
        }
        eventDebounceTask?.cancel()
        eventDebounceTask = nil
        repositoryFileMonitor?.stop()
        for refresh in projectRefreshTasks.values {
            refresh.task.cancel()
        }
        for refresh in worktreeRefreshTasks.values {
            refresh.task.cancel()
        }
    }

    func prepareForTermination() async {
        isTerminating = true
        cleanupTimerTask?.cancel()
        cleanupTimerTask = nil
        // 等待已开始的 git worktree remove 完成，避免退出进程打断删除。
        await cleanupRunTask?.value
        isApplicationActive = false
        agentAssociations.setApplicationActive(false)
        foregroundRefreshSequence &+= 1
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
        eventDebounceTask?.cancel()
        eventDebounceTask = nil
        repositoryFileMonitor?.stop()
        for refresh in projectRefreshTasks.values {
            refresh.task.cancel()
        }
        for refresh in worktreeRefreshTasks.values {
            refresh.task.cancel()
        }
        reviewStates.flush()
        snapshotCacheSaveTask?.cancel()
        snapshotCacheSaveTask = nil
        _ = await saveSnapshotCache()
    }

    private func scheduleForegroundRefresh() {
        foregroundRefreshSequence &+= 1
        let sequence = foregroundRefreshSequence
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = Task { [weak self] in
            await self?.refreshAllIfStale()
            guard !Task.isCancelled,
                  let self,
                  self.foregroundRefreshSequence == sequence else {
                return
            }
            self.foregroundRefreshTask = nil
        }
    }

    func isWorktreePinned(id: GitWorktreeSnapshot.ID) -> Bool {
        pinnedWorktreeIDs.contains(id)
    }

    func toggleWorktreePinned(id: GitWorktreeSnapshot.ID) {
        guard cleanupRemovalWorktreeID != id else { return }
        if pinnedWorktreeIDs.contains(id) {
            pinnedWorktreeIDs.remove(id)
        } else {
            pinnedWorktreeIDs.insert(id)
        }
    }

    func isProjectExcludedFromCleanup(id: GitProject.ID) -> Bool {
        cleanupExcludedProjectIDs.contains(id)
    }

    func setProjectCleanupExcluded(_ excluded: Bool, id: GitProject.ID) {
        if excluded {
            cleanupExcludedProjectIDs.insert(id)
        } else {
            cleanupExcludedProjectIDs.remove(id)
        }
    }

    private func scheduleWorktreeCleanup() {
        cleanupTimerTask?.cancel()
        cleanupTimerTask = nil
        guard hasLoadedProjects, cleanupSettings.isEnabled, !isTerminating else { return }
        if cleanupRunTask == nil {
            cleanupRunTask = Task { [weak self] in
                await self?.runWorktreeCleanupIfNeeded()
                self?.cleanupRunTask = nil
            }
        }
        cleanupTimerTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            self?.scheduleWorktreeCleanup()
        }
    }

    func runWorktreeCleanupIfNeeded(now: Date = Date()) async {
        await runWorktreeCleanup(now: now, immediately: false)
    }

    func runWorktreeCleanupNow(now: Date = Date()) async {
        guard cleanupRunTask == nil, !isCleaningWorktrees, !isTerminating else { return }
        let task = Task<Void, Never> { [weak self] in
            await self?.runWorktreeCleanup(now: now, immediately: true)
        }
        cleanupRunTask = task
        await task.value
        cleanupRunTask = nil
    }

    private func runWorktreeCleanup(now: Date, immediately: Bool) async {
        let settings = cleanupSettings
        let isDue = cleanupReport.map { now.timeIntervalSince($0.checkedAt) >= settings.interval } ?? true
        guard !isTerminating, !isCleaningWorktrees,
              immediately || (settings.isEnabled && isDue) else {
            return
        }
        isCleaningWorktrees = true
        defer {
            isCleaningWorktrees = false
            cleanupRemovalWorktreeID = nil
        }
        var report = WorktreeCleanupReport(checkedAt: now)
        let cutoff = now.addingTimeInterval(-settings.inactivity)
        for project in projects.map(\.project) {
            guard !isTerminating, cleanupSettings == settings else { break }
            guard !isProjectExcludedFromCleanup(id: project.id) else { continue }
            do {
                // 后台也直接读取 Git 成员与状态，不依赖界面缓存。
                let worktrees = try await repositoryService.listWorktrees(at: project.rootURL)
                for worktree in worktrees where worktree.id != project.id {
                    guard !isTerminating, cleanupSettings == settings else { break }
                    do {
                        guard canCleanWorktree(worktree, project: project) else {
                            report.skippedCount += 1
                            continue
                        }
                        let result = try await cleanupService.removeIfInactive(
                            worktree, project: project, inactiveSince: cutoff,
                            willRemove: { @MainActor [weak self] in
                                guard let self, !self.isTerminating, self.cleanupSettings == settings,
                                      self.canCleanWorktree(worktree, project: project) else {
                                    return false
                                }
                                self.cleanupRemovalWorktreeID = worktree.id
                                return true
                            },
                            isRemovalAllowed: { @MainActor [weak self] in
                                guard let self, !self.isTerminating, self.cleanupSettings == settings else {
                                    return false
                                }
                                return self.canCleanWorktree(worktree, project: project)
                            }
                        )
                        cleanupRemovalWorktreeID = nil
                        switch result {
                        case .removed:
                            report.removedPaths.append(worktree.id)
                            forgetRemovedWorktree(worktree.id, projectID: project.id)
                        case .skipped:
                            report.skippedCount += 1
                        }
                    } catch {
                        cleanupRemovalWorktreeID = nil
                        report.errors.append("\(worktree.rootURL.path): \(error)")
                    }
                }
            } catch {
                report.errors.append("\(project.rootURL.path): \(error)")
            }
        }
        cleanupReport = report
        if let data = try? JSONEncoder().encode(report) {
            defaults.set(data, forKey: Self.cleanupReportKey)
        }
        if !report.removedPaths.isEmpty {
            updateRepositoryMonitor()
            _ = await saveSnapshotCache()
        }
    }

    private func canCleanWorktree(
        _ worktree: GitWorktree, project: GitProject
    ) -> Bool {
        guard projects.contains(where: { $0.id == project.id }),
              !isProjectExcludedFromCleanup(id: project.id),
              worktree.id != selectedWorktreeID,
              !pinnedWorktreeIDs.contains(worktree.id),
              !mutationWorktreeIDs.contains(worktree.id),
              blockingGitRefreshErrors[worktree.id] == nil else {
            return false
        }
        return true
    }

    private func forgetRemovedWorktree(_ id: GitWorktree.ID, projectID: GitProject.ID) {
        // 使正在运行的刷新失效，防止旧结果重新添加已经删除的行。
        projectRefreshTasks[projectID]?.task.cancel()
        projectRefreshTasks[projectID] = nil
        worktreeRefreshTasks[id]?.task.cancel()
        worktreeRefreshTasks[id] = nil
        refreshCoordinator.removeProject(projectID, worktreeIDs: [id])
        pendingEventWorktreeIDs.remove(id)
        pendingEventMetadataWorktreeIDs.remove(id)
        pendingEventContentPathsByWorktreeID[id] = nil
        blockingGitRefreshErrors[id] = nil
        if let index = projects.firstIndex(where: { $0.id == projectID }),
           let snapshot = projects[index].snapshot {
            projects[index].snapshot = GitProjectSnapshot(
                project: snapshot.project,
                worktrees: snapshot.worktrees.filter { $0.id != id },
                refreshedAt: snapshot.refreshedAt
            )
            projects[index].isLoading = false
        }
    }

    func toggleProjectCollapsed(id: GitProject.ID) {
        if collapsedProjectIDs.contains(id) {
            collapsedProjectIDs.remove(id)
        } else {
            collapsedProjectIDs.insert(id)
        }
    }

    func moveProject(
        id: GitProject.ID,
        relativeTo targetID: GitProject.ID,
        placeAfterTarget: Bool
    ) {
        guard id != targetID,
              let sourceIndex = projects.firstIndex(where: { $0.id == id }) else {
            return
        }
        let project = projects.remove(at: sourceIndex)
        guard let targetIndex = projects.firstIndex(where: { $0.id == targetID }) else {
            projects.insert(project, at: sourceIndex)
            return
        }
        projects.insert(project, at: targetIndex + (placeAfterTarget ? 1 : 0))
        persistProjects()
    }

    private func applyLoadResult(
        token: RepositoryRefreshToken,
        baselineSnapshot: GitProjectSnapshot?,
        snapshot: GitProjectSnapshot?,
        errorMessage: String?
    ) {
        guard refreshCoordinator.acceptsProject(token),
              let index = projects.firstIndex(where: { $0.id == token.projectID }) else {
            return
        }

        if let snapshot {
            projects[index].snapshot = mergedProjectSnapshot(
                snapshot,
                preservingNewerWorktreesFrom: projects[index].snapshot,
                token: token
            )
            for worktree in snapshot.worktrees
                where worktree.hasUsableState
                    && !refreshCoordinator.shouldPreserveWorktree(
                        worktree.id,
                        fromProject: token
                    ) {
                blockingGitRefreshErrors[worktree.id] = nil
            }
        } else if let baselineSnapshot {
            projects[index].snapshot = mergedProjectSnapshot(
                baselineSnapshot,
                preservingNewerWorktreesFrom: projects[index].snapshot,
                token: token
            )
        } else {
            projects[index].snapshot = nil
        }
        projects[index].errorMessage = errorMessage
        scheduleSnapshotCacheSave()
    }

    private func mergedProjectSnapshot(
        _ incoming: GitProjectSnapshot,
        preservingNewerWorktreesFrom current: GitProjectSnapshot?,
        token: RepositoryRefreshToken
    ) -> GitProjectSnapshot {
        guard let current else {
            return incoming
        }
        let currentByID = Dictionary(
            uniqueKeysWithValues: current.worktrees.map { ($0.id, $0) }
        )
        var worktrees = incoming.worktrees.map { worktree in
            let currentWorktree = currentByID[worktree.id]
            guard refreshCoordinator.shouldPreserveWorktree(
                worktree.id,
                fromProject: token
            ) else {
                return worktreeSnapshotByApplyingRefresh(
                    worktree,
                    preserving: currentWorktree
                )
            }
            return currentWorktree ?? worktree
        }
        let incomingIDs = Set(incoming.worktrees.map(\.id))
        worktrees.append(contentsOf: current.worktrees.filter { worktree in
            !incomingIDs.contains(worktree.id)
                && refreshCoordinator.shouldPreserveWorktree(
                    worktree.id,
                    fromProject: token
                )
        })
        worktrees.sort(by: compareWorktreeSnapshots)
        return GitProjectSnapshot(
            project: incoming.project,
            worktrees: worktrees,
            refreshedAt: incoming.refreshedAt
        )
    }

    private func startProjectRefresh(_ project: GitProject) -> ProjectRefreshRequest {
        projectRefreshTasks[project.id]?.task.cancel()
        let baselineSnapshot = projects.first(where: { $0.id == project.id })?.snapshot
        let token = beginProjectRefresh(project.id)
        let service = repositoryService
        let selectedIDForProject: GitWorktree.ID? = if selectedWorktreeProjectID == project.id {
            selectedWorktreeID
        } else {
            projects.first(where: { $0.id == project.id })?
                .snapshot?.worktrees.first(where: { $0.id == selectedWorktreeID })?.id
        }
        let prioritizedWorktreeID = selectedIDForProject
            ?? project.rootURL.standardizedFileURL.path
        let prioritizedSubmoduleScanMode: GitSubmoduleScanMode = if selectedIDForProject != nil
            || (selectedWorktreeID == nil && projects.first?.id == project.id) {
            .allChanges
        } else {
            .commitsOnly
        }
        let task = Task { () -> ProjectRefreshResult in
            do {
                var loadedWorktrees: [GitWorktree.ID: GitWorktreeSnapshot] = [:]
                var refreshedProject = project
                for try await event in service.projectRefreshEvents(
                    at: project.rootURL,
                    prioritizedWorktreeID: prioritizedWorktreeID,
                    prioritizedSubmoduleScanMode: prioritizedSubmoduleScanMode,
                    maximumConcurrentWorktrees: Self.maximumConcurrentWorktreeRefreshes
                ) {
                    try Task.checkCancellation()
                    switch event {
                    case let .discovered(discoveredProject, worktrees):
                        refreshedProject = discoveredProject
                        prepareProjectRefresh(
                            token: token,
                            project: discoveredProject,
                            discoveredWorktrees: worktrees
                        )
                    case let .worktree(snapshot):
                        loadedWorktrees[snapshot.id] = snapshot
                        applyPartialProjectRefresh(
                            token: token,
                            project: refreshedProject,
                            worktree: snapshot
                        )
                    }
                }
                let snapshot = GitProjectSnapshot(
                    project: refreshedProject,
                    worktrees: loadedWorktrees.values.sorted(
                        by: compareWorktreeSnapshots
                    ),
                    refreshedAt: Date()
                )
                return ProjectRefreshResult(
                    snapshot: snapshot,
                    errorMessage: nil
                )
            } catch is CancellationError {
                return ProjectRefreshResult(
                    snapshot: nil,
                    errorMessage: nil
                )
            } catch {
                return ProjectRefreshResult(
                    snapshot: nil,
                    errorMessage: String(describing: error)
                )
            }
        }
        projectRefreshTasks[project.id] = ActiveProjectRefresh(
            sequence: token.sequence,
            task: task
        )
        return ProjectRefreshRequest(
            token: token,
            baselineSnapshot: baselineSnapshot,
            task: task
        )
    }

    private func startProjectMembershipRefresh(
        _ project: GitProject,
        current: GitProjectSnapshot,
        discoveredWorktrees: [GitWorktree]
    ) -> ProjectRefreshRequest {
        projectRefreshTasks[project.id]?.task.cancel()
        let discoveredIDs = Set(discoveredWorktrees.map(\.id))
        let removedIDs = Set(current.worktrees.map(\.id)).subtracting(discoveredIDs)
        for worktreeID in removedIDs {
            worktreeRefreshTasks[worktreeID]?.task.cancel()
            worktreeRefreshTasks[worktreeID] = nil
        }
        pendingEventWorktreeIDs.subtract(removedIDs)

        let token = beginProjectRefresh(project.id)
        let service = repositoryService
        let currentByID = Dictionary(
            uniqueKeysWithValues: current.worktrees.map { ($0.id, $0) }
        )
        let selectedIDForProject: GitWorktree.ID? = selectedWorktreeProjectID == project.id
            ? selectedWorktreeID
            : nil
        let loadTargets = discoveredWorktrees.filter { worktree in
            currentByID[worktree.id] == nil
        }
        let maximumConcurrentWorktrees = Self.maximumConcurrentWorktreeRefreshes
        let task = Task { () -> ProjectRefreshResult in
            let loaded = await Self.loadMembershipWorktrees(
                loadTargets,
                selectedWorktreeID: selectedIDForProject,
                maximumConcurrency: maximumConcurrentWorktrees,
                using: service
            )
            do {
                try Task.checkCancellation()
            } catch is CancellationError {
                return ProjectRefreshResult(
                    snapshot: nil,
                    errorMessage: nil
                )
            } catch {
                return ProjectRefreshResult(
                    snapshot: nil,
                    errorMessage: String(describing: error)
                )
            }
            let loadedByID = Dictionary(
                uniqueKeysWithValues: loaded.map { ($0.id, $0) }
            )
            let snapshots = discoveredWorktrees.compactMap { worktree in
                if let refreshed = loadedByID[worktree.id] {
                    return refreshed
                }
                guard let existing = currentByID[worktree.id] else {
                    return nil
                }
                return worktreeSnapshotByApplyingDiscovery(
                    worktree,
                    preserving: existing
                )
            }
            return ProjectRefreshResult(
                snapshot: GitProjectSnapshot(
                    project: project,
                    worktrees: snapshots.sorted(by: compareWorktreeSnapshots),
                    refreshedAt: Date()
                ),
                errorMessage: nil
            )
        }
        projectRefreshTasks[project.id] = ActiveProjectRefresh(
            sequence: token.sequence,
            task: task
        )
        return ProjectRefreshRequest(
            token: token,
            baselineSnapshot: current,
            task: task
        )
    }

    private nonisolated static func loadMembershipWorktrees(
        _ worktrees: [GitWorktree],
        selectedWorktreeID: GitWorktree.ID?,
        maximumConcurrency: Int,
        using service: GitRepositoryService
    ) async -> [GitWorktreeSnapshot] {
        await withTaskGroup(of: GitWorktreeSnapshot.self) { group in
            let concurrency = min(maximumConcurrency, worktrees.count)
            for worktree in worktrees.prefix(concurrency) {
                group.addTask {
                    await service.loadWorktree(
                        worktree,
                        submoduleScanMode: worktree.id == selectedWorktreeID
                            ? .allChanges
                            : .commitsOnly
                    )
                }
            }
            var snapshots: [GitWorktreeSnapshot] = []
            var nextIndex = concurrency
            while let snapshot = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                snapshots.append(snapshot)
                if nextIndex < worktrees.count {
                    let worktree = worktrees[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        await service.loadWorktree(
                            worktree,
                            submoduleScanMode: worktree.id == selectedWorktreeID
                                ? .allChanges
                                : .commitsOnly
                        )
                    }
                }
            }
            return snapshots
        }
    }

    private func prepareProjectRefresh(
        token: RepositoryRefreshToken,
        project: GitProject,
        discoveredWorktrees: [GitWorktree]
    ) {
        guard refreshCoordinator.acceptsProject(token),
              let index = projects.firstIndex(where: { $0.id == token.projectID }),
              let current = projects[index].snapshot else {
            return
        }
        let discoveredIDs = Set(discoveredWorktrees.map(\.id))
        let retained = current.worktrees.filter { discoveredIDs.contains($0.id) }
        projects[index].snapshot = GitProjectSnapshot(
            project: project,
            worktrees: retained,
            refreshedAt: current.refreshedAt
        )
    }

    private func applyPartialProjectRefresh(
        token: RepositoryRefreshToken,
        project: GitProject,
        worktree: GitWorktreeSnapshot
    ) {
        guard refreshCoordinator.acceptsProject(token),
              !refreshCoordinator.shouldPreserveWorktree(worktree.id, fromProject: token),
              let index = projects.firstIndex(where: { $0.id == token.projectID }) else {
            return
        }
        var worktrees = projects[index].snapshot?.worktrees ?? []
        if let worktreeIndex = worktrees.firstIndex(where: { $0.id == worktree.id }) {
            worktrees[worktreeIndex] = worktreeSnapshotByApplyingRefresh(
                worktree,
                preserving: worktrees[worktreeIndex]
            )
        } else {
            worktrees.append(worktree)
        }
        worktrees.sort(by: compareWorktreeSnapshots)
        projects[index].snapshot = GitProjectSnapshot(
            project: project,
            worktrees: worktrees,
            refreshedAt: Date()
        )
        projects[index].errorMessage = nil
        if worktree.hasUsableState {
            blockingGitRefreshErrors[worktree.id] = nil
        }
        scheduleSnapshotCacheSave()
        if selectedWorktreeID == nil {
            selectedWorktreeID = worktree.id
        }
    }

    private func completeProjectRefresh(_ request: ProjectRefreshRequest) async {
        let result = await withTaskCancellationHandler {
            await request.task.value
        } onCancel: {
            request.task.cancel()
        }
        applyLoadResult(
            token: request.token,
            baselineSnapshot: request.baselineSnapshot,
            snapshot: result.snapshot,
            errorMessage: result.errorMessage
        )
        if result.snapshot != nil, result.errorMessage == nil {
            completeProjectSnapshotIDs.insert(request.token.projectID)
        }
        if projectRefreshTasks[request.token.projectID]?.sequence == request.token.sequence {
            projectRefreshTasks[request.token.projectID] = nil
        }
        finishRefresh(request.token)
    }

    private func beginProjectRefresh(_ id: GitProject.ID) -> RepositoryRefreshToken {
        let token = refreshCoordinator.beginProject(id)
        if let index = projects.firstIndex(where: { $0.id == id }) {
            projects[index].isLoading = true
            projects[index].errorMessage = nil
        }
        return token
    }

    private func finishRefresh(_ token: RepositoryRefreshToken) {
        refreshCoordinator.finish(token)
        if let index = projects.firstIndex(where: { $0.id == token.projectID }) {
            projects[index].isLoading = projectRefreshTasks[token.projectID] != nil
        }
        scheduleRepositoryEventRefresh()
    }

    private func firstAvailableWorktreeID() -> GitWorktreeSnapshot.ID? {
        projects.lazy.compactMap(\.snapshot).flatMap(\.worktrees).first?.id
    }

    private var awaitsSelectedWorktreeRecovery: Bool {
        guard selectedWorktree == nil,
              selectedWorktreeID != nil,
              let selectedWorktreeProjectID,
              projects.contains(where: { $0.id == selectedWorktreeProjectID }) else {
            return false
        }
        return !completeProjectSnapshotIDs.contains(selectedWorktreeProjectID)
    }

    private func fallbackToAvailableWorktreeIfSelectionIsResolved() {
        guard selectedWorktree == nil,
              !awaitsSelectedWorktreeRecovery else {
            return
        }
        selectedWorktreeID = firstAvailableWorktreeID()
    }

    private func persistProjects() {
        completeProjectSnapshotIDs.formIntersection(Set(projects.map(\.id)))
        defaults.set(projects.map { $0.project.rootURL.path }, forKey: Self.projectPathsKey)
        scheduleSnapshotCacheSave()
    }

    private func scheduleSnapshotCacheSave() {
        guard snapshotStore != nil else {
            return
        }
        snapshotCacheSaveTask?.cancel()
        snapshotCacheSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            await self?.saveSnapshotCache()
        }
    }

    @discardableResult
    private func saveSnapshotCache(
        eventID: FSEventStreamEventId? = nil
    ) async -> Bool {
        guard let snapshotStore else {
            return true
        }
        let targetEventID = eventID ?? snapshotCacheEventID
        let projectIDs = projects.map(\.id)
        let snapshots = projects.compactMap(\.snapshot)
        do {
            try await snapshotStore.save(
                projectIDs: projectIDs,
                snapshots: snapshots,
                eventID: targetEventID,
                completeProjectIDs: completeProjectSnapshotIDs
            )
            if let eventID {
                snapshotCacheEventID = max(snapshotCacheEventID, eventID)
            }
            snapshotCacheError = nil
            return true
        } catch {
            snapshotCacheError = String(describing: error)
            return false
        }
    }

    private func persistSelectedWorktreeSelection() {
        guard let selectedWorktreeID else {
            selectedWorktreeProjectID = nil
            defaults.removeObject(forKey: Self.selectedWorktreeIDKey)
            defaults.removeObject(forKey: Self.selectedWorktreeProjectIDKey)
            return
        }
        defaults.set(selectedWorktreeID, forKey: Self.selectedWorktreeIDKey)
        if let projectID = projects.first(where: { state in
            state.snapshot?.worktrees.contains(where: { $0.id == selectedWorktreeID }) == true
        })?.id {
            selectedWorktreeProjectID = projectID
        }
        if let selectedWorktreeProjectID {
            defaults.set(
                selectedWorktreeProjectID,
                forKey: Self.selectedWorktreeProjectIDKey
            )
        }
    }

    private func updateRepositoryMonitor() {
        guard isApplicationActive else {
            repositoryFileMonitor?.stop()
            return
        }
        if repositoryFileMonitor == nil {
            repositoryFileMonitor = RepositoryFileMonitor(
                sinceWhen: snapshotCacheEventID
            ) { [weak self] impact, eventID in
                Task { @MainActor [weak self] in
                    self?.enqueueRepositoryEvents(impact, eventID: eventID)
                }
            }
        }
        do {
            try repositoryFileMonitor?.update(index: RepositoryWatchIndex(projects: projects))
            repositoryMonitorError = nil
        } catch {
            repositoryMonitorError = String(describing: error)
        }
    }

    func enqueueRepositoryEvents(
        _ impact: RepositoryChangeImpact,
        eventID: FSEventStreamEventId
    ) {
        if impact.isEmpty {
            pendingRepositoryEventID = max(pendingRepositoryEventID ?? 0, eventID)
            if isApplicationActive {
                scheduleRepositoryEventRefresh()
            }
            return
        }
        pendingEventProjectIDs.formUnion(impact.projectIDs)
        pendingEventWorktreeIDs.formUnion(impact.worktreeIDs)
        pendingEventMetadataWorktreeIDs.formUnion(
            impact.metadataWorktreeIDs
        )
        for (worktreeID, paths) in impact.contentPathsByWorktreeID {
            pendingEventContentPathsByWorktreeID[
                worktreeID,
                default: []
            ].formUnion(paths)
        }
        pendingRepositoryEventID = max(pendingRepositoryEventID ?? 0, eventID)
        if isApplicationActive {
            scheduleRepositoryEventRefresh()
        }
    }

    private func scheduleRepositoryEventRefresh() {
        guard isApplicationActive,
              !pendingEventProjectIDs.isEmpty
                || !pendingEventWorktreeIDs.isEmpty
                || pendingRepositoryEventID != nil,
              !isProcessingRepositoryEvents else {
            return
        }
        eventDebounceTask?.cancel()
        eventDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch is CancellationError {
                return
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            await self?.refreshPendingRepositoryEvents()
        }
    }

    private func refreshPendingRepositoryEvents() async {
        eventDebounceTask = nil
        guard isApplicationActive, !isProcessingRepositoryEvents else {
            return
        }
        isProcessingRepositoryEvents = true
        defer {
            isProcessingRepositoryEvents = false
            scheduleRepositoryEventRefresh()
        }

        let requestedProjectIDs = pendingEventProjectIDs
        let requestedWorktreeIDs = pendingEventWorktreeIDs
        let requestedMetadataWorktreeIDs = pendingEventMetadataWorktreeIDs
        let requestedContentPathsByWorktreeID =
            pendingEventContentPathsByWorktreeID
        let requestedEventID = pendingRepositoryEventID
        pendingEventProjectIDs = []
        pendingEventWorktreeIDs = []
        pendingEventMetadataWorktreeIDs = []
        pendingEventContentPathsByWorktreeID = [:]
        pendingRepositoryEventID = nil
        var deferredProjectIDs: Set<GitProject.ID> = []
        var deferredWorktreeIDs: Set<GitWorktree.ID> = []

        let orderedProjectIDs = orderedRepositoryEventProjectIDs(
            requestedProjectIDs,
            projects: projects,
            selectedWorktreeID: selectedWorktreeID
        )
        var membershipCheckProjectIDs: Set<GitProject.ID> = []
        for projectID in orderedProjectIDs {
            guard projects.contains(where: { $0.id == projectID }) else {
                continue
            }
            guard projectRefreshTasks[projectID] == nil else {
                pendingEventProjectIDs.insert(projectID)
                deferredProjectIDs.insert(projectID)
                continue
            }
            membershipCheckProjectIDs.insert(projectID)
        }
        let changedMembershipProjectIDs = await reconcileProjectWorktreeMembership(
            projectIDs: membershipCheckProjectIDs
        )

        var worktrees: [GitWorktreeSnapshot] = []
        for worktreeID in requestedWorktreeIDs {
            guard let project = projects.first(where: { state in
                state.snapshot?.worktrees.contains(where: { $0.id == worktreeID }) == true
            }), let worktree = project.snapshot?.worktrees.first(where: {
                $0.id == worktreeID
            }) else {
                continue
            }
            guard !changedMembershipProjectIDs.contains(project.id) else {
                continue
            }
            guard projectRefreshTasks[project.id] == nil,
                  worktreeRefreshTasks[worktreeID] == nil else {
                pendingEventWorktreeIDs.insert(worktreeID)
                if requestedMetadataWorktreeIDs.contains(worktreeID) {
                    pendingEventMetadataWorktreeIDs.insert(worktreeID)
                }
                if let paths = requestedContentPathsByWorktreeID[worktreeID] {
                    pendingEventContentPathsByWorktreeID[
                        worktreeID,
                        default: []
                    ].formUnion(paths)
                }
                deferredWorktreeIDs.insert(worktreeID)
                continue
            }
            if !requestedMetadataWorktreeIDs.contains(worktreeID),
               let paths = requestedContentPathsByWorktreeID[worktreeID],
               !paths.isEmpty {
                do {
                    let containsRelevantEvent = try await repositoryService
                        .containsGitRelevantWorkingTreeEvent(
                            worktree: worktree.worktree,
                            absolutePaths: Array(paths)
                        )
                    guard containsRelevantEvent else {
                        continue
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // ignore 规则读取失败时保留刷新，确保仓库状态不会停留在旧值。
                }
            }
            worktrees.append(worktree)
        }

        worktrees.sort { lhs, rhs in
            let lhsSelected = lhs.id == selectedWorktreeID
            let rhsSelected = rhs.id == selectedWorktreeID
            if lhsSelected != rhsSelected {
                return lhsSelected
            }
            return compareWorktreeSnapshots(lhs, rhs)
        }

        await withTaskGroup(of: Void.self) { group in
            let initialCount = min(
                Self.maximumConcurrentEventRefreshes,
                worktrees.count
            )
            for worktree in worktrees.prefix(initialCount) {
                let submoduleScanMode: GitSubmoduleScanMode = worktree.id == selectedWorktreeID
                    ? .allChanges
                    : .commitsOnly
                group.addTask { [weak self] in
                    _ = await self?.refresh(
                        worktree: worktree.worktree,
                        submoduleScanMode: submoduleScanMode
                    )
                }
            }
            var nextIndex = initialCount
            while await group.next() != nil {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                if nextIndex < worktrees.count {
                    let worktree = worktrees[nextIndex]
                    nextIndex += 1
                    let submoduleScanMode: GitSubmoduleScanMode = worktree.id
                            == selectedWorktreeID
                        ? .allChanges
                        : .commitsOnly
                    group.addTask { [weak self] in
                        _ = await self?.refresh(
                            worktree: worktree.worktree,
                            submoduleScanMode: submoduleScanMode
                        )
                    }
                }
            }
        }
        guard !Task.isCancelled else {
            return
        }
        let hasDeferredRefresh = !deferredProjectIDs.isEmpty
            || !deferredWorktreeIDs.isEmpty
        if hasDeferredRefresh, let requestedEventID {
            pendingRepositoryEventID = max(
                pendingRepositoryEventID ?? 0,
                requestedEventID
            )
        }
        let projectRefreshFailed = projects.contains { project in
            guard requestedProjectIDs.contains(project.id) else {
                return false
            }
            return project.errorMessage != nil
                || project.snapshot?.worktrees.contains(where: {
                    $0.errorMessage != nil
                }) == true
        }
        let worktreeRefreshFailed = projects.lazy
            .compactMap(\.snapshot)
            .flatMap(\.worktrees)
            .contains { worktree in
                requestedWorktreeIDs.contains(worktree.id)
                    && worktree.errorMessage != nil
            }
        if let requestedEventID,
           !hasDeferredRefresh,
           !projectRefreshFailed,
           !worktreeRefreshFailed {
            snapshotCacheSaveTask?.cancel()
            snapshotCacheSaveTask = nil
            _ = await saveSnapshotCache(eventID: requestedEventID)
        } else {
            scheduleSnapshotCacheSave()
        }
    }

    @discardableResult
    private func refresh(
        worktree: GitWorktree,
        submoduleScanMode: GitSubmoduleScanMode
    ) async -> WorktreeRefreshOutcome {
        guard let projectIndex = projects.firstIndex(where: { projectState in
            projectState.snapshot?.worktrees.contains(where: { $0.id == worktree.id }) == true
        }), let projectSnapshot = projects[projectIndex].snapshot else {
            return .failed("The worktree is no longer part of a loaded project.")
        }
        let token = refreshCoordinator.beginWorktree(
            worktree.id,
            projectID: projectSnapshot.id
        )
        worktreeRefreshTasks[worktree.id]?.task.cancel()
        let service = repositoryService
        let refreshTask = Task {
            await service.loadWorktree(
                worktree,
                submoduleScanMode: submoduleScanMode
            )
        }
        worktreeRefreshTasks[worktree.id] = ActiveWorktreeRefresh(
            sequence: token.sequence,
            task: refreshTask
        )
        projects[projectIndex].errorMessage = nil
        defer {
            if worktreeRefreshTasks[worktree.id]?.sequence == token.sequence {
                worktreeRefreshTasks[worktree.id] = nil
            }
            finishRefresh(token)
        }
        let refreshedWorktree = await withTaskCancellationHandler {
            await refreshTask.value
        } onCancel: {
            refreshTask.cancel()
        }
        guard !refreshTask.isCancelled,
              !Task.isCancelled,
              refreshCoordinator.acceptsWorktree(token),
              let currentProjectIndex = projects.firstIndex(where: {
            $0.id == projectSnapshot.id
              }), let currentSnapshot = projects[currentProjectIndex].snapshot,
              let worktreeIndex = currentSnapshot.worktrees.firstIndex(where: {
                  $0.id == worktree.id
              }) else {
            return .superseded
        }
        var worktrees = currentSnapshot.worktrees
        worktrees[worktreeIndex] = worktreeSnapshotByApplyingRefresh(
            refreshedWorktree,
            preserving: worktrees[worktreeIndex]
        )
        worktrees.sort(by: compareWorktreeSnapshots)
        projects[currentProjectIndex].snapshot = GitProjectSnapshot(
            project: currentSnapshot.project,
            worktrees: worktrees,
            refreshedAt: Date()
        )
        projects[currentProjectIndex].errorMessage = nil
        scheduleSnapshotCacheSave()
        updateRepositoryMonitor()
        if refreshedWorktree.hasUsableState {
            blockingGitRefreshErrors[worktree.id] = nil
            return .updated
        }
        return .failed(
            refreshedWorktree.errorMessage
                ?? "Git status returned no usable repository state."
        )
    }
}

func orderedRepositoryEventProjectIDs(
    _ projectIDs: Set<GitProject.ID>,
    projects: [ProjectState],
    selectedWorktreeID: GitWorktree.ID?
) -> [GitProject.ID] {
    let selectedProjectID = projects.first(where: { project in
        guard let selectedWorktreeID else {
            return false
        }
        return project.snapshot?.worktrees.contains(where: {
            $0.id == selectedWorktreeID
        }) == true
    })?.id
    return projectIDs.sorted { lhs, rhs in
        let lhsSelected = lhs == selectedProjectID
        let rhsSelected = rhs == selectedProjectID
        if lhsSelected != rhsSelected {
            return lhsSelected
        }
        let lhsIndex = projects.firstIndex(where: { $0.id == lhs }) ?? .max
        let rhsIndex = projects.firstIndex(where: { $0.id == rhs }) ?? .max
        return lhsIndex < rhsIndex
    }
}

func worktreeSnapshotByApplyingRefresh(
    _ incoming: GitWorktreeSnapshot,
    preserving current: GitWorktreeSnapshot?
) -> GitWorktreeSnapshot {
    guard let current,
          let errorMessage = incoming.errorMessage,
          !incoming.hasUsableState else {
        return incoming
    }
    let eventWatchURLs = Set(current.eventWatchURLs + incoming.eventWatchURLs)
        .sorted { $0.path < $1.path }
    return GitWorktreeSnapshot(
        worktree: current.worktree,
        status: current.status,
        diffStat: current.diffStat,
        lastActivityAt: current.lastActivityAt,
        refreshedAt: current.refreshedAt,
        errorMessage: errorMessage,
        hasUsableState: current.hasUsableState,
        eventWatchURLs: eventWatchURLs
    )
}

func worktreeSnapshotByApplyingDiscovery(
    _ discovered: GitWorktree,
    preserving current: GitWorktreeSnapshot
) -> GitWorktreeSnapshot {
    GitWorktreeSnapshot(
        worktree: discovered,
        status: current.status,
        diffStat: current.diffStat,
        lastActivityAt: current.lastActivityAt,
        refreshedAt: current.refreshedAt,
        errorMessage: current.errorMessage,
        hasUsableState: current.hasUsableState,
        eventWatchURLs: current.eventWatchURLs
    )
}

func compareWorktreeSnapshots(
    _ lhs: GitWorktreeSnapshot,
    _ rhs: GitWorktreeSnapshot
) -> Bool {
    if lhs.lastActivityAt != rhs.lastActivityAt {
        return lhs.lastActivityAt > rhs.lastActivityAt
    }
    return lhs.worktree.displayName.localizedStandardCompare(
        rhs.worktree.displayName
    ) == .orderedAscending
}

struct RepositoryRefreshToken: Hashable, Sendable {
    let sequence: UInt64
    let projectID: GitProject.ID
    let worktreeID: GitWorktree.ID?
}

struct RepositoryRefreshCoordinator {
    private var nextSequence: UInt64 = 0
    private var latestProjectSequence: [GitProject.ID: UInt64] = [:]
    private var latestWorktreeSequence: [GitWorktree.ID: UInt64] = [:]
    private var activeSequencesByProject: [GitProject.ID: Set<UInt64>] = [:]

    mutating func beginProject(_ projectID: GitProject.ID) -> RepositoryRefreshToken {
        let sequence = makeSequence()
        latestProjectSequence[projectID] = sequence
        activeSequencesByProject[projectID, default: []].insert(sequence)
        return RepositoryRefreshToken(
            sequence: sequence,
            projectID: projectID,
            worktreeID: nil
        )
    }

    mutating func beginWorktree(
        _ worktreeID: GitWorktree.ID,
        projectID: GitProject.ID
    ) -> RepositoryRefreshToken {
        let sequence = makeSequence()
        latestWorktreeSequence[worktreeID] = sequence
        activeSequencesByProject[projectID, default: []].insert(sequence)
        return RepositoryRefreshToken(
            sequence: sequence,
            projectID: projectID,
            worktreeID: worktreeID
        )
    }

    func acceptsProject(_ token: RepositoryRefreshToken) -> Bool {
        token.worktreeID == nil
            && latestProjectSequence[token.projectID] == token.sequence
    }

    func acceptsWorktree(_ token: RepositoryRefreshToken) -> Bool {
        guard let worktreeID = token.worktreeID,
              latestWorktreeSequence[worktreeID] == token.sequence else {
            return false
        }
        return (latestProjectSequence[token.projectID] ?? 0) <= token.sequence
    }

    func shouldPreserveWorktree(
        _ worktreeID: GitWorktree.ID,
        fromProject token: RepositoryRefreshToken
    ) -> Bool {
        (latestWorktreeSequence[worktreeID] ?? 0) > token.sequence
    }

    mutating func finish(_ token: RepositoryRefreshToken) {
        activeSequencesByProject[token.projectID]?.remove(token.sequence)
        if activeSequencesByProject[token.projectID]?.isEmpty == true {
            activeSequencesByProject[token.projectID] = nil
        }
    }

    func isLoading(_ projectID: GitProject.ID) -> Bool {
        !(activeSequencesByProject[projectID]?.isEmpty ?? true)
    }

    mutating func removeProject(
        _ projectID: GitProject.ID,
        worktreeIDs: Set<GitWorktree.ID>
    ) {
        latestProjectSequence[projectID] = nil
        activeSequencesByProject[projectID] = nil
        for worktreeID in worktreeIDs {
            latestWorktreeSequence[worktreeID] = nil
        }
    }

    private mutating func makeSequence() -> UInt64 {
        nextSequence &+= 1
        return nextSequence
    }
}
