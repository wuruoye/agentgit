import Foundation

public struct GitWorktreeSnapshot: Identifiable, Hashable, Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case worktree
        case status
        case diffStat
        case lastActivityAt
        case refreshedAt
        case errorMessage
        case hasUsableState
        case eventWatchURLs
    }

    public let worktree: GitWorktree
    public let status: GitStatusSnapshot
    public let diffStat: GitDiffStat
    public let lastActivityAt: Date
    public let refreshedAt: Date?
    public let errorMessage: String?
    public let hasUsableState: Bool
    public let eventWatchURLs: [URL]

    public init(
        worktree: GitWorktree,
        status: GitStatusSnapshot,
        diffStat: GitDiffStat,
        lastActivityAt: Date,
        refreshedAt: Date? = nil,
        errorMessage: String?,
        hasUsableState: Bool = true,
        eventWatchURLs: [URL] = []
    ) {
        self.worktree = worktree
        self.status = status
        self.diffStat = diffStat
        self.lastActivityAt = lastActivityAt
        self.refreshedAt = refreshedAt
        self.errorMessage = errorMessage
        self.hasUsableState = hasUsableState
        self.eventWatchURLs = eventWatchURLs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let worktree = try container.decode(GitWorktree.self, forKey: .worktree)
        self.init(
            worktree: worktree,
            status: try container.decode(GitStatusSnapshot.self, forKey: .status),
            diffStat: try container.decodeIfPresent(
                GitDiffStat.self,
                forKey: .diffStat
            ) ?? .zero,
            lastActivityAt: try container.decodeIfPresent(
                Date.self,
                forKey: .lastActivityAt
            ) ?? .distantPast,
            refreshedAt: try container.decodeIfPresent(
                Date.self,
                forKey: .refreshedAt
            ),
            errorMessage: try container.decodeIfPresent(
                String.self,
                forKey: .errorMessage
            ),
            hasUsableState: try container.decodeIfPresent(
                Bool.self,
                forKey: .hasUsableState
            ) ?? true,
            eventWatchURLs: try container.decodeIfPresent(
                [URL].self,
                forKey: .eventWatchURLs
            ) ?? [worktree.rootURL]
        )
    }

    public var id: GitWorktree.ID {
        worktree.id
    }
}

public struct GitProjectSnapshot: Identifiable, Hashable, Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case project
        case worktrees
        case refreshedAt
    }

    public let project: GitProject
    public let worktrees: [GitWorktreeSnapshot]
    public let refreshedAt: Date

    public init(project: GitProject, worktrees: [GitWorktreeSnapshot], refreshedAt: Date) {
        self.project = project
        self.worktrees = worktrees
        self.refreshedAt = refreshedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let worktrees = try container.decode(
            [GitWorktreeSnapshot].self,
            forKey: .worktrees
        )
        let inferredRefreshDate = worktrees.compactMap(\.refreshedAt).max()
            ?? worktrees.map(\.lastActivityAt).max()
            ?? .distantPast
        self.init(
            project: try container.decode(GitProject.self, forKey: .project),
            worktrees: worktrees,
            refreshedAt: try container.decodeIfPresent(
                Date.self,
                forKey: .refreshedAt
            ) ?? inferredRefreshDate
        )
    }

    public var id: GitProject.ID {
        project.id
    }
}

public enum GitProjectRefreshEvent: Sendable {
    case discovered(project: GitProject, worktrees: [GitWorktree])
    case worktree(GitWorktreeSnapshot)
}

public struct GitPendingDiffBatch: Sendable {
    public let scope: GitDiffScope
    public let diffs: [GitFileDiff]

    public init(scope: GitDiffScope, diffs: [GitFileDiff]) {
        self.scope = scope
        self.diffs = diffs
    }
}

public enum GitPendingSelectionAction: Hashable, Sendable {
    case stage
    case unstage
    case discard
}

public enum GitRemoteAction: Hashable, Sendable {
    case pull
    case push
}

public enum GitSubmoduleScanMode: Hashable, Sendable {
    case commitsOnly
    case allChanges
}

public enum GitMutationError: Error, Equatable, Sendable {
    case invalidScope
    case pathOutsideWorktree
}

public enum GitHistoryLoadError: LocalizedError, Equatable, Sendable {
    case invalidOffset(Int)
    case invalidPageSize(Int)
    case invalidLineRange(start: Int, end: Int)
    case emptyPath

    public var errorDescription: String? {
        switch self {
        case let .invalidOffset(offset):
            "History offset must be zero or greater; received \(offset)."
        case let .invalidPageSize(pageSize):
            "History page size must be greater than zero; received \(pageSize)."
        case let .invalidLineRange(start, end):
            "Line history requires a positive range; received \(start)...\(end)."
        case .emptyPath:
            "Line history requires a repository-relative file path."
        }
    }
}

public enum GitRemoteActionError: LocalizedError, Equatable, Sendable {
    case noRemote
    case ambiguousRemotes([String])
    case unavailableBranch

    public var errorDescription: String? {
        switch self {
        case .noRemote:
            "Add a Git remote before publishing this branch."
        case let .ambiguousRemotes(remotes):
            "Choose an upstream before publishing; available remotes: "
                + remotes.joined(separator: ", ")
                + "."
        case .unavailableBranch:
            "A checked-out local branch is required for publishing."
        }
    }
}

private struct GitBranchStatusCacheKey: Hashable, Sendable {
    let worktreePath: String
    let headOID: String
    let upstreamOID: String
    let upstreamRef: String
}

private actor GitBranchStatusCache {
    private static let maximumEntryCount = 512
    private var values: [GitBranchStatusCacheKey: GitBranchStatus] = [:]

    func value(for key: GitBranchStatusCacheKey) -> GitBranchStatus? {
        values[key]
    }

    func insert(_ value: GitBranchStatus, for key: GitBranchStatusCacheKey) {
        if values.count >= Self.maximumEntryCount, values[key] == nil {
            values.removeAll(keepingCapacity: true)
        }
        values[key] = value
    }
}

private struct GitFileSystemFingerprint: Hashable, Sendable {
    let path: String
    let modificationDate: Date?
    let fileSize: UInt64?
    let fileNumber: UInt64?
}

private struct GitDiffStatCacheKey: Hashable, Sendable {
    let worktreePath: String
    let headOID: String?
    let status: GitStatusSnapshot
    let gitMetadata: [GitFileSystemFingerprint]
    let changedFiles: [GitFileSystemFingerprint]
}

private actor GitDiffStatCache {
    private struct Entry {
        let value: GitDiffStat
        let storedAt: Date
    }

    private static let maximumEntryCount = 512
    private static let maximumAge: TimeInterval = 60
    private var values: [GitDiffStatCacheKey: Entry] = [:]

    func value(for key: GitDiffStatCacheKey, now: Date = Date()) -> GitDiffStat? {
        guard let entry = values[key],
              now.timeIntervalSince(entry.storedAt) <= Self.maximumAge else {
            values[key] = nil
            return nil
        }
        return entry.value
    }

    func insert(_ value: GitDiffStat, for key: GitDiffStatCacheKey) {
        if values.count >= Self.maximumEntryCount, values[key] == nil {
            values.removeAll(keepingCapacity: true)
        }
        values[key] = Entry(value: value, storedAt: Date())
    }
}

private enum GitBranchStatusLoadError: Error, CustomStringConvertible, Sendable {
    case malformedReferenceOutput
    case upstreamUnavailable(String)

    var description: String {
        switch self {
        case .malformedReferenceOutput:
            "Git returned an invalid upstream reference."
        case let .upstreamUnavailable(upstreamRef):
            "Upstream \(upstreamRef) is unavailable."
        }
    }
}

private enum GitSupplementalLoadResult<Value: Sendable>: Sendable {
    case success(Value)
    case failure(String)
}

public struct GitRepositoryService: Sendable {
    /// oid, short oid, author, author date, parents, refs, subject —— 与 GitLogParser 对应。
    private static let historyFormat = "%x00%H%x1f%h%x1f%an%x1f%aI%x1f%P%x1f%D%x1f%s"
    private static let diffBatchSize = 24
    private static let maximumPatchOutputBytes = 8 * 1_024 * 1_024
    private static let maximumHistoryOutputBytes = 8 * 1_024 * 1_024
    private static let maximumCommitMessageBytes = 2 * 1_024 * 1_024
    private static let maximumChangedPathsOutputBytes = 8 * 1_024 * 1_024
    private static let maximumRemoteErrorBytes = 2 * 1_024 * 1_024
    private static let maximumDiffStatPathCount = 2_048
    private static let maximumDiffStatPathBytes = 128 * 1_024
    private static let quickMetadataTimeout: Duration = .seconds(15)
    private static let repositoryScanTimeout: Duration = .seconds(30)
    private static let remoteOperationTimeout: Duration = .seconds(300)

    private let runner: GitCommandRunner
    private let branchStatusCache: GitBranchStatusCache
    private let diffStatCache: GitDiffStatCache
    private let discardRecoveryStore: GitDiscardRecoveryStore

    public init(
        runner: GitCommandRunner = GitCommandRunner(),
        discardRecoveryStore: GitDiscardRecoveryStore = .systemTrash
    ) {
        self.runner = runner
        self.branchStatusCache = GitBranchStatusCache()
        self.diffStatCache = GitDiffStatCache()
        self.discardRecoveryStore = discardRecoveryStore
    }

    public func listWorktrees(at rootURL: URL) async throws -> [GitWorktree] {
        let standardizedRootURL = rootURL.standardizedFileURL
        let worktreeData = try await runner.run(
            arguments: ["worktree", "list", "--porcelain", "-z"],
            workingDirectory: standardizedRootURL,
            timeout: Self.quickMetadataTimeout
        )
        return try WorktreeListParser.parse(worktreeData)
            .filter { !$0.isBare }
    }

    public func resolveProject(at rootURL: URL) async throws -> GitProject {
        let standardizedRootURL = rootURL.standardizedFileURL
        let worktrees = try await listWorktrees(at: standardizedRootURL)
        guard let primaryWorktree = worktrees.first else {
            throw GitProjectResolutionError.noNonBareWorktree
        }
        return GitProject(rootURL: primaryWorktree.rootURL)
    }

    public func projectRefreshEvents(
        at rootURL: URL,
        prioritizedWorktreeID: GitWorktree.ID? = nil,
        prioritizedSubmoduleScanMode: GitSubmoduleScanMode = .commitsOnly,
        maximumConcurrentWorktrees: Int = 3
    ) -> AsyncThrowingStream<GitProjectRefreshEvent, any Error> {
        let service = self
        let standardizedRootURL = rootURL.standardizedFileURL
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let project = GitProject(rootURL: standardizedRootURL)
                    var worktrees = try await service.listWorktrees(at: project.rootURL)
                    let preferredID = prioritizedWorktreeID ?? project.rootURL.path
                    if let preferredIndex = worktrees.firstIndex(where: {
                        $0.id == preferredID
                    }), preferredIndex != worktrees.startIndex {
                        let preferred = worktrees.remove(at: preferredIndex)
                        worktrees.insert(preferred, at: worktrees.startIndex)
                    }
                    continuation.yield(
                        .discovered(project: project, worktrees: worktrees)
                    )

                    if worktrees.first?.id == preferredID,
                       let preferred = worktrees.first {
                        let initialSubmoduleScanMode: GitSubmoduleScanMode =
                            prioritizedSubmoduleScanMode == .allChanges
                                ? .commitsOnly
                                : prioritizedSubmoduleScanMode
                        let snapshot = await service.loadWorktree(
                            preferred,
                            submoduleScanMode: initialSubmoduleScanMode
                        )
                        try Task.checkCancellation()
                        continuation.yield(.worktree(snapshot))
                        if prioritizedSubmoduleScanMode == .allChanges {
                            let completeSnapshot = await service.loadWorktree(
                                preferred,
                                submoduleScanMode: .allChanges
                            )
                            try Task.checkCancellation()
                            continuation.yield(.worktree(completeSnapshot))
                        }
                        worktrees.removeFirst()
                    }

                    let concurrency = min(
                        max(1, maximumConcurrentWorktrees),
                        worktrees.count
                    )
                    await withTaskGroup(of: GitWorktreeSnapshot.self) { group in
                        for worktree in worktrees.prefix(concurrency) {
                            group.addTask {
                                await service.loadWorktree(worktree)
                            }
                        }
                        var nextIndex = concurrency
                        while let snapshot = await group.next() {
                            guard !Task.isCancelled else {
                                group.cancelAll()
                                return
                            }
                            continuation.yield(.worktree(snapshot))
                            if nextIndex < worktrees.count {
                                let worktree = worktrees[nextIndex]
                                nextIndex += 1
                                group.addTask {
                                    await service.loadWorktree(worktree)
                                }
                            }
                        }
                    }
                    try Task.checkCancellation()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    public func loadProject(at rootURL: URL) async throws -> GitProjectSnapshot {
        let project = GitProject(rootURL: rootURL)
        let worktrees = try await listWorktrees(at: project.rootURL)

        let snapshots = await withTaskGroup(of: GitWorktreeSnapshot.self) { group in
            for worktree in worktrees {
                group.addTask {
                    await loadWorktree(worktree)
                }
            }

            var values: [GitWorktreeSnapshot] = []
            for await snapshot in group {
                values.append(snapshot)
            }
            return values
        }

        return GitProjectSnapshot(
            project: project,
            worktrees: snapshots.sorted {
                if $0.lastActivityAt == $1.lastActivityAt {
                    return $0.worktree.displayName.localizedStandardCompare(
                        $1.worktree.displayName
                    ) == .orderedAscending
                }
                return $0.lastActivityAt > $1.lastActivityAt
            },
            refreshedAt: Date()
        )
    }

    /// 使用 Git 自身的 ignore 规则过滤工作区文件事件；tracked 文件始终保留。
    public func containsGitRelevantWorkingTreeEvent(
        worktree: GitWorktree,
        absolutePaths: [String]
    ) async throws -> Bool {
        let rootPath = worktree.rootURL.standardizedFileURL.path
        let rootPrefix = rootPath + "/"
        var relativePaths: Set<String> = []
        for absolutePath in absolutePaths {
            let path = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
            guard path != rootPath else {
                return true
            }
            guard path.hasPrefix(rootPrefix) else {
                return true
            }
            let relativePath = String(path.dropFirst(rootPrefix.count))
            guard relativePath != ".git",
                  !relativePath.hasPrefix(".git/") else {
                return true
            }
            relativePaths.insert(relativePath)
        }
        guard !relativePaths.isEmpty else {
            return false
        }

        let sortedPaths = relativePaths.sorted()
        let batchSize = 512
        var startIndex = 0
        while startIndex < sortedPaths.count {
            let endIndex = min(startIndex + batchSize, sortedPaths.count)
            let batch = Array(sortedPaths[startIndex..<endIndex])
            var standardInput = Data()
            for path in batch {
                standardInput.append(contentsOf: path.utf8)
                standardInput.append(0)
            }
            let output: Data
            do {
                output = try await runner.run(
                    arguments: ["check-ignore", "--stdin", "-z"],
                    workingDirectory: worktree.rootURL,
                    standardInput: standardInput,
                    maximumOutputBytes: standardInput.count,
                    timeout: Self.quickMetadataTimeout
                )
            } catch let error as GitCommandFailure where error.exitCode == 1 {
                return true
            }
            let ignoredPaths = Set(
                output.split(separator: 0).map {
                    String(decoding: $0, as: UTF8.self)
                }
            )
            if batch.contains(where: { !ignoredPaths.contains($0) }) {
                return true
            }
            startIndex = endIndex
        }
        return false
    }

    public func loadDiff(
        worktree: GitWorktree,
        change: GitFileChange,
        scope: GitDiffScope,
        options: GitDiffOptions = GitDiffOptions()
    ) async throws -> GitFileDiff {
        if change.isUntracked {
            guard scope == .working else {
                return GitFileDiff(
                    change: change,
                    scope: scope,
                    hunks: [],
                    state: .unavailable("Untracked files are not staged")
                )
            }
            let fileURL = worktree.rootURL.appendingPathComponent(change.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                let destination = try FileManager.default.destinationOfSymbolicLink(
                    atPath: fileURL.path
                )
                return UnifiedDiffParser.addedFile(
                    data: Data(destination.utf8),
                    change: change
                )
            }
            // `git ls-files --others` 不会走进嵌套仓库（submodule / linked worktree），
            // 只吐出它的目录路径本身。这里没有本仓库能读的文件内容，读了会拿到
            // POSIX 21 "Is a directory"，把整个 Review 面板变成一段 NSError。
            if attributes[.type] as? FileAttributeType == .typeDirectory {
                return GitFileDiff(
                    change: change,
                    scope: scope,
                    hunks: [],
                    state: .unavailable("Nested Git repository")
                )
            }
            if GitImageDiff.supports(path: change.path) {
                return GitFileDiff(
                    change: change,
                    scope: scope,
                    hunks: [],
                    state: .binary
                )
            }
            let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard byteCount <= 4 * 1_024 * 1_024 else {
                return GitFileDiff(
                    change: change,
                    scope: scope,
                    hunks: [],
                    state: .tooLarge(lineCount: UnifiedDiffParser.maximumRenderedLines + 1),
                    addedLineCount: 0,
                    deletedLineCount: 0
                )
            }
            return UnifiedDiffParser.addedFile(
                data: try Data(contentsOf: fileURL),
                change: change
            )
        }

        var arguments = [
            "-c", "core.quotePath=false",
            "diff"
        ]
        if scope == .staged {
            arguments.append("--cached")
        } else if change.kind == .unmerged {
            arguments.append("--ours")
        }
        arguments.append(contentsOf: ["--no-ext-diff", "--no-color"])
        arguments.append(contentsOf: options.arguments)
        arguments.append(contentsOf: ["--", change.path])
        if let originalPath = change.originalPath {
            arguments.append(originalPath)
        }
        do {
            let data = try await runner.run(
                arguments: arguments,
                workingDirectory: worktree.rootURL,
                maximumOutputBytes: Self.maximumPatchOutputBytes,
                timeout: Self.repositoryScanTimeout
            )
            let diff = try UnifiedDiffParser.parseBounded(
                data,
                change: change,
                scope: scope
            )
            guard case .tooLarge = diff.state else {
                return diff
            }
            let reportedLineCount: Int? = if case let .tooLarge(lineCount) = diff.state {
                lineCount
            } else {
                nil
            }
            return try await oversizedDiff(
                worktree: worktree,
                change: change,
                scope: scope,
                statArguments: pendingStatArguments(
                    scope: scope,
                    change: change,
                    options: options
                ),
                reportedLineCount: reportedLineCount
            )
        } catch is GitCommandOutputLimitError {
            return try await oversizedDiff(
                worktree: worktree,
                change: change,
                scope: scope,
                statArguments: pendingStatArguments(
                    scope: scope,
                    change: change,
                    options: options
                ),
                reportedLineCount: nil
            )
        } catch let error as UnifiedDiffParseError {
            return try await unavailableDiff(
                worktree: worktree,
                change: change,
                scope: scope,
                statArguments: pendingStatArguments(
                    scope: scope,
                    change: change,
                    options: options
                ),
                reason: unavailableDiffReason(for: error)
            )
        }
    }

    public func loadDiffs(
        worktree: GitWorktree,
        changes: [GitFileChange],
        scope: GitDiffScope,
        options: GitDiffOptions = GitDiffOptions()
    ) async throws -> [GitFileDiff] {
        let uniqueChanges = Self.uniqueChanges(changes)
        var diffs: [GitFileDiff] = []
        for try await batch in loadDiffBatches(
            worktree: worktree,
            changes: uniqueChanges,
            scope: scope,
            options: options
        ) {
            diffs.append(contentsOf: batch)
        }
        let diffsByChangeID = Dictionary(
            diffs.map { ($0.change.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return uniqueChanges.compactMap { diffsByChangeID[$0.id] }
    }

    public func loadDiffBatches(
        worktree: GitWorktree,
        changes: [GitFileChange],
        scope: GitDiffScope,
        options: GitDiffOptions = GitDiffOptions()
    ) -> AsyncThrowingStream<[GitFileDiff], any Error> {
        let changes = Self.uniqueChanges(changes)
        var patchArguments = ["-c", "core.quotePath=false", "diff"]
        var statArguments = ["diff"]
        if scope == .staged {
            patchArguments.append("--cached")
            statArguments.append("--cached")
        }
        patchArguments.append(contentsOf: ["--no-ext-diff", "--no-color"])
        patchArguments.append(contentsOf: options.arguments)
        patchArguments.append("--find-renames")
        statArguments.append(contentsOf: ["--numstat", "--find-renames"])
        statArguments.append(contentsOf: statOptionArguments(options))

        let batchChanges = changes.filter {
            !$0.isUntracked
                && !(scope == .working && $0.kind == .unmerged)
                && diffHeaderPathsAreBatchSafe($0)
        }
        let batchChangeIDs = Set(batchChanges.map(\.id))
        let individualChanges = changes.filter { !batchChangeIDs.contains($0.id) }
        return makeDiffBatches(
            worktree: worktree,
            changes: batchChanges,
            individualChanges: individualChanges,
            scope: scope,
            patchArguments: patchArguments,
            statArguments: statArguments,
            individualDiffLoader: { change in
                try await self.loadDiff(
                    worktree: worktree,
                    change: change,
                    scope: scope,
                    options: options
                )
            }
        )
    }

    public func loadPendingDiffBatches(
        worktree: GitWorktree,
        workingChanges: [GitFileChange],
        stagedChanges: [GitFileChange],
        options: GitDiffOptions = GitDiffOptions()
    ) -> AsyncThrowingStream<GitPendingDiffBatch, any Error> {
        let workingStream = loadDiffBatches(
            worktree: worktree,
            changes: workingChanges,
            scope: .working,
            options: options
        )
        let stagedStream = loadDiffBatches(
            worktree: worktree,
            changes: stagedChanges,
            scope: .staged,
            options: options
        )
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        if !workingChanges.isEmpty {
                            group.addTask {
                                for try await diffs in workingStream {
                                    try Task.checkCancellation()
                                    continuation.yield(
                                        GitPendingDiffBatch(scope: .working, diffs: diffs)
                                    )
                                }
                            }
                        }
                        if !stagedChanges.isEmpty {
                            group.addTask {
                                for try await diffs in stagedStream {
                                    try Task.checkCancellation()
                                    continuation.yield(
                                        GitPendingDiffBatch(scope: .staged, diffs: diffs)
                                    )
                                }
                            }
                        }
                        try await group.waitForAll()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func makeDiffBatches(
        worktree: GitWorktree,
        changes: [GitFileChange],
        individualChanges: [GitFileChange],
        scope: GitDiffScope,
        patchArguments: [String],
        statArguments: [String],
        individualDiffLoader: @escaping @Sendable (
            GitFileChange
        ) async throws -> GitFileDiff
    ) -> AsyncThrowingStream<[GitFileDiff], any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var startIndex = 0
                    while startIndex < changes.count {
                        try Task.checkCancellation()
                        let endIndex = min(
                            startIndex + Self.diffBatchSize,
                            changes.count
                        )
                        let chunk = Array(changes[startIndex..<endIndex])
                        let batches = try await loadPatchBatches(
                            worktree: worktree,
                            changes: chunk,
                            scope: scope,
                            patchArguments: patchArguments,
                            statArguments: statArguments
                        )
                        for batch in batches {
                            continuation.yield(batch)
                        }
                        startIndex = endIndex
                    }
                    for change in individualChanges {
                        try Task.checkCancellation()
                        continuation.yield([
                            try await individualDiffLoader(change)
                        ])
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func loadPatchBatches(
        worktree: GitWorktree,
        changes: [GitFileChange],
        scope: GitDiffScope,
        patchArguments: [String],
        statArguments: [String]
    ) async throws -> [[GitFileDiff]] {
        guard !changes.isEmpty else {
            return []
        }
        do {
            let data = try await runner.run(
                arguments: patchArguments + ["--"] + pathArguments(for: changes),
                workingDirectory: worktree.rootURL,
                maximumOutputBytes: Self.maximumPatchOutputBytes,
                timeout: Self.repositoryScanTimeout
            )
            let parsed = try UnifiedDiffParser.parseFiles(
                data,
                changes: changes,
                scope: scope
            )
            var enriched: [GitFileDiff] = []
            for diff in parsed {
                if case let .tooLarge(lineCount) = diff.state {
                    enriched.append(
                        try await oversizedDiff(
                            worktree: worktree,
                            change: diff.change,
                            scope: scope,
                            statArguments: statArguments,
                            reportedLineCount: lineCount
                        )
                    )
                } else {
                    enriched.append(diff)
                }
            }
            return [enriched]
        } catch is GitCommandOutputLimitError {
            guard changes.count > 1 else {
                return [[
                    try await oversizedDiff(
                        worktree: worktree,
                        change: changes[0],
                        scope: scope,
                        statArguments: statArguments,
                        reportedLineCount: nil
                    )
                ]]
            }
            return try await splitPatchBatches(
                worktree: worktree,
                changes: changes,
                scope: scope,
                patchArguments: patchArguments,
                statArguments: statArguments
            )
        } catch let error as UnifiedDiffParseError {
            guard changes.count > 1 else {
                return [[
                    try await unavailableDiff(
                        worktree: worktree,
                        change: changes[0],
                        scope: scope,
                        statArguments: statArguments,
                        reason: unavailableDiffReason(for: error)
                    )
                ]]
            }
            return try await splitPatchBatches(
                worktree: worktree,
                changes: changes,
                scope: scope,
                patchArguments: patchArguments,
                statArguments: statArguments
            )
        }
    }

    private func splitPatchBatches(
        worktree: GitWorktree,
        changes: [GitFileChange],
        scope: GitDiffScope,
        patchArguments: [String],
        statArguments: [String]
    ) async throws -> [[GitFileDiff]] {
        let middleIndex = changes.count / 2
        let left = try await loadPatchBatches(
            worktree: worktree,
            changes: Array(changes[..<middleIndex]),
            scope: scope,
            patchArguments: patchArguments,
            statArguments: statArguments
        )
        let right = try await loadPatchBatches(
            worktree: worktree,
            changes: Array(changes[middleIndex...]),
            scope: scope,
            patchArguments: patchArguments,
            statArguments: statArguments
        )
        return left + right
    }

    private func oversizedDiff(
        worktree: GitWorktree,
        change: GitFileChange,
        scope: GitDiffScope,
        statArguments: [String],
        reportedLineCount: Int?
    ) async throws -> GitFileDiff {
        let statData = try await runner.run(
            arguments: statArguments + ["--"] + pathArguments(for: [change]),
            workingDirectory: worktree.rootURL,
            maximumOutputBytes: 1 * 1_024 * 1_024,
            timeout: Self.repositoryScanTimeout
        )
        let stat = try GitNumstatParser.parse(statData)
        let changedLineCount = stat.addedLineCount + stat.deletedLineCount
        return GitFileDiff(
            change: change,
            scope: scope,
            hunks: [],
            state: .tooLarge(
                lineCount: max(
                    reportedLineCount ?? 0,
                    changedLineCount,
                    UnifiedDiffParser.maximumRenderedLines + 1
                )
            ),
            addedLineCount: stat.addedLineCount,
            deletedLineCount: stat.deletedLineCount
        )
    }

    private func unavailableDiff(
        worktree: GitWorktree,
        change: GitFileChange,
        scope: GitDiffScope,
        statArguments: [String],
        reason: String
    ) async throws -> GitFileDiff {
        let statData = try await runner.run(
            arguments: statArguments + ["--"] + pathArguments(for: [change]),
            workingDirectory: worktree.rootURL,
            maximumOutputBytes: 1 * 1_024 * 1_024,
            timeout: Self.repositoryScanTimeout
        )
        let stat = try GitNumstatParser.parse(statData)
        return GitFileDiff(
            change: change,
            scope: scope,
            hunks: [],
            state: .unavailable(reason),
            addedLineCount: stat.addedLineCount,
            deletedLineCount: stat.deletedLineCount
        )
    }

    private func unavailableDiffReason(for error: UnifiedDiffParseError) -> String {
        switch error {
        case .invalidUTF8:
            "Text diff uses an unsupported encoding."
        case .malformedHunkHeader:
            "Git returned a malformed hunk header."
        }
    }

    private func pendingStatArguments(
        scope: GitDiffScope,
        change: GitFileChange,
        options: GitDiffOptions
    ) -> [String] {
        var arguments = ["diff"]
        if scope == .staged {
            arguments.append("--cached")
        } else if change.kind == .unmerged {
            arguments.append("--ours")
        }
        arguments.append(contentsOf: ["--numstat", "--find-renames"])
        arguments.append(contentsOf: statOptionArguments(options))
        return arguments
    }

    private func pathArguments(for changes: [GitFileChange]) -> [String] {
        var seen: Set<String> = []
        var paths: [String] = []
        for change in changes {
            for path in [change.path, change.originalPath].compactMap({ $0 }) {
                if seen.insert(path).inserted {
                    paths.append(path)
                }
            }
        }
        return paths
    }

    private func diffHeaderPathsAreBatchSafe(_ change: GitFileChange) -> Bool {
        [change.path, change.originalPath].compactMap { $0 }.allSatisfy { path in
            path.utf8.allSatisfy { byte in
                byte >= 0x20
                    && byte != 0x22
                    && byte != 0x5C
                    && byte != 0x7F
            }
        }
    }

    private func mutationPathArguments(for change: GitFileChange) -> [String] {
        var paths = [change.path]
        if change.indexStatus == "R" || change.worktreeStatus == "R",
           let originalPath = change.originalPath,
           originalPath != change.path {
            paths.append(originalPath)
        }
        return paths
    }

    private func statOptionArguments(_ options: GitDiffOptions) -> [String] {
        options.ignoresWhitespace ? ["--ignore-all-space"] : []
    }

    public func loadImageDiff(
        worktree: GitWorktree,
        change: GitFileChange,
        scope: GitDiffScope
    ) async throws -> GitImageDiff {
        switch scope {
        case .working:
            let indexPath = change.worktreeStatus == "R" || change.worktreeStatus == "C"
                ? change.originalPath ?? change.path
                : change.path
            let oldImage = change.isUntracked
                ? nil
                : try await imageBlobFromGit(
                    path: indexPath,
                    revision: ":\(indexPath)",
                    worktree: worktree
                )
            let newImage = change.worktreeStatus == "D"
                ? nil
                : try imageBlobFromDisk(path: change.path, worktree: worktree)
            return GitImageDiff(oldImage: oldImage, newImage: newImage)
        case .staged:
            let oldPath = change.originalPath ?? change.path
            let oldImage = worktree.isUnborn || change.indexStatus == "A"
                ? nil
                : try await imageBlobFromGit(
                    path: oldPath,
                    revision: "HEAD:\(oldPath)",
                    worktree: worktree
                )
            let newImage = change.indexStatus == "D"
                ? nil
                : try await imageBlobFromGit(
                    path: change.path,
                    revision: ":\(change.path)",
                    worktree: worktree
                )
            return GitImageDiff(oldImage: oldImage, newImage: newImage)
        }
    }

    public func loadHistory(
        worktree: GitWorktree,
        limit: Int = 200
    ) async throws -> [GitCommit] {
        try await loadHistoryPage(
            worktree: worktree,
            revision: nil,
            offset: 0,
            pageSize: limit
        ).commits
    }

    public func loadHistoryPage(
        worktree: GitWorktree,
        revision: String?,
        offset: Int,
        pageSize: Int
    ) async throws -> GitHistoryPage {
        guard offset >= 0 else {
            throw GitHistoryLoadError.invalidOffset(offset)
        }
        guard pageSize > 0 && pageSize < Int.max else {
            throw GitHistoryLoadError.invalidPageSize(pageSize)
        }
        guard !worktree.isUnborn else {
            return GitHistoryPage(commits: [], nextOffset: 0, hasMore: false)
        }

        var arguments = [
            "log",
            "-z",
            "--shortstat",
            "--decorate=full",
            "--format=\(Self.historyFormat)",
            "--max-count=\(pageSize + 1)",
            "--skip=\(offset)"
        ]
        if let revision {
            arguments.append(revision)
        }
        let data = try await runner.run(
            arguments: arguments,
            workingDirectory: worktree.rootURL,
            maximumOutputBytes: Self.maximumHistoryOutputBytes,
            environment: ["LC_ALL": "C"],
            timeout: Self.repositoryScanTimeout
        )
        let loaded = try GitLogParser.parse(data)
        let commits = Array(loaded.prefix(pageSize))
        return GitHistoryPage(
            commits: commits,
            nextOffset: offset + commits.count,
            hasMore: loaded.count > pageSize
        )
    }

    public func loadLineHistory(
        worktree: GitWorktree,
        revision: String?,
        path: String,
        startLine: Int,
        endLine: Int,
        limit: Int = 500
    ) async throws -> [GitCommit] {
        guard !path.isEmpty else {
            throw GitHistoryLoadError.emptyPath
        }
        guard startLine > 0, endLine >= startLine else {
            throw GitHistoryLoadError.invalidLineRange(
                start: startLine,
                end: endLine
            )
        }
        guard limit > 0 && limit < Int.max else {
            throw GitHistoryLoadError.invalidPageSize(limit)
        }
        guard !worktree.isUnborn else {
            return []
        }

        var arguments = [
            "log",
            "-z",
            "-L", "\(startLine),\(endLine):\(path)",
            "--decorate=full",
            "--format=\(Self.historyFormat)",
            "--no-patch",
            "--max-count=\(limit)"
        ]
        if let revision {
            arguments.append(revision)
        }
        let data = try await runner.run(
            arguments: arguments,
            workingDirectory: worktree.rootURL,
            maximumOutputBytes: Self.maximumHistoryOutputBytes,
            environment: ["LC_ALL": "C"],
            timeout: Self.repositoryScanTimeout
        )
        return try GitLogParser.parse(data)
    }

    public func historyContainsCommits(
        worktree: GitWorktree,
        revision: String?,
        commitIDs: Set<GitCommit.ID>
    ) async throws -> Bool {
        guard !commitIDs.isEmpty else {
            return true
        }
        guard commitIDs.allSatisfy(Self.isFullObjectID) else {
            return false
        }
        let targetRevision = revision ?? "HEAD"
        for commitID in commitIDs.sorted() {
            do {
                _ = try await runner.run(
                    arguments: [
                        "merge-base", "--is-ancestor", commitID, targetRevision
                    ],
                    workingDirectory: worktree.rootURL,
                    maximumOutputBytes: 64 * 1_024,
                    maximumErrorBytes: 256 * 1_024,
                    timeout: Self.quickMetadataTimeout
                )
            } catch let failure as GitCommandFailure where failure.exitCode == 1 {
                return false
            }
        }
        return true
    }

    public func searchHistoryPage(
        worktree: GitWorktree,
        revision: String?,
        query: GitHistorySearchQuery,
        offset: Int,
        pageSize: Int
    ) async throws -> GitHistoryPage {
        guard offset >= 0 else {
            throw GitHistoryLoadError.invalidOffset(offset)
        }
        guard pageSize > 0 && pageSize < Int.max else {
            throw GitHistoryLoadError.invalidPageSize(pageSize)
        }
        guard !worktree.isUnborn else {
            return GitHistoryPage(commits: [], nextOffset: 0, hasMore: false)
        }

        var arguments = [
            "log",
            "-z",
            "--shortstat",
            "--decorate=full",
            "--format=\(Self.historyFormat)",
            "--max-count=\(pageSize + 1)",
            "--skip=\(offset)",
            "--regexp-ignore-case",
            "--fixed-strings"
        ]
        switch query.field {
        case .message:
            arguments.append("--grep=\(query.term)")
        case .author:
            arguments.append("--author=\(query.term)")
        }
        if let revision {
            arguments.append(revision)
        }
        let data = try await runner.run(
            arguments: arguments,
            workingDirectory: worktree.rootURL,
            maximumOutputBytes: Self.maximumHistoryOutputBytes,
            environment: ["LC_ALL": "C"],
            timeout: Self.repositoryScanTimeout
        )
        let loaded = try GitLogParser.parse(data)
        let commits = Array(loaded.prefix(pageSize))
        return GitHistoryPage(
            commits: commits,
            nextOffset: offset + commits.count,
            hasMore: loaded.count > pageSize
        )
    }

    public func loadCommitMessage(
        worktree: GitWorktree,
        commit: GitCommit
    ) async throws -> String {
        let data = try await runner.run(
            arguments: [
                "show",
                "-s",
                "--format=%B",
                commit.oid
            ],
            workingDirectory: worktree.rootURL,
            maximumOutputBytes: Self.maximumCommitMessageBytes,
            timeout: Self.repositoryScanTimeout
        )
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func loadCommitMetadata(
        worktree: GitWorktree,
        commit: GitCommit
    ) async throws -> GitCommitMetadata {
        let data = try await runner.run(
            arguments: [
                "show",
                "-s",
                "--format=%T%x1f%ae",
                commit.oid
            ],
            workingDirectory: worktree.rootURL,
            maximumOutputBytes: 64 * 1_024,
            timeout: Self.quickMetadataTimeout
        )
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = text.split(
            separator: "\u{1f}",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard fields.count == 2, !fields[0].isEmpty else {
            throw GitLogParseError.malformedRecord(text)
        }
        return GitCommitMetadata(
            treeOID: String(fields[0]),
            authorEmail: String(fields[1])
        )
    }

    public func loadCommitChanges(
        worktree: GitWorktree,
        commit: GitCommit
    ) async throws -> [GitFileChange] {
        let data = try await runner.run(
            arguments: [
                "-c", "core.quotePath=false",
                "show",
                "--format=",
                "--name-status",
                "-z",
                "--find-renames",
                "--diff-merges=first-parent",
                commit.oid
            ],
            workingDirectory: worktree.rootURL,
            maximumOutputBytes: Self.maximumChangedPathsOutputBytes,
            timeout: Self.repositoryScanTimeout
        )
        return try GitNameStatusParser.parse(data)
    }

    public func loadCommitDiff(
        worktree: GitWorktree,
        commit: GitCommit,
        change: GitFileChange,
        options: GitDiffOptions = GitDiffOptions()
    ) async throws -> GitFileDiff {
        var arguments = [
            "-c", "core.quotePath=false",
            "show",
            "--format=",
            "--no-ext-diff",
            "--no-color"
        ]
        arguments.append(contentsOf: options.arguments)
        arguments.append(contentsOf: [
            "--find-renames",
            "--diff-merges=first-parent",
            commit.oid,
            "--",
            change.path
        ])
        if let originalPath = change.originalPath {
            arguments.append(originalPath)
        }
        do {
            let data = try await runner.run(
                arguments: arguments,
                workingDirectory: worktree.rootURL,
                maximumOutputBytes: Self.maximumPatchOutputBytes,
                timeout: Self.repositoryScanTimeout
            )
            let diff = try UnifiedDiffParser.parseBounded(
                data,
                change: change,
                scope: .staged
            )
            guard case let .tooLarge(lineCount) = diff.state else {
                return diff
            }
            return try await oversizedDiff(
                worktree: worktree,
                change: change,
                scope: .staged,
                statArguments: commitStatArguments(commit: commit, options: options),
                reportedLineCount: lineCount
            )
        } catch is GitCommandOutputLimitError {
            return try await oversizedDiff(
                worktree: worktree,
                change: change,
                scope: .staged,
                statArguments: commitStatArguments(commit: commit, options: options),
                reportedLineCount: nil
            )
        } catch let error as UnifiedDiffParseError {
            return try await unavailableDiff(
                worktree: worktree,
                change: change,
                scope: .staged,
                statArguments: commitStatArguments(
                    commit: commit,
                    options: options
                ),
                reason: unavailableDiffReason(for: error)
            )
        }
    }

    public func loadCommitDiffs(
        worktree: GitWorktree,
        commit: GitCommit,
        changes: [GitFileChange],
        options: GitDiffOptions = GitDiffOptions()
    ) async throws -> [GitFileDiff] {
        let uniqueChanges = Self.uniqueChanges(changes)
        var diffs: [GitFileDiff] = []
        for try await batch in loadCommitDiffBatches(
            worktree: worktree,
            commit: commit,
            changes: uniqueChanges,
            options: options
        ) {
            diffs.append(contentsOf: batch)
        }
        let diffsByChangeID = Dictionary(
            diffs.map { ($0.change.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return uniqueChanges.compactMap { diffsByChangeID[$0.id] }
    }

    public func loadCommitDiffBatches(
        worktree: GitWorktree,
        commit: GitCommit,
        changes: [GitFileChange],
        options: GitDiffOptions = GitDiffOptions()
    ) -> AsyncThrowingStream<[GitFileDiff], any Error> {
        let changes = Self.uniqueChanges(changes)
        let batchChanges = changes.filter(diffHeaderPathsAreBatchSafe)
        let batchChangeIDs = Set(batchChanges.map(\.id))
        let individualChanges = changes.filter { !batchChangeIDs.contains($0.id) }
        return makeDiffBatches(
            worktree: worktree,
            changes: batchChanges,
            individualChanges: individualChanges,
            scope: .staged,
            patchArguments: [
                "-c", "core.quotePath=false",
                "show",
                "--format=",
                "--no-ext-diff",
                "--no-color"
            ] + options.arguments + [
                "--find-renames",
                "--diff-merges=first-parent",
                commit.oid
            ],
            statArguments: commitStatArguments(commit: commit, options: options),
            individualDiffLoader: { change in
                try await self.loadCommitDiff(
                    worktree: worktree,
                    commit: commit,
                    change: change,
                    options: options
                )
            }
        )
    }

    private func commitStatArguments(
        commit: GitCommit,
        options: GitDiffOptions
    ) -> [String] {
        [
            "show",
            "--format=",
            "--numstat"
        ] + statOptionArguments(options) + [
            "--find-renames",
            "--diff-merges=first-parent",
            commit.oid
        ]
    }

    public func loadCommitImageDiff(
        worktree: GitWorktree,
        commit: GitCommit,
        change: GitFileChange
    ) async throws -> GitImageDiff {
        let oldPath = change.originalPath ?? change.path
        let oldImage: GitImageBlob? = if change.indexStatus == "A"
            || commit.parentOIDs.first == nil {
            nil
        } else {
            try await imageBlobFromGit(
                path: oldPath,
                revision: "\(commit.parentOIDs[0]):\(oldPath)",
                worktree: worktree
            )
        }
        let newImage = change.indexStatus == "D"
            ? nil
            : try await imageBlobFromGit(
                path: change.path,
                revision: "\(commit.oid):\(change.path)",
                worktree: worktree
            )
        return GitImageDiff(oldImage: oldImage, newImage: newImage)
    }

    /// commit range 的 base 是排除端：\(baseOID)..\(headOID) 只包含 base 之后的改动。
    public func loadRangeChanges(
        worktree: GitWorktree,
        baseOID: String,
        headOID: String
    ) async throws -> [GitFileChange] {
        let data = try await runner.run(
            arguments: [
                "-c", "core.quotePath=false",
                "diff",
                "--name-status",
                "-z",
                "--find-renames",
                "\(baseOID)..\(headOID)"
            ],
            workingDirectory: worktree.rootURL,
            maximumOutputBytes: Self.maximumChangedPathsOutputBytes,
            timeout: Self.repositoryScanTimeout
        )
        return try GitNameStatusParser.parse(data)
    }

    public func loadRangeDiffs(
        worktree: GitWorktree,
        baseOID: String,
        headOID: String,
        changes: [GitFileChange],
        options: GitDiffOptions = GitDiffOptions()
    ) async throws -> [GitFileDiff] {
        let uniqueChanges = Self.uniqueChanges(changes)
        var diffs: [GitFileDiff] = []
        for try await batch in loadRangeDiffBatches(
            worktree: worktree,
            baseOID: baseOID,
            headOID: headOID,
            changes: uniqueChanges,
            options: options
        ) {
            diffs.append(contentsOf: batch)
        }
        let diffsByChangeID = Dictionary(
            diffs.map { ($0.change.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return uniqueChanges.compactMap { diffsByChangeID[$0.id] }
    }

    public func loadRangeDiffBatches(
        worktree: GitWorktree,
        baseOID: String,
        headOID: String,
        changes: [GitFileChange],
        options: GitDiffOptions = GitDiffOptions()
    ) -> AsyncThrowingStream<[GitFileDiff], any Error> {
        let changes = Self.uniqueChanges(changes)
        let batchChanges = changes.filter(diffHeaderPathsAreBatchSafe)
        let batchChangeIDs = Set(batchChanges.map(\.id))
        let individualChanges = changes.filter { !batchChangeIDs.contains($0.id) }
        return makeDiffBatches(
            worktree: worktree,
            changes: batchChanges,
            individualChanges: individualChanges,
            scope: .staged,
            patchArguments: [
                "-c", "core.quotePath=false",
                "diff",
                "--no-ext-diff",
                "--no-color"
            ] + options.arguments + [
                "--find-renames",
                "\(baseOID)..\(headOID)"
            ],
            statArguments: rangeStatArguments(
                baseOID: baseOID,
                headOID: headOID,
                options: options
            ),
            individualDiffLoader: { change in
                try await self.loadRangeDiff(
                    worktree: worktree,
                    baseOID: baseOID,
                    headOID: headOID,
                    change: change,
                    options: options
                )
            }
        )
    }

    public func loadRangeDiff(
        worktree: GitWorktree,
        baseOID: String,
        headOID: String,
        change: GitFileChange,
        options: GitDiffOptions = GitDiffOptions()
    ) async throws -> GitFileDiff {
        var arguments = [
            "-c", "core.quotePath=false",
            "diff",
            "--no-ext-diff",
            "--no-color"
        ]
        arguments.append(contentsOf: options.arguments)
        arguments.append(contentsOf: [
            "--find-renames",
            "\(baseOID)..\(headOID)",
            "--",
            change.path
        ])
        if let originalPath = change.originalPath {
            arguments.append(originalPath)
        }
        do {
            let data = try await runner.run(
                arguments: arguments,
                workingDirectory: worktree.rootURL,
                maximumOutputBytes: Self.maximumPatchOutputBytes,
                timeout: Self.repositoryScanTimeout
            )
            let diff = try UnifiedDiffParser.parseBounded(
                data,
                change: change,
                scope: .staged
            )
            guard case let .tooLarge(lineCount) = diff.state else {
                return diff
            }
            return try await oversizedDiff(
                worktree: worktree,
                change: change,
                scope: .staged,
                statArguments: rangeStatArguments(
                    baseOID: baseOID,
                    headOID: headOID,
                    options: options
                ),
                reportedLineCount: lineCount
            )
        } catch is GitCommandOutputLimitError {
            return try await oversizedDiff(
                worktree: worktree,
                change: change,
                scope: .staged,
                statArguments: rangeStatArguments(
                    baseOID: baseOID,
                    headOID: headOID,
                    options: options
                ),
                reportedLineCount: nil
            )
        } catch let error as UnifiedDiffParseError {
            return try await unavailableDiff(
                worktree: worktree,
                change: change,
                scope: .staged,
                statArguments: rangeStatArguments(
                    baseOID: baseOID,
                    headOID: headOID,
                    options: options
                ),
                reason: unavailableDiffReason(for: error)
            )
        }
    }

    private func rangeStatArguments(
        baseOID: String,
        headOID: String,
        options: GitDiffOptions
    ) -> [String] {
        [
            "diff",
            "--numstat"
        ] + statOptionArguments(options) + [
            "--find-renames",
            "\(baseOID)..\(headOID)"
        ]
    }

    public func loadRangeImageDiff(
        worktree: GitWorktree,
        baseOID: String,
        headOID: String,
        change: GitFileChange
    ) async throws -> GitImageDiff {
        let oldPath = change.originalPath ?? change.path
        let oldImage = change.indexStatus == "A"
            ? nil
            : try await imageBlobFromGit(
                path: oldPath,
                revision: "\(baseOID):\(oldPath)",
                worktree: worktree
            )
        let newImage = change.indexStatus == "D"
            ? nil
            : try await imageBlobFromGit(
                path: change.path,
                revision: "\(headOID):\(change.path)",
                worktree: worktree
        )
        return GitImageDiff(oldImage: oldImage, newImage: newImage)
    }

    private func imageBlobFromGit(
        path: String,
        revision: String,
        worktree: GitWorktree
    ) async throws -> GitImageBlob {
        let contents: Data
        do {
            contents = try await runner.run(
                arguments: ["show", revision],
                workingDirectory: worktree.rootURL,
                maximumOutputBytes: GitImageDiff.maximumBlobByteCount,
                timeout: Self.repositoryScanTimeout
            )
        } catch let error as GitCommandOutputLimitError {
            throw GitImageDiffError.tooLarge(
                path: path,
                byteCount: error.actualByteCount,
                limit: error.limit
            )
        }
        return GitImageBlob(path: path, contents: contents)
    }

    private func imageBlobFromDisk(
        path: String,
        worktree: GitWorktree
    ) throws -> GitImageBlob {
        let rootURL = worktree.rootURL.standardizedFileURL
        let fileURL = rootURL.appendingPathComponent(path).standardizedFileURL
        guard fileURL.path.hasPrefix(rootURL.path + "/") else {
            throw GitMutationError.pathOutsideWorktree
        }
        let resolvedRootURL = rootURL.resolvingSymlinksInPath()
        let resolvedFileURL = fileURL.resolvingSymlinksInPath()
        guard resolvedFileURL.path.hasPrefix(resolvedRootURL.path + "/") else {
            throw GitMutationError.pathOutsideWorktree
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard byteCount <= UInt64(GitImageDiff.maximumBlobByteCount) else {
            throw GitImageDiffError.tooLarge(
                path: path,
                byteCount: Int(clamping: byteCount),
                limit: GitImageDiff.maximumBlobByteCount
            )
        }
        return GitImageBlob(path: path, contents: try Data(contentsOf: fileURL))
    }

    public func stageFile(worktree: GitWorktree, change: GitFileChange) async throws {
        _ = try await runner.run(
            arguments: ["add", "--"] + mutationPathArguments(for: change),
            workingDirectory: worktree.rootURL
        )
    }

    public func performRemoteAction(
        _ action: GitRemoteAction,
        worktree: GitWorktree
    ) async throws {
        let arguments: [String]
        switch action {
        case .pull:
            arguments = ["pull", "--ff-only"]
        case .push:
            arguments = try await pushArguments(for: worktree)
        }
        _ = try await runner.run(
            arguments: arguments,
            workingDirectory: worktree.rootURL,
            maximumErrorBytes: Self.maximumRemoteErrorBytes,
            environment: [
                "GIT_TERMINAL_PROMPT": "0",
                "GCM_INTERACTIVE": "Never"
            ],
            timeout: Self.remoteOperationTimeout
        )
    }

    private func pushArguments(for worktree: GitWorktree) async throws -> [String] {
        guard let branchRef = worktree.branchRef,
              branchRef.hasPrefix("refs/heads/") else {
            throw GitRemoteActionError.unavailableBranch
        }
        let branch = String(branchRef.dropFirst("refs/heads/".count))
        guard !branch.isEmpty else {
            throw GitRemoteActionError.unavailableBranch
        }
        async let configuredRemote = gitConfigValue(
            "branch.\(branch).remote",
            worktree: worktree
        )
        async let configuredMerge = gitConfigValue(
            "branch.\(branch).merge",
            worktree: worktree
        )
        if try await configuredRemote != nil,
           try await configuredMerge != nil {
            return ["push"]
        }
        let remoteData = try await runner.run(
            arguments: ["remote"],
            workingDirectory: worktree.rootURL,
            maximumOutputBytes: 64 * 1_024,
            timeout: Self.quickMetadataTimeout
        )
        let remotes = Set(
            String(decoding: remoteData, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map(String.init)
        ).sorted()
        let remote: String
        if remotes.contains("origin") {
            remote = "origin"
        } else if remotes.count == 1, let onlyRemote = remotes.first {
            remote = onlyRemote
        } else if remotes.isEmpty {
            throw GitRemoteActionError.noRemote
        } else {
            throw GitRemoteActionError.ambiguousRemotes(remotes)
        }
        return ["push", "--set-upstream", remote, branch]
    }

    private func gitConfigValue(
        _ key: String,
        worktree: GitWorktree
    ) async throws -> String? {
        do {
            let data = try await runner.run(
                arguments: ["config", "--get", key],
                workingDirectory: worktree.rootURL,
                maximumOutputBytes: 64 * 1_024,
                timeout: Self.quickMetadataTimeout
            )
            let value = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        } catch is CancellationError {
            throw CancellationError()
        } catch is GitCommandFailure {
            return nil
        }
    }

    public func unstageFile(worktree: GitWorktree, change: GitFileChange) async throws {
        let arguments: [String]
        if worktree.isUnborn {
            arguments = ["rm", "--cached", "--ignore-unmatch", "-q", "--"]
                + mutationPathArguments(for: change)
        } else {
            arguments = ["reset", "-q", "HEAD", "--"]
                + mutationPathArguments(for: change)
        }
        _ = try await runner.run(arguments: arguments, workingDirectory: worktree.rootURL)
    }

    public func discardFile(worktree: GitWorktree, change: GitFileChange) async throws {
        if change.isUntracked {
            let target = try discardTargetURL(
                worktree: worktree,
                relativePath: change.path
            )
            _ = try discardRecoveryStore.preserve(
                itemAt: target,
                worktreeURL: worktree.rootURL,
                relativePath: change.path,
                kind: .file,
                movesOriginal: true
            )
            return
        }
        if let submoduleStatus = change.submoduleStatus {
            let root = worktree.rootURL.standardizedFileURL
            let target = root.appendingPathComponent(change.path).standardizedFileURL
            guard target.path.hasPrefix(root.path + "/") else {
                throw GitMutationError.pathOutsideWorktree
            }
            let resolvedRoot = root.resolvingSymlinksInPath()
            let resolvedTarget = target.resolvingSymlinksInPath()
            guard resolvedTarget.path.hasPrefix(resolvedRoot.path + "/") else {
                throw GitMutationError.pathOutsideWorktree
            }
            try await preserveSubmoduleDiscard(
                worktree: worktree,
                change: change,
                submoduleURL: target
            )
            if submoduleStatus.hasUntrackedChanges {
                _ = try await runner.run(
                    arguments: ["-C", change.path, "clean", "-fd"],
                    workingDirectory: worktree.rootURL
                )
            }
            _ = try await runner.run(
                arguments: [
                    "submodule",
                    "update",
                    "--checkout",
                    "--force",
                    "--recursive",
                    "--",
                    change.path
                ],
                workingDirectory: worktree.rootURL
            )
            return
        }
        try preserveDiscardedItemIfPresent(
            worktree: worktree,
            relativePath: change.path,
            kind: .file
        )
        _ = try await runner.run(
            arguments: ["restore", "--worktree", "--", change.path],
            workingDirectory: worktree.rootURL
        )
    }

    public func applySelection(
        _ action: GitPendingSelectionAction,
        worktree: GitWorktree,
        diff: GitFileDiff,
        selectedLineIDs: Set<GitDiffLine.ID>
    ) async throws {
        var arguments = ["apply", "--unidiff-zero", "--recount", "--whitespace=nowarn"]
        let treatsUntrackedAsNewFile = action != .discard
        switch action {
        case .stage:
            guard diff.scope == .working else {
                throw GitMutationError.invalidScope
            }
            arguments.append("--cached")
        case .unstage:
            guard diff.scope == .staged else {
                throw GitMutationError.invalidScope
            }
            arguments.append(contentsOf: ["--cached", "--reverse"])
        case .discard:
            guard diff.scope == .working else {
                throw GitMutationError.invalidScope
            }
            arguments.append("--reverse")
        }
        let newFileMode = try await selectionNewFileMode(
            worktree: worktree,
            diff: diff,
            selectedLineIDs: selectedLineIDs,
            treatsUntrackedAsNewFile: treatsUntrackedAsNewFile
        )
        if action == .discard {
            try preserveDiscardedItemIfPresent(
                worktree: worktree,
                relativePath: diff.change.path,
                kind: .selection
            )
        }
        arguments.append("-")
        _ = try await runner.run(
            arguments: arguments,
            workingDirectory: worktree.rootURL,
            standardInput: try GitPatchSelectionBuilder.patch(
                for: diff,
                selectedLineIDs: selectedLineIDs,
                treatsUntrackedAsNewFile: treatsUntrackedAsNewFile,
                newFileMode: newFileMode
            )
        )
    }

    private func selectionNewFileMode(
        worktree: GitWorktree,
        diff: GitFileDiff,
        selectedLineIDs: Set<GitDiffLine.ID>,
        treatsUntrackedAsNewFile: Bool
    ) async throws -> String {
        guard GitPatchSelectionBuilder.usesNewFileHeader(
            for: diff,
            selectedLineIDs: selectedLineIDs,
            treatsUntrackedAsNewFile: treatsUntrackedAsNewFile
        ) else {
            return "100644"
        }
        if diff.change.isUntracked && treatsUntrackedAsNewFile {
            let root = worktree.rootURL.standardizedFileURL
            let fileURL = root.appendingPathComponent(
                diff.change.path
            ).standardizedFileURL
            guard fileURL.path.hasPrefix(root.path + "/") else {
                throw GitMutationError.pathOutsideWorktree
            }
            let attributes = try FileManager.default.attributesOfItem(
                atPath: fileURL.path
            )
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                return "120000"
            }
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
                ?? 0o644
            return permissions & 0o111 == 0 ? "100644" : "100755"
        }
        let output = try await runner.run(
            arguments: [
                "ls-files",
                "--format=%(objectmode)",
                "--",
                diff.change.path
            ],
            workingDirectory: worktree.rootURL,
            maximumOutputBytes: 64,
            timeout: Self.quickMetadataTimeout
        )
        let mode = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["100644", "100755", "120000"].contains(mode) else {
            throw GitPatchSelectionError.unsupportedFileMode(mode)
        }
        return mode
    }

    private func preserveDiscardedItemIfPresent(
        worktree: GitWorktree,
        relativePath: String,
        kind: GitDiscardRecoveryKind
    ) throws {
        let target = try discardTargetURL(
            worktree: worktree,
            relativePath: relativePath
        )
        guard (try? FileManager.default.attributesOfItem(
            atPath: target.path
        )) != nil else {
            return
        }
        _ = try discardRecoveryStore.preserve(
            itemAt: target,
            worktreeURL: worktree.rootURL,
            relativePath: relativePath,
            kind: kind,
            movesOriginal: false
        )
    }

    private func discardTargetURL(
        worktree: GitWorktree,
        relativePath: String
    ) throws -> URL {
        let root = worktree.rootURL.standardizedFileURL
        let target = root.appendingPathComponent(
            relativePath
        ).standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else {
            throw GitMutationError.pathOutsideWorktree
        }
        return target
    }

    private func preserveSubmoduleDiscard(
        worktree: GitWorktree,
        change: GitFileChange,
        submoduleURL: URL
    ) async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "AgentGit-Submodule-Recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        let payloadURL = temporaryRoot.appendingPathComponent(
            "Submodule Recovery",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: payloadURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let headData = try await runner.run(
            arguments: ["-C", change.path, "rev-parse", "HEAD"],
            workingDirectory: worktree.rootURL,
            maximumOutputBytes: 4 * 1_024,
            timeout: Self.quickMetadataTimeout
        )
        let headOID = String(decoding: headData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let patchData = try await runner.run(
            arguments: [
                "-C", change.path,
                "diff",
                "--binary",
                "--no-ext-diff",
                "HEAD",
                "--"
            ],
            workingDirectory: worktree.rootURL,
            maximumOutputBytes: 128 * 1_024 * 1_024,
            timeout: Self.repositoryScanTimeout
        )
        if !patchData.isEmpty {
            try patchData.write(
                to: payloadURL.appendingPathComponent("Changes.patch"),
                options: .atomic
            )
        }
        let untrackedData = try await runner.run(
            arguments: [
                "-C", change.path,
                "ls-files",
                "--others",
                "--exclude-standard",
                "-z"
            ],
            workingDirectory: worktree.rootURL,
            maximumOutputBytes: 16 * 1_024 * 1_024,
            timeout: Self.repositoryScanTimeout
        )
        let untrackedPaths = untrackedData.split(separator: 0).map {
            String(decoding: $0, as: UTF8.self)
        }
        let untrackedRoot = payloadURL.appendingPathComponent(
            "Untracked",
            isDirectory: true
        )
        for relativePath in untrackedPaths {
            let sourceURL = submoduleURL
                .appendingPathComponent(relativePath)
                .standardizedFileURL
            guard sourceURL.path.hasPrefix(submoduleURL.path + "/") else {
                throw GitMutationError.pathOutsideWorktree
            }
            let recoveredURL = untrackedRoot
                .appendingPathComponent(relativePath)
                .standardizedFileURL
            guard recoveredURL.path.hasPrefix(untrackedRoot.path + "/") else {
                throw GitMutationError.pathOutsideWorktree
            }
            try fileManager.createDirectory(
                at: recoveredURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.copyItem(at: sourceURL, to: recoveredURL)
        }
        let instructions = """
        Submodule: \(change.path)
        HEAD before discard: \(headOID)

        Changes.patch contains tracked and staged changes relative to that HEAD.
        Untracked contains files that were outside the submodule index.
        """
        try Data((instructions + "\n").utf8).write(
            to: payloadURL.appendingPathComponent("Recovery.txt"),
            options: .atomic
        )
        _ = try discardRecoveryStore.preserve(
            itemAt: payloadURL,
            worktreeURL: worktree.rootURL,
            relativePath: "\(change.path)/Submodule Recovery",
            kind: .file,
            movesOriginal: true
        )
    }

    public func loadWorktree(
        _ worktree: GitWorktree,
        submoduleScanMode: GitSubmoduleScanMode = .commitsOnly
    ) async -> GitWorktreeSnapshot {
        do {
            async let loadedGitDirectories = absoluteGitDirectories(for: worktree.rootURL)
            let initialStatus = try await loadStatus(
                for: worktree,
                submoduleScanMode: submoduleScanMode
            )
            let refreshedWorktree = worktreeByApplyingStatus(
                initialStatus,
                to: worktree
            )
            async let loadedBranch = supplementalResult(label: "Ahead/behind") {
                try await loadBranchStatus(
                    for: refreshedWorktree,
                    status: initialStatus
                )
            }
            let gitDirectories = await loadedGitDirectories
            let diffStatCacheKey = diffStatCacheKey(
                for: refreshedWorktree,
                status: initialStatus,
                gitDirectory: gitDirectories.gitDirectory,
                commonGitDirectory: gitDirectories.commonGitDirectory
            )
            async let loadedDiffStat = supplementalResult(label: "Diff statistics") {
                try await self.diffStat(
                    for: refreshedWorktree,
                    status: initialStatus,
                    cacheKey: diffStatCacheKey
                )
            }
            async let loadedActivityDate = activityDate(
                for: refreshedWorktree,
                status: initialStatus,
                gitDirectory: gitDirectories.gitDirectory
            )
            let branchResult = try await loadedBranch
            let diffStatResult = try await loadedDiffStat
            let lastActivityAt = await loadedActivityDate
            var supplementalErrors: [String] = []
            let branch: GitBranchStatus?
            switch branchResult {
            case let .success(value):
                branch = value
            case let .failure(errorMessage):
                branch = initialStatus.branch.map { initialBranch in
                    GitBranchStatus(
                        upstreamRef: initialBranch.upstreamRef,
                        aheadCount: initialBranch.aheadCount,
                        behindCount: initialBranch.behindCount,
                        upstreamError: errorMessage
                    )
                }
                supplementalErrors.append(errorMessage)
            }
            let diffStat: GitDiffStat
            switch diffStatResult {
            case let .success(value):
                diffStat = value
            case let .failure(errorMessage):
                diffStat = .zero
                supplementalErrors.append(errorMessage)
            }
            let status = GitStatusSnapshot(
                changes: initialStatus.changes,
                branch: branch,
                headOID: initialStatus.headOID,
                branchHead: initialStatus.branchHead
            )
            let eventWatchURLs = Set(
                [
                    refreshedWorktree.rootURL,
                    gitDirectories.gitDirectory,
                    gitDirectories.commonGitDirectory
                ].compactMap { $0 }
            ).sorted { $0.path < $1.path }
            return GitWorktreeSnapshot(
                worktree: refreshedWorktree,
                status: status,
                diffStat: diffStat,
                lastActivityAt: lastActivityAt,
                refreshedAt: Date(),
                errorMessage: supplementalErrors.isEmpty
                    ? nil
                    : supplementalErrors.joined(separator: "\n"),
                eventWatchURLs: eventWatchURLs
            )
        } catch {
            return GitWorktreeSnapshot(
                worktree: worktree,
                status: .clean,
                diffStat: .zero,
                lastActivityAt: .distantPast,
                refreshedAt: nil,
                errorMessage: String(describing: error),
                hasUsableState: false,
                eventWatchURLs: [worktree.rootURL]
            )
        }
    }

    private func supplementalResult<Value: Sendable>(
        label: String,
        operation: @Sendable () async throws -> Value
    ) async throws -> GitSupplementalLoadResult<Value> {
        do {
            return .success(try await operation())
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure("\(label): \(String(describing: error))")
        }
    }

    private func loadStatus(
        for worktree: GitWorktree,
        submoduleScanMode: GitSubmoduleScanMode
    ) async throws -> GitStatusSnapshot {
        let statusData = try await runner.run(
            arguments: [
                "status",
                "--porcelain=v2",
                "-z",
                "--branch",
                "--no-ahead-behind",
                "--untracked-files=normal",
                submoduleScanMode == .allChanges
                    ? "--ignore-submodules=none"
                    : "--ignore-submodules=dirty"
            ],
            workingDirectory: worktree.rootURL,
            timeout: Self.repositoryScanTimeout
        )
        let initialStatus = try GitStatusParser.parsePorcelainV2(statusData)
        let untrackedDirectories = initialStatus.changes.filter {
            $0.isUntracked && $0.path.hasSuffix("/")
        }
        guard !untrackedDirectories.isEmpty else {
            return initialStatus
        }

        let directoryIDs = Set(untrackedDirectories.map(\.id))
        let untrackedData = try await runner.run(
            arguments: [
                "ls-files",
                "--others",
                "--exclude-standard",
                "-z",
                "--"
            ] + untrackedDirectories.map(\.path),
            workingDirectory: worktree.rootURL,
            timeout: Self.repositoryScanTimeout
        )
        return GitStatusSnapshot(
            changes: initialStatus.changes.filter { !directoryIDs.contains($0.id) }
                + (try GitUntrackedFilesParser.parse(untrackedData)),
            branch: initialStatus.branch,
            headOID: initialStatus.headOID,
            branchHead: initialStatus.branchHead
        )
    }

    private func loadBranchStatus(
        for worktree: GitWorktree,
        status: GitStatusSnapshot
    ) async throws -> GitBranchStatus? {
        guard let branch = status.branch,
              let upstreamRef = branch.upstreamRef,
              let headOID = status.headOID else {
            return nil
        }
        let referenceData: Data
        do {
            referenceData = try await runner.run(
                arguments: [
                    "rev-parse",
                    "@{upstream}^{commit}"
                ],
                workingDirectory: worktree.rootURL,
                timeout: Self.quickMetadataTimeout
            )
        } catch is GitCommandFailure {
            throw GitBranchStatusLoadError.upstreamUnavailable(upstreamRef)
        }
        let upstreamOIDs = String(decoding: referenceData, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard upstreamOIDs.count == 1 else {
            throw GitBranchStatusLoadError.malformedReferenceOutput
        }
        let cacheKey = GitBranchStatusCacheKey(
            worktreePath: worktree.rootURL.standardizedFileURL.path,
            headOID: headOID,
            upstreamOID: upstreamOIDs[0],
            upstreamRef: upstreamRef
        )
        if let cached = await branchStatusCache.value(for: cacheKey) {
            return cached
        }
        let data = try await runner.run(
            arguments: [
                "rev-list",
                "--left-right",
                "--count",
                "\(headOID)...\(upstreamOIDs[0])"
            ],
            workingDirectory: worktree.rootURL,
            timeout: Self.repositoryScanTimeout
        )
        let status = try GitAheadBehindParser.parse(data, upstreamRef: upstreamRef)
        await branchStatusCache.insert(status, for: cacheKey)
        return status
    }

    private func diffStat(
        for worktree: GitWorktree,
        status: GitStatusSnapshot,
        cacheKey: GitDiffStatCacheKey
    ) async throws -> GitDiffStat {
        guard !status.changes.allSatisfy(\.isUntracked) else {
            return .zero
        }
        if let cached = await diffStatCache.value(for: cacheKey) {
            return cached
        }
        let value = try await diffStat(for: worktree, status: status)
        await diffStatCache.insert(value, for: cacheKey)
        return value
    }

    private func diffStatCacheKey(
        for worktree: GitWorktree,
        status: GitStatusSnapshot,
        gitDirectory: URL?,
        commonGitDirectory: URL?
    ) -> GitDiffStatCacheKey {
        let metadataURLs = Set(
            [
                gitDirectory?.appendingPathComponent("HEAD"),
                gitDirectory?.appendingPathComponent("index"),
                gitDirectory?.appendingPathComponent("logs/HEAD"),
                commonGitDirectory?.appendingPathComponent("config"),
                commonGitDirectory?.appendingPathComponent("info/attributes"),
                worktree.rootURL.appendingPathComponent(".gitattributes")
            ].compactMap { $0?.standardizedFileURL }
        )
        let changedURLs = Set(
            status.changes.flatMap { change in
                [change.path, change.originalPath].compactMap { path -> URL? in
                    guard let path else {
                        return nil
                    }
                    let url = worktree.rootURL.appendingPathComponent(path)
                    if FileManager.default.fileExists(atPath: url.path) {
                        return url.standardizedFileURL
                    }
                    return url.deletingLastPathComponent().standardizedFileURL
                }
            }
        )
        return GitDiffStatCacheKey(
            worktreePath: worktree.rootURL.standardizedFileURL.path,
            headOID: status.headOID,
            status: status,
            gitMetadata: metadataURLs.map(fileSystemFingerprint).sorted {
                $0.path < $1.path
            },
            changedFiles: changedURLs.map(fileSystemFingerprint).sorted {
                $0.path < $1.path
            }
        )
    }

    private func fileSystemFingerprint(_ url: URL) -> GitFileSystemFingerprint {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return GitFileSystemFingerprint(
            path: url.path,
            modificationDate: attributes?[.modificationDate] as? Date,
            fileSize: (attributes?[.size] as? NSNumber)?.uint64Value,
            fileNumber: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    /// 相对 HEAD 的改动规模；unborn HEAD 无 diff 基准，改为 staged + working 两段求和。
    private func diffStat(
        for worktree: GitWorktree,
        status: GitStatusSnapshot
    ) async throws -> GitDiffStat {
        let baseArguments = ["diff", "--no-ext-diff", "--numstat"]
        let trackedChanges = status.changes.filter { !$0.isUntracked }
        let paths = pathArguments(for: trackedChanges)
        let pathBytes = paths.reduce(0) { $0 + $1.utf8.count + 1 }
        let pathFilter = paths.count <= Self.maximumDiffStatPathCount
                && pathBytes <= Self.maximumDiffStatPathBytes
            ? ["--"] + paths
            : []
        guard worktree.isUnborn else {
            let data = try await runner.run(
                arguments: baseArguments + ["HEAD"] + pathFilter,
                workingDirectory: worktree.rootURL,
                timeout: Self.repositoryScanTimeout
            )
            return try GitNumstatParser.parse(data)
        }

        let stagedData = try await runner.run(
            arguments: baseArguments + ["--cached"] + pathFilter,
            workingDirectory: worktree.rootURL,
            timeout: Self.repositoryScanTimeout
        )
        let workingData = try await runner.run(
            arguments: baseArguments + pathFilter,
            workingDirectory: worktree.rootURL,
            timeout: Self.repositoryScanTimeout
        )
        return try GitNumstatParser.parse(stagedData) + GitNumstatParser.parse(workingData)
    }

    /// 与列表的 lastActivityAt 使用同一计算方式，不计查看记录或忽略文件。
    public func loadActivityDate(for worktree: GitWorktree) async throws -> Date {
        async let loadedDirectories = absoluteGitDirectories(for: worktree.rootURL)
        let status = try await loadStatus(for: worktree, submoduleScanMode: .commitsOnly)
        let directories = await loadedDirectories
        return await activityDate(
            for: worktree, status: status, gitDirectory: directories.gitDirectory
        )
    }

    private func activityDate(
        for worktree: GitWorktree,
        status: GitStatusSnapshot,
        gitDirectory: URL?
    ) async -> Date {
        var dates: [Date] = []
        async let loadedGitDates = gitDates(
            for: worktree.rootURL,
            gitDirectory: gitDirectory
        )
        for change in status.changes {
            let fileURL = worktree.rootURL.appendingPathComponent(change.path)
            if let date = modificationDate(at: fileURL) {
                dates.append(date)
            } else if change.indexStatus == "D" || change.worktreeStatus == "D",
                      let date = modificationDate(at: fileURL.deletingLastPathComponent()) {
                dates.append(date)
            }
        }
        dates.append(contentsOf: await loadedGitDates)

        return dates.max() ?? .distantPast
    }

    private func gitDates(
        for worktreeURL: URL,
        gitDirectory: URL?
    ) async -> [Date] {
        var dates: [Date] = []
        if let gitDirectory {
            if let headLogDate = modificationDate(
                at: gitDirectory.appendingPathComponent("logs/HEAD")
            ) {
                dates.append(headLogDate)
            }
        }
        if let commitDate = await headCommitDate(for: worktreeURL) {
            dates.append(commitDate)
        }
        return dates
    }

    private func absoluteGitDirectories(
        for worktreeURL: URL
    ) async -> (gitDirectory: URL?, commonGitDirectory: URL?) {
        guard let data = try? await runner.run(
            arguments: [
                "rev-parse",
                "--path-format=absolute",
                "--absolute-git-dir",
                "--git-common-dir"
            ],
            workingDirectory: worktreeURL,
            timeout: Self.quickMetadataTimeout
        ) else {
            return (nil, nil)
        }

        let paths = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard paths.count == 2 else {
            return (nil, nil)
        }
        return (
            URL(fileURLWithPath: paths[0], isDirectory: true).standardizedFileURL,
            URL(fileURLWithPath: paths[1], isDirectory: true).standardizedFileURL
        )
    }

    private func worktreeByApplyingStatus(
        _ status: GitStatusSnapshot,
        to worktree: GitWorktree
    ) -> GitWorktree {
        let isDetached = status.branchHead == "(detached)"
        let branchRef: String? = if let branchHead = status.branchHead, !isDetached {
            "refs/heads/\(branchHead)"
        } else if isDetached {
            nil
        } else {
            worktree.branchRef
        }
        return GitWorktree(
            rootURL: worktree.rootURL,
            headOID: status.headOID,
            branchRef: branchRef,
            isBare: worktree.isBare,
            isDetached: isDetached || (status.branchHead == nil && worktree.isDetached),
            lockedReason: worktree.lockedReason,
            prunableReason: worktree.prunableReason
        )
    }

    private func headCommitDate(for worktreeURL: URL) async -> Date? {
        guard let data = try? await runner.run(
            arguments: ["show", "-s", "--format=%cI", "HEAD"],
            workingDirectory: worktreeURL,
            timeout: Self.quickMetadataTimeout
        ) else {
            return nil
        }

        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ISO8601DateFormatter().date(from: value)
    }

    private static func uniqueChanges(
        _ changes: [GitFileChange]
    ) -> [GitFileChange] {
        var seenIDs: Set<GitFileChange.ID> = []
        return changes.filter { seenIDs.insert($0.id).inserted }
    }

    private static func isFullObjectID(_ value: String) -> Bool {
        guard value.utf8.count == 40 || value.utf8.count == 64 else {
            return false
        }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte)
                || (65...70).contains(byte)
                || (97...102).contains(byte)
        }
    }

    private func modificationDate(at url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }
}

public enum GitProjectResolutionError: LocalizedError, Equatable, Sendable {
    case noNonBareWorktree

    public var errorDescription: String? {
        switch self {
        case .noNonBareWorktree:
            "The repository does not contain a reviewable worktree."
        }
    }
}
