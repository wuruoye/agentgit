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

    private let defaults: UserDefaults
    private let repositoryService: GitRepositoryService
    private let pendingDiffRequests = GitPendingDiffRequests()
    private let snapshotStore: ProjectSnapshotStore?
    private let reviewContentStore: ReviewContentStore?
    private var restoredStartupReviewContent: StartupReviewContent?
    private var hasLoadedProjects = false
    private var hasNormalizedProjects = false
    private var selectedWorktreeProjectID: GitProject.ID?
    private var refreshCoordinator = RepositoryRefreshCoordinator()
    private var worktreeRefreshTasks: [GitWorktree.ID: ActiveWorktreeRefresh] = [:]
    private var projectRefreshTasks: [GitProject.ID: ActiveProjectRefresh] = [:]
    private var backgroundRefreshTask: Task<Void, Never>?
    private let backgroundRefreshInterval: Duration
    private var snapshotCacheEventID: FSEventStreamEventId
    private var completeProjectSnapshotIDs: Set<GitProject.ID>
    private var snapshotCacheSaveTask: Task<Void, Never>?
    @ObservationIgnored private var repositoryMonitor: RepositoryFileMonitor?
    @ObservationIgnored private var monitoredRepositoryPaths: Set<String> = []
    @ObservationIgnored private var repositoryMonitorUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var repositoryEventTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRepositoryImpact = RepositoryChangeImpact()
    @ObservationIgnored private var pendingRepositoryEventID: FSEventStreamEventId = 0
    @ObservationIgnored private var repositoryEventNeedsRetry = false
    private let cleanupService: GitWorktreeCleanupService
    private var cleanupTimerTask: Task<Void, Never>?
    private var cleanupRunTask: Task<Void, Never>?
    private var isTerminating = false
    private var mutationWorktreeIDs: Set<GitWorktree.ID> = [] {
        didSet {
            if mutationWorktreeIDs.isEmpty { scheduleRepositoryEventProcessing() }
        }
    }
    private var cleanupRemovalWorktreeID: GitWorktree.ID? {
        didSet {
            if cleanupRemovalWorktreeID == nil { scheduleRepositoryEventProcessing() }
        }
    }
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

    private(set) var projects: [ProjectState] {
        didSet { scheduleRepositoryMonitorUpdate() }
    }
    private(set) var projectAdditionError: String?
    private(set) var snapshotCacheError: String?
    private(set) var reviewContentCacheError: String?
    private(set) var repositoryMonitorError: String?
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
        cleanupService: GitWorktreeCleanupService = GitWorktreeCleanupService(),
        backgroundRefreshInterval: Duration = .seconds(600)
    ) {
        self.defaults = defaults
        self.backgroundRefreshInterval = backgroundRefreshInterval
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
        guard !hasLoadedProjects, isApplicationActive else {
            return
        }
        hasLoadedProjects = true
        updateRepositoryMonitor()
        agentAssociations.start()
        agentAssociations.lookUpCreators(
            worktreePaths: Set(projects.compactMap(\.snapshot).flatMap(\.worktrees).map(\.id))
        )
        if isApplicationActive {
            await normalizeStoredProjects()
            await validateSelectedSnapshotIfNeeded()
            _ = await reconcileProjectWorktreeMembership(
                projectIDs: projectIDsNeedingMembershipValidation
            )
            await refreshProjectsMissingSnapshots()
        }
        scheduleWorktreeCleanup()
        scheduleBackgroundRefresh()
        scheduleRepositoryMonitorUpdate()
        scheduleRepositoryEventProcessing()
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
            projectAdditionError = GitErrorDescription.message(for: error)
        }
    }

    func clearProjectAdditionError() {
        projectAdditionError = nil
    }

    var cacheErrorMessage: String? {
        let messages = [
            snapshotCacheError.map { "Project snapshots: \($0)" },
            reviewContentCacheError.map { "Review content: \($0)" },
            repositoryMonitorError.map { "Repository updates: \($0)" }
        ].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    func clearCacheErrors() {
        snapshotCacheError = nil
        reviewContentCacheError = nil
        if repositoryMonitorError != nil { updateRepositoryMonitor() }
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
        guard blockingGitRefreshErrors[worktreeID] != message else { return }
        blockingGitRefreshErrors[worktreeID] = message
    }

    func clearProjectError(id: GitProject.ID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            return
        }
        projects[index].errorMessage = nil
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
            let currentWorktrees = Dictionary(uniqueKeysWithValues: current.worktrees.map { ($0.id, $0.worktree) })
            if currentIDs != discoveredIDs
                || discoveredWorktrees.contains(where: { currentWorktrees[$0.id] != $0 }) {
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
                errorMessage: GitErrorDescription.message(for: error),
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
                            errorMessage: GitErrorDescription.message(for: error)
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
    }

    private func refreshProjectsMissingSnapshots() async {
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
            _ = await saveSnapshotCache()
        }
    }

    @discardableResult
    func refreshSelectedWorktree() async -> WorktreeRefreshOutcome {
        guard let selectedWorktree else {
            return .failed("The selected worktree is unavailable.")
        }
        return await refresh(
            worktree: selectedWorktree.worktree,
            submoduleScanMode: .allChanges
        )
    }

    func refreshSelectedProject() async {
        guard let projectID = projects.first(where: {
            $0.snapshot?.worktrees.contains(where: { $0.id == selectedWorktreeID }) == true
        })?.id ?? selectedWorktreeProjectID else { return }
        await refreshProject(id: projectID)
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
        return projectRefreshTasks[project.id] != nil
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
    }

    func loadDiff(
        worktree: GitWorktree,
        change: GitFileChange,
        scope: GitDiffScope,
        options: GitDiffOptions? = nil
    ) async throws -> GitFileDiff {
        let resolvedOptions = options ?? diffOptions
        let identities = (try? await repositoryService.pendingDiffIdentities(
            worktree: worktree,
            workingChanges: scope == .working ? [change] : [],
            stagedChanges: scope == .staged ? [change] : [],
            options: resolvedOptions
        )) ?? []
        try Task.checkCancellation()
        let diff = try await repositoryService.loadDiff(
            worktree: worktree,
            change: change,
            scope: scope,
            options: resolvedOptions
        )
        return diff.withSourceIdentity(identities.first)
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
        options: GitDiffOptions? = nil,
        sourceIdentities: [GitPendingDiffIdentity] = []
    ) -> AsyncThrowingStream<GitPendingDiffBatch, any Error> {
        repositoryService.loadPendingDiffBatches(
            worktree: worktree,
            workingChanges: workingChanges,
            stagedChanges: stagedChanges,
            options: options ?? diffOptions,
            sourceIdentities: sourceIdentities
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

    func applyAllChangesAction(
        _ action: GitAllChangesAction,
        worktree: GitWorktree
    ) async throws {
        try beginWorktreeMutation(worktree.id)
        defer { mutationWorktreeIDs.remove(worktree.id) }
        try await repositoryService.applyAllChangesAction(action, worktree: worktree)
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
        let identities = await pendingDiffIdentities(snapshot: snapshot, options: options)
        return await reviewContentStore.reusablePendingDiffEntry(
            for: PendingReviewContentCacheKey(
                snapshot: snapshot,
                options: options
            ), identities: identities
        )
    }

    private func pendingDiffIdentities(
        snapshot: GitWorktreeSnapshot, options: GitDiffOptions,
        changes: [GitFileChange]? = nil
    ) async -> [GitPendingDiffIdentity] {
        let changes = changes ?? snapshot.status.changes
        return (try? await repositoryService.pendingDiffIdentities(
            worktree: snapshot.worktree,
            workingChanges: changes.filter { $0.isUnstaged || $0.isUntracked },
            stagedChanges: changes.filter(\.isStaged), options: options
        )) ?? []
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
        let currentIdentities = Set(await pendingDiffIdentities(snapshot: snapshot, options: options))
        let reusable = diffs.filter { $0.sourceIdentity.map(currentIdentities.contains) == true }
        let verifiedDiffs = diffs.map { diff in
            diff.sourceIdentity.map(currentIdentities.contains) == true ? diff : diff.withSourceIdentity(nil)
        }
        await cacheReviewContent {
            let key = PendingReviewContentCacheKey(
                snapshot: snapshot,
                options: options
            )
            if isComplete {
                try await reviewContentStore.savePendingDiffs(
                    verifiedDiffs,
                    for: key
                )
            } else {
                try await reviewContentStore.savePartialPendingDiffs(
                    verifiedDiffs,
                    for: key
                )
            }
            try await reviewContentStore.saveReusablePendingDiffs(reusable)
        }
    }

    func cachePendingDiffBatch(
        _ diffs: [GitFileDiff], snapshot: GitWorktreeSnapshot, options: GitDiffOptions
    ) async {
        guard let reviewContentStore else { return }
        let changes = Array(Set(diffs.map(\.change)))
        let current = Set(await pendingDiffIdentities(snapshot: snapshot, options: options, changes: changes))
        let reusable = diffs.filter { $0.sourceIdentity.map(current.contains) == true }
        await cacheReviewContent { try await reviewContentStore.saveReusablePendingDiffs(reusable) }
    }

    func loadCachedPendingDiff(
        snapshot: GitWorktreeSnapshot,
        change: GitFileChange,
        scope: GitDiffScope,
        options: GitDiffOptions
    ) async throws -> GitFileDiff {
        let identities = (try? await repositoryService.pendingDiffIdentities(
            worktree: snapshot.worktree,
            workingChanges: scope == .working ? [change] : [],
            stagedChanges: scope == .staged ? [change] : [], options: options
        )) ?? []
        try Task.checkCancellation()
        let identity = identities.first
        if let identity, let cached = await reviewContentStore?.reusablePendingDiff(for: identity) {
            try Task.checkCancellation()
            return cached.diff.withChange(change)
        }
        let service = repositoryService
        let operation: @Sendable () async throws -> GitFileDiff = {
            let diff = try await service.loadDiff(
                worktree: snapshot.worktree, change: change, scope: scope, options: options
            ).withSourceIdentity(identity)
            try Task.checkCancellation()
            await self.cachePendingDiff(diff, snapshot: snapshot, options: options)
            try Task.checkCancellation()
            return diff
        }
        if let identity {
            return try await pendingDiffRequests.value(for: identity, operation: operation).withChange(change)
        }
        return try await operation()
    }

    func cachePendingDiff(
        _ diff: GitFileDiff,
        snapshot: GitWorktreeSnapshot,
        options: GitDiffOptions
    ) async {
        guard let reviewContentStore else {
            return
        }
        let identities = await pendingDiffIdentities(snapshot: snapshot, options: options, changes: [diff.change])
        let verified = diff.sourceIdentity.map(identities.contains) == true ? diff : diff.withSourceIdentity(nil)
        await cacheReviewContent {
            try await reviewContentStore.savePendingDiff(
                verified,
                for: PendingReviewContentCacheKey(
                    snapshot: snapshot,
                    options: options
                )
            )
            if let identity = diff.sourceIdentity, identities.contains(identity) {
                try await reviewContentStore.saveReusablePendingDiffs([diff])
            }
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
            reviewContentCacheError = GitErrorDescription.message(for: error)
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
        collapsedProjectIDs.remove(id)
        pinnedWorktreeIDs.subtract(removedWorktreeIDs)
        if let selectedWorktreeID, removedWorktreeIDs.contains(selectedWorktreeID) {
            self.selectedWorktreeID = firstAvailableWorktreeID()
        }
        persistProjects()
    }

    private func scheduleRepositoryMonitorUpdate() {
        guard hasLoadedProjects, !isTerminating else { return }
        repositoryMonitorUpdateTask?.cancel()
        repositoryMonitorUpdateTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            self?.updateRepositoryMonitor()
        }
    }

    private func updateRepositoryMonitor() {
        guard hasLoadedProjects, !isTerminating else { return }
        if repositoryMonitor == nil {
            repositoryMonitor = RepositoryFileMonitor(sinceWhen: snapshotCacheEventID) { [weak self] impact, eventID in
                // 同一事件队列按收到的顺序转到主线程，保持历史回放的游标顺序。
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.receiveRepositoryEvents(impact, eventID: eventID)
                    }
                }
            }
        }
        do {
            let index = RepositoryWatchIndex(projects: projects)
            let paths = Set(index.watchedPaths)
            let addedPaths = paths.subtracting(monitoredRepositoryPaths)
            let needsCoverage = !monitoredRepositoryPaths.isEmpty && !addedPaths.isEmpty
            try repositoryMonitor?.update(index: index, acknowledgedEventID: snapshotCacheEventID)
            monitoredRepositoryPaths = paths
            if needsCoverage {
                // 新路径在建立监听之后再读一次，覆盖加入监听前的文件与 index 变化。
                receiveRepositoryEvents(
                    RepositoryChangeImpact(metadataWorktreeIDs: index.worktreeIDs(watching: addedPaths)),
                    eventID: 0
                )
            }
            if repositoryMonitorError != nil { repositoryMonitorError = nil }
            if isApplicationActive {
                backgroundRefreshTask?.cancel()
                backgroundRefreshTask = nil
            }
        } catch {
            repositoryMonitorError = error.localizedDescription
            scheduleBackgroundRefresh()
        }
    }

    private func receiveRepositoryEvents(
        _ impact: RepositoryChangeImpact, eventID: FSEventStreamEventId
    ) {
        guard !isTerminating else { return }
        pendingRepositoryImpact.formUnion(impact)
        pendingRepositoryEventID = max(pendingRepositoryEventID, eventID)
        scheduleRepositoryEventProcessing()
    }

    private func scheduleRepositoryEventProcessing() {
        guard hasLoadedProjects, isApplicationActive, !isTerminating,
              mutationWorktreeIDs.isEmpty, cleanupRemovalWorktreeID == nil,
              repositoryEventTask == nil,
              !pendingRepositoryImpact.isEmpty || pendingRepositoryEventID > snapshotCacheEventID else { return }
        repositoryEventTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch {
                self?.repositoryEventTask = nil
                self?.scheduleRepositoryEventProcessing()
                return
            }
            guard let self else { return }
            self.repositoryEventNeedsRetry = false
            var completedEventID = self.snapshotCacheEventID
            defer {
                if completedEventID > self.snapshotCacheEventID {
                    self.pendingRepositoryEventID = max(self.pendingRepositoryEventID, completedEventID)
                }
                self.repositoryEventTask = nil
                if self.isApplicationActive, Task.isCancelled || self.repositoryEventNeedsRetry {
                    self.scheduleRepositoryEventProcessing()
                }
            }
            while self.isApplicationActive, !self.isTerminating, !Task.isCancelled,
                  !self.pendingRepositoryImpact.isEmpty || self.pendingRepositoryEventID > self.snapshotCacheEventID {
                let impact = self.pendingRepositoryImpact
                let eventID = self.pendingRepositoryEventID
                self.pendingRepositoryImpact = RepositoryChangeImpact()
                self.pendingRepositoryEventID = 0
                guard await self.refreshForRepositoryEvents(impact) else {
                    self.pendingRepositoryImpact.formUnion(impact)
                    self.pendingRepositoryEventID = max(self.pendingRepositoryEventID, eventID)
                    break
                }
                completedEventID = max(completedEventID, eventID)
                self.updateRepositoryMonitor()
                guard self.repositoryMonitorError == nil else { break }
                // 新增监听范围的补读和已到达的事件一起完成后，再确认全局游标。
                if self.pendingRepositoryImpact.isEmpty,
                   self.pendingRepositoryEventID <= completedEventID {
                    self.snapshotCacheEventID = max(self.snapshotCacheEventID, completedEventID)
                    self.pendingRepositoryEventID = 0
                    self.scheduleSnapshotCacheSave()
                }
            }
        }
    }

    private func refreshForRepositoryEvents(_ impact: RepositoryChangeImpact) async -> Bool {
        guard isApplicationActive, !isTerminating, !Task.isCancelled,
              mutationWorktreeIDs.isDisjoint(with: impact.worktreeIDs),
              cleanupRemovalWorktreeID.map({ !impact.worktreeIDs.contains($0) }) ?? true else { return false }
        let affectedProjects = projects.filter { state in
            impact.projectIDs.contains(state.id)
                || state.snapshot?.worktrees.contains { impact.worktreeIDs.contains($0.id) } == true
        }
        for project in affectedProjects {
            if let refresh = projectRefreshTasks[project.id] { _ = await refresh.task.value }
        }
        for id in impact.worktreeIDs {
            if let refresh = worktreeRefreshTasks[id] { _ = await refresh.task.value }
        }
        guard isApplicationActive, !Task.isCancelled else { return false }
        if !impact.projectIDs.isEmpty {
            _ = await reconcileProjectWorktreeMembership(projectIDs: impact.projectIDs)
            guard isApplicationActive, !Task.isCancelled,
                  projects.filter({ impact.projectIDs.contains($0.id) }).allSatisfy({ $0.errorMessage == nil }) else {
                return false
            }
        }
        // 选中的工作区先更新，其余逐个读取，避免一次文件事件启动大量 Git 进程。
        let ids = impact.worktreeIDs.sorted {
            if ($0 == selectedWorktreeID) != ($1 == selectedWorktreeID) { return $0 == selectedWorktreeID }
            return $0 < $1
        }
        for id in ids {
            guard isApplicationActive, !Task.isCancelled,
                  !mutationWorktreeIDs.contains(id) else { return false }
            guard let worktree = projects.lazy.compactMap(\.snapshot).flatMap(\.worktrees)
                .first(where: { $0.id == id })?.worktree else { continue }
            if !impact.metadataWorktreeIDs.contains(id),
               let paths = impact.contentPathsByWorktreeID[id],
               !paths.contains(where: { [".gitignore", ".gitattributes"].contains(URL(fileURLWithPath: $0).lastPathComponent) }) {
                do {
                    let isRelevant = try await repositoryService.containsGitRelevantWorkingTreeEvent(
                        worktree: worktree, absolutePaths: paths.sorted()
                    )
                    if !isRelevant { continue }
                } catch is CancellationError { return false } catch {
                    // ignore 查询失败时直接读取状态，避免漏掉真实变更。
                }
            }
            guard isApplicationActive, !Task.isCancelled,
                  !mutationWorktreeIDs.contains(id), cleanupRemovalWorktreeID != id else {
                repositoryEventNeedsRetry = true
                return false
            }
            switch await refreshWorktree(id: id) {
            case .updated:
                // 缓存会保留出错前的快照，有补充信息读取失败时不能推进持久化游标。
                guard projects.lazy.compactMap(\.snapshot).flatMap(\.worktrees)
                    .first(where: { $0.id == id })?.errorMessage == nil else { return false }
            case .superseded:
                repositoryEventNeedsRetry = true
                return false
            case .failed: return false
            }
        }
        return isApplicationActive && !Task.isCancelled
    }

    func setApplicationActive(_ isActive: Bool) {
        guard isApplicationActive != isActive else {
            return
        }
        isApplicationActive = isActive
        agentAssociations.setApplicationActive(isActive)
        if isActive {
            backgroundRefreshTask?.cancel()
            backgroundRefreshTask = nil
            if !hasLoadedProjects {
                Task { await loadProjectsIfNeeded() }
            }
            updateRepositoryMonitor()
            scheduleRepositoryEventProcessing()
            scheduleBackgroundRefresh()
            return
        }

        repositoryEventTask?.cancel()
        reviewStates.flush()
        snapshotCacheSaveTask?.cancel()
        snapshotCacheSaveTask = Task { [weak self] in
            await self?.saveSnapshotCache()
        }
        for refresh in projectRefreshTasks.values {
            refresh.task.cancel()
        }
        for refresh in worktreeRefreshTasks.values {
            refresh.task.cancel()
        }
        scheduleBackgroundRefresh()
    }

    private func scheduleBackgroundRefresh() {
        guard (!isApplicationActive || repositoryMonitorError != nil), !isTerminating,
              backgroundRefreshTask == nil else { return }
        let interval = backgroundRefreshInterval
        backgroundRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self, (!self.isApplicationActive || self.repositoryMonitorError != nil), !self.isTerminating else {
                    return
                }
                await self.normalizeStoredProjects()
                guard !Task.isCancelled, (!self.isApplicationActive || self.repositoryMonitorError != nil) else { return }
                await self.refreshAll()
            }
        }
    }

    func prepareForTermination() async {
        isTerminating = true
        repositoryMonitorUpdateTask?.cancel()
        repositoryMonitorUpdateTask = nil
        repositoryEventTask?.cancel()
        for refresh in projectRefreshTasks.values { refresh.task.cancel() }
        for refresh in worktreeRefreshTasks.values { refresh.task.cancel() }
        await repositoryEventTask?.value
        repositoryEventTask = nil
        repositoryMonitor?.stop()
        repositoryMonitor = nil
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = nil
        cleanupTimerTask?.cancel()
        cleanupTimerTask = nil
        // 等待已开始的 git worktree remove 完成，避免退出进程打断删除。
        await cleanupRunTask?.value
        isApplicationActive = false
        agentAssociations.setApplicationActive(false)
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
        AgentGitDiagnostics.shared.record("app.terminate")
        await AgentGitDiagnostics.shared.flush()
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
        await AgentGitDiagnostics.$operationID.withValue(UUID().uuidString) {
            await performWorktreeCleanup(now: now, immediately: immediately, settings: settings)
        }
    }

    private func performWorktreeCleanup(
        now: Date, immediately: Bool, settings: WorktreeCleanupSettings
    ) async {
        isCleaningWorktrees = true
        defer {
            isCleaningWorktrees = false
            cleanupRemovalWorktreeID = nil
        }
        var report = WorktreeCleanupReport(checkedAt: now)
        report.runID = AgentGitDiagnostics.operationID
        let startedAt = ProcessInfo.processInfo.systemUptime
        let cutoff = now.addingTimeInterval(-settings.inactivity)
        AgentGitDiagnostics.shared.record("cleanup.start", fields: [
            "trigger": immediately ? "manual" : "automatic", "inactiveDays": String(settings.inactiveDays),
            "intervalHours": String(settings.intervalHours), "cutoff": cutoff.ISO8601Format(),
            "projectCount": String(projects.count), "selectedWorktree": selectedWorktreeID ?? "",
            "pinnedWorktrees": pinnedWorktreeIDs.sorted().joined(separator: "\n"),
            "excludedProjects": cleanupExcludedProjectIDs.sorted().joined(separator: "\n")
        ])
        for project in projects.map(\.project) {
            guard !isTerminating, cleanupSettings == settings else {
                AgentGitDiagnostics.shared.record("cleanup.interrupted", fields: [
                    "reason": isTerminating ? "Application is terminating" : "Cleanup settings changed"
                ])
                break
            }
            guard !isProjectExcludedFromCleanup(id: project.id) else {
                AgentGitDiagnostics.shared.record("cleanup.project.skipped", fields: [
                    "project": project.rootURL.path, "reason": "Project is excluded"
                ])
                continue
            }
            do {
                // 后台也直接读取 Git 成员与状态，不依赖界面缓存。
                let worktrees = try await repositoryService.listWorktrees(at: project.rootURL)
                AgentGitDiagnostics.shared.record("cleanup.project.members", fields: [
                    "project": project.rootURL.path, "count": String(worktrees.count)
                ])
                for worktree in worktrees {
                    guard !isTerminating, cleanupSettings == settings else {
                        AgentGitDiagnostics.shared.record("cleanup.interrupted", fields: [
                            "project": project.rootURL.path,
                            "reason": isTerminating ? "Application is terminating" : "Cleanup settings changed"
                        ])
                        break
                    }
                    if worktree.id == project.id || worktree.id == worktrees.first?.id {
                        AgentGitDiagnostics.shared.record("cleanup.worktree.skipped", fields: [
                            "project": project.rootURL.path, "worktree": worktree.rootURL.path,
                            "reason": "Main checkout"
                        ])
                        continue
                    }
                    do {
                        if let reason = worktreeCleanupProtectionReason(worktree, project: project) {
                            report.recordSkipped(path: worktree.id, reason: reason)
                            AgentGitDiagnostics.shared.record("cleanup.worktree.skipped", fields: [
                                "project": project.rootURL.path, "worktree": worktree.rootURL.path,
                                "reason": reason
                            ])
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
                        case let .skipped(reason):
                            report.recordSkipped(path: worktree.id, reason: reason)
                        }
                    } catch {
                        cleanupRemovalWorktreeID = nil
                        report.errors.append("\(worktree.rootURL.path): \(error)")
                        AgentGitDiagnostics.shared.record("cleanup.worktree.error", level: "error", fields: [
                            "project": project.rootURL.path, "worktree": worktree.rootURL.path,
                            "error": String(describing: error)
                        ])
                    }
                }
            } catch {
                report.errors.append("\(project.rootURL.path): \(error)")
                AgentGitDiagnostics.shared.record("cleanup.project.error", level: "error", fields: [
                    "project": project.rootURL.path, "error": String(describing: error)
                ])
            }
        }
        // 创建者记录没有删除 hook，随定期清理删掉已删除或重建过的 worktree 的记录。
        await agentAssociations.removeStaleCreators()
        report.durationSeconds = ProcessInfo.processInfo.systemUptime - startedAt
        AgentGitDiagnostics.shared.record("cleanup.finish", fields: [
            "removed": String(report.removedPaths.count), "kept": String(report.skippedCount),
            "errors": String(report.errors.count),
            "durationSeconds": String(report.durationSeconds ?? 0)
        ])
        cleanupReport = report
        if let data = try? JSONEncoder().encode(report) {
            defaults.set(data, forKey: Self.cleanupReportKey)
        }
        if !report.removedPaths.isEmpty {
            _ = await saveSnapshotCache()
        }
    }

    private func canCleanWorktree(
        _ worktree: GitWorktree, project: GitProject
    ) -> Bool {
        worktreeCleanupProtectionReason(worktree, project: project) == nil
    }

    private func worktreeCleanupProtectionReason(
        _ worktree: GitWorktree, project: GitProject
    ) -> String? {
        if !projects.contains(where: { $0.id == project.id }) { return "Project is no longer open" }
        if isProjectExcludedFromCleanup(id: project.id) { return "Project is excluded" }
        if worktree.id == selectedWorktreeID { return "Currently selected worktree" }
        if pinnedWorktreeIDs.contains(worktree.id) { return "Pinned worktree" }
        if mutationWorktreeIDs.contains(worktree.id) { return "Git operation in progress" }
        if let error = blockingGitRefreshErrors[worktree.id] {
            return "Git state could not be refreshed: \(error)"
        }
        return nil
    }

    private func forgetRemovedWorktree(_ id: GitWorktree.ID, projectID: GitProject.ID) {
        // 使正在运行的刷新失效，防止旧结果重新添加已经删除的行。
        projectRefreshTasks[projectID]?.task.cancel()
        projectRefreshTasks[projectID] = nil
        worktreeRefreshTasks[id]?.task.cancel()
        worktreeRefreshTasks[id] = nil
        refreshCoordinator.removeProject(projectID, worktreeIDs: [id])
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

        let nextSnapshot: GitProjectSnapshot?
        if let snapshot {
            nextSnapshot = mergedProjectSnapshot(
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
                if blockingGitRefreshErrors[worktree.id] != nil {
                    blockingGitRefreshErrors[worktree.id] = nil
                }
            }
        } else if let baselineSnapshot {
            nextSnapshot = mergedProjectSnapshot(
                baselineSnapshot,
                preservingNewerWorktreesFrom: projects[index].snapshot,
                token: token
            )
        } else {
            nextSnapshot = nil
        }
        if projects[index].snapshot != nextSnapshot {
            projects[index].snapshot = nextSnapshot
            scheduleSnapshotCacheSave()
        }
        if projects[index].errorMessage != errorMessage {
            projects[index].errorMessage = errorMessage
        }
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
        if incoming.project == current.project, worktrees == current.worktrees {
            return current
        }
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
                    errorMessage: GitErrorDescription.message(for: error)
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
                    errorMessage: GitErrorDescription.message(for: error)
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
        guard current.project != project || current.worktrees != retained else { return }
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
        let current = projects[index].snapshot
        if current?.project != project || current?.worktrees != worktrees {
            projects[index].snapshot = GitProjectSnapshot(
                project: project,
                worktrees: worktrees,
                refreshedAt: Date()
            )
            scheduleSnapshotCacheSave()
        }
        if projects[index].errorMessage != nil { projects[index].errorMessage = nil }
        if worktree.hasUsableState, blockingGitRefreshErrors[worktree.id] != nil {
            if blockingGitRefreshErrors[worktree.id] != nil {
                blockingGitRefreshErrors[worktree.id] = nil
            }
        }
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
        // 每次 worktree 列表刷新后，给还没有创建者记录的 worktree 补查一次。
        if let worktrees = projects.first(where: { $0.id == request.token.projectID })?.snapshot?.worktrees {
            agentAssociations.lookUpCreators(worktreePaths: Set(worktrees.map(\.id)))
        }
    }

    private func beginProjectRefresh(_ id: GitProject.ID) -> RepositoryRefreshToken {
        completeProjectSnapshotIDs.remove(id)
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
        scheduleRepositoryEventProcessing()
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
    private func saveSnapshotCache() async -> Bool {
        guard let snapshotStore else {
            return true
        }
        let targetEventID = snapshotCacheEventID
        let projectIDs = projects.map(\.id)
        let snapshots = projects.compactMap(\.snapshot)
        do {
            try await snapshotStore.save(
                projectIDs: projectIDs,
                snapshots: snapshots,
                eventID: targetEventID,
                completeProjectIDs: completeProjectSnapshotIDs
            )
            snapshotCacheError = nil
            return true
        } catch {
            snapshotCacheError = GitErrorDescription.message(for: error)
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
        if worktrees != currentSnapshot.worktrees {
            projects[currentProjectIndex].snapshot = GitProjectSnapshot(
                project: currentSnapshot.project,
                worktrees: worktrees,
                refreshedAt: Date()
            )
            scheduleSnapshotCacheSave()
        }
        if projects[currentProjectIndex].errorMessage != nil {
            projects[currentProjectIndex].errorMessage = nil
        }
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

func worktreeSnapshotByApplyingRefresh(
    _ incoming: GitWorktreeSnapshot,
    preserving current: GitWorktreeSnapshot?
) -> GitWorktreeSnapshot {
    if let current,
       let revision = incoming.pendingDiffRevision,
       revision == current.pendingDiffRevision,
       incoming.worktree == current.worktree,
       incoming.status == current.status,
       incoming.diffStat == current.diffStat,
       incoming.lastActivityAt == current.lastActivityAt,
       incoming.errorMessage == current.errorMessage,
       incoming.hasUsableState == current.hasUsableState,
       incoming.eventWatchURLs == current.eventWatchURLs {
        return current
    }
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
        eventWatchURLs: eventWatchURLs,
        pendingDiffRevision: current.pendingDiffRevision
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
        eventWatchURLs: current.eventWatchURLs,
        pendingDiffRevision: discovered.headOID == current.worktree.headOID
            ? current.pendingDiffRevision : nil
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
