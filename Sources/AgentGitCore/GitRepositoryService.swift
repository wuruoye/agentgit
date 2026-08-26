import Foundation

public struct GitWorktreeSnapshot: Identifiable, Hashable, Sendable {
    public let worktree: GitWorktree
    public let status: GitStatusSnapshot
    public let diffStat: GitDiffStat
    public let lastActivityAt: Date
    public let errorMessage: String?

    public init(
        worktree: GitWorktree,
        status: GitStatusSnapshot,
        diffStat: GitDiffStat,
        lastActivityAt: Date,
        errorMessage: String?
    ) {
        self.worktree = worktree
        self.status = status
        self.diffStat = diffStat
        self.lastActivityAt = lastActivityAt
        self.errorMessage = errorMessage
    }

    public var id: GitWorktree.ID {
        worktree.id
    }
}

public struct GitProjectSnapshot: Identifiable, Hashable, Sendable {
    public let project: GitProject
    public let worktrees: [GitWorktreeSnapshot]
    public let refreshedAt: Date

    public init(project: GitProject, worktrees: [GitWorktreeSnapshot], refreshedAt: Date) {
        self.project = project
        self.worktrees = worktrees
        self.refreshedAt = refreshedAt
    }

    public var id: GitProject.ID {
        project.id
    }
}

public enum GitPendingSelectionAction: Hashable, Sendable {
    case stage
    case unstage
    case discard
}

public enum GitMutationError: Error, Equatable, Sendable {
    case invalidScope
    case pathOutsideWorktree
}

public struct GitRepositoryService: Sendable {
    /// oid, short oid, author, author date, parents, refs, subject —— 与 GitLogParser 对应。
    private static let historyFormat = "%H%x1f%h%x1f%an%x1f%aI%x1f%P%x1f%D%x1f%s"

    private let runner: GitCommandRunner

    public init(runner: GitCommandRunner = GitCommandRunner()) {
        self.runner = runner
    }

    public func loadProject(at rootURL: URL) async throws -> GitProjectSnapshot {
        let project = GitProject(rootURL: rootURL)
        let worktreeData = try await runner.run(
            arguments: ["worktree", "list", "--porcelain", "-z"],
            workingDirectory: project.rootURL
        )
        let worktrees = try WorktreeListParser.parse(worktreeData)
            .filter { !$0.isBare }

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
        let data = try await runner.run(arguments: arguments, workingDirectory: worktree.rootURL)
        return try UnifiedDiffParser.parse(data, change: change, scope: scope)
    }

    public func loadDiffs(
        worktree: GitWorktree,
        changes: [GitFileChange],
        scope: GitDiffScope,
        options: GitDiffOptions = GitDiffOptions()
    ) async throws -> [GitFileDiff] {
        let batchChanges = changes.filter {
            !$0.isUntracked && !(scope == .working && $0.kind == .unmerged)
        }
        var diffs: [GitFileDiff] = []

        if !batchChanges.isEmpty {
            var arguments = [
                "-c", "core.quotePath=false",
                "diff"
            ]
            if scope == .staged {
                arguments.append("--cached")
            }
            arguments.append(contentsOf: ["--no-ext-diff", "--no-color"])
            arguments.append(contentsOf: options.arguments)
            arguments.append("--find-renames")
            let data = try await runner.run(
                arguments: arguments,
                workingDirectory: worktree.rootURL
            )
            diffs.append(contentsOf: try UnifiedDiffParser.parseFiles(
                data,
                changes: batchChanges,
                scope: scope
            ))
        }

        let batchChangeIDs = Set(batchChanges.map(\.id))
        for change in changes where !batchChangeIDs.contains(change.id) {
            diffs.append(
                try await loadDiff(
                    worktree: worktree,
                    change: change,
                    scope: scope,
                    options: options
                )
            )
        }

        let diffsByChangeID = Dictionary(uniqueKeysWithValues: diffs.map { ($0.change.id, $0) })
        return changes.compactMap { diffsByChangeID[$0.id] }
    }

    public func loadHistory(
        worktree: GitWorktree,
        limit: Int = 200
    ) async throws -> [GitCommit] {
        guard !worktree.isUnborn else {
            return []
        }

        let data = try await runner.run(
            arguments: [
                "--no-optional-locks",
                "log",
                "-z",
                "--format=\(Self.historyFormat)",
                "--max-count=\(limit)"
            ],
            workingDirectory: worktree.rootURL
        )
        return try GitLogParser.parse(data)
    }

    public func loadCommitMessage(
        worktree: GitWorktree,
        commit: GitCommit
    ) async throws -> String {
        let data = try await runner.run(
            arguments: [
                "--no-optional-locks",
                "show",
                "-s",
                "--format=%B",
                commit.oid
            ],
            workingDirectory: worktree.rootURL
        )
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func loadCommitChanges(
        worktree: GitWorktree,
        commit: GitCommit
    ) async throws -> [GitFileChange] {
        let data = try await runner.run(
            arguments: [
                "-c", "core.quotePath=false",
                "--no-optional-locks",
                "show",
                "--format=",
                "--name-status",
                "-z",
                "--find-renames",
                "--diff-merges=first-parent",
                commit.oid
            ],
            workingDirectory: worktree.rootURL
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
            "--no-optional-locks",
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
        let data = try await runner.run(arguments: arguments, workingDirectory: worktree.rootURL)
        return try UnifiedDiffParser.parse(data, change: change, scope: .staged)
    }

    public func loadCommitDiffs(
        worktree: GitWorktree,
        commit: GitCommit,
        changes: [GitFileChange],
        options: GitDiffOptions = GitDiffOptions()
    ) async throws -> [GitFileDiff] {
        let data = try await runner.run(
            arguments: [
                "-c", "core.quotePath=false",
                "--no-optional-locks",
                "show",
                "--format=",
                "--no-ext-diff",
                "--no-color"
            ] + options.arguments + [
                "--find-renames",
                "--diff-merges=first-parent",
                commit.oid
            ],
            workingDirectory: worktree.rootURL
        )
        return try UnifiedDiffParser.parseFiles(data, changes: changes, scope: .staged)
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
                "--no-optional-locks",
                "diff",
                "--name-status",
                "-z",
                "--find-renames",
                "\(baseOID)..\(headOID)"
            ],
            workingDirectory: worktree.rootURL
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
        let data = try await runner.run(
            arguments: [
                "-c", "core.quotePath=false",
                "--no-optional-locks",
                "diff",
                "--no-ext-diff",
                "--no-color"
            ] + options.arguments + [
                "--find-renames",
                "\(baseOID)..\(headOID)"
            ],
            workingDirectory: worktree.rootURL
        )
        return try UnifiedDiffParser.parseFiles(data, changes: changes, scope: .staged)
    }

    public func stageFile(worktree: GitWorktree, change: GitFileChange) async throws {
        _ = try await runner.run(
            arguments: ["add", "--", change.path],
            workingDirectory: worktree.rootURL
        )
    }

    public func unstageFile(worktree: GitWorktree, change: GitFileChange) async throws {
        let arguments: [String]
        if worktree.isUnborn {
            arguments = ["rm", "--cached", "--ignore-unmatch", "-q", "--", change.path]
        } else {
            arguments = ["reset", "-q", "HEAD", "--", change.path]
        }
        _ = try await runner.run(arguments: arguments, workingDirectory: worktree.rootURL)
    }

    public func discardFile(worktree: GitWorktree, change: GitFileChange) async throws {
        if change.isUntracked {
            let root = worktree.rootURL.standardizedFileURL
            let target = root.appendingPathComponent(change.path).standardizedFileURL
            guard target.path.hasPrefix(root.path + "/") else {
                throw GitMutationError.pathOutsideWorktree
            }
            try FileManager.default.removeItem(at: target)
            return
        }
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
        arguments.append("-")
        _ = try await runner.run(
            arguments: arguments,
            workingDirectory: worktree.rootURL,
            standardInput: try GitPatchSelectionBuilder.patch(
                for: diff,
                selectedLineIDs: selectedLineIDs,
                treatsUntrackedAsNewFile: action != .discard
            )
        )
    }

    private func loadWorktree(_ worktree: GitWorktree) async -> GitWorktreeSnapshot {
        do {
            let statusData = try await runner.run(
                arguments: [
                    "--no-optional-locks",
                    "status",
                    "--porcelain=v2",
                    "-z",
                    "--branch",
                    "--untracked-files=all"
                ],
                workingDirectory: worktree.rootURL
            )
            let status = try GitStatusParser.parsePorcelainV2(statusData)
            return GitWorktreeSnapshot(
                worktree: worktree,
                status: status,
                diffStat: try await diffStat(for: worktree),
                lastActivityAt: await activityDate(for: worktree, status: status),
                errorMessage: nil
            )
        } catch {
            return GitWorktreeSnapshot(
                worktree: worktree,
                status: .clean,
                diffStat: .zero,
                lastActivityAt: .distantPast,
                errorMessage: String(describing: error)
            )
        }
    }

    /// 相对 HEAD 的改动规模；unborn HEAD 无 diff 基准，改为 staged + working 两段求和。
    private func diffStat(for worktree: GitWorktree) async throws -> GitDiffStat {
        let baseArguments = ["--no-optional-locks", "diff", "--no-ext-diff", "--numstat"]
        guard worktree.isUnborn else {
            let data = try await runner.run(
                arguments: baseArguments + ["HEAD"],
                workingDirectory: worktree.rootURL
            )
            return try GitNumstatParser.parse(data)
        }

        let stagedData = try await runner.run(
            arguments: baseArguments + ["--cached"],
            workingDirectory: worktree.rootURL
        )
        let workingData = try await runner.run(
            arguments: baseArguments,
            workingDirectory: worktree.rootURL
        )
        return try GitNumstatParser.parse(stagedData) + GitNumstatParser.parse(workingData)
    }

    private func activityDate(for worktree: GitWorktree, status: GitStatusSnapshot) async -> Date {
        var dates: [Date] = []

        if let gitDirectory = await absoluteGitDirectory(for: worktree.rootURL) {
            dates.append(contentsOf: [
                modificationDate(at: gitDirectory.appendingPathComponent("HEAD")),
                modificationDate(at: gitDirectory.appendingPathComponent("index")),
                modificationDate(at: gitDirectory.appendingPathComponent("logs/HEAD"))
            ].compactMap { $0 })
        }

        for change in status.changes {
            if let date = modificationDate(
                at: worktree.rootURL.appendingPathComponent(change.path)
            ) {
                dates.append(date)
            }
        }

        if let commitDate = await headCommitDate(for: worktree.rootURL) {
            dates.append(commitDate)
        }

        return dates.max() ?? .distantPast
    }

    private func absoluteGitDirectory(for worktreeURL: URL) async -> URL? {
        guard let data = try? await runner.run(
            arguments: ["rev-parse", "--absolute-git-dir"],
            workingDirectory: worktreeURL
        ) else {
            return nil
        }

        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private func headCommitDate(for worktreeURL: URL) async -> Date? {
        guard let data = try? await runner.run(
            arguments: ["show", "-s", "--format=%cI", "HEAD"],
            workingDirectory: worktreeURL
        ) else {
            return nil
        }

        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ISO8601DateFormatter().date(from: value)
    }

    private func modificationDate(at url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }
}
