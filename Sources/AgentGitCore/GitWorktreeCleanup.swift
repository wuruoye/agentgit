import Foundation

public enum GitWorktreeCleanupResult: Equatable, Sendable {
    case removed
    case skipped(String)
}

private struct GitWorktreeCleanupTimeout: LocalizedError, CustomStringConvertible {
    let operation: String
    let seconds: Int
    var errorDescription: String? { description }
    var description: String {
        "Timed out after \(seconds) seconds while \(operation). Cleanup stopped for this worktree."
    }
}

/// 自动删除前重新读取 Git 状态和 worktree 成员。
public struct GitWorktreeCleanupService: Sendable {
    private let runner: GitCommandRunner
    private let repositoryService: GitRepositoryService
    private let diagnostics: AgentGitDiagnostics

    public init(runner: GitCommandRunner = GitCommandRunner()) {
        self.runner = runner
        self.repositoryService = GitRepositoryService(runner: runner)
        self.diagnostics = runner.diagnostics
    }

    public func removeIfInactive(
        _ worktree: GitWorktree,
        project: GitProject,
        inactiveSince cutoff: Date,
        willRemove: @Sendable () async throws -> Bool = { true },
        isRemovalAllowed: @Sendable () async throws -> Bool = { true }
    ) async throws -> GitWorktreeCleanupResult {
        var stage = "members"
        func record(_ event: String, fields: [String: String] = [:]) {
            diagnostics.record("cleanup.worktree.\(event)", fields: fields.merging([
                "project": project.rootURL.path, "worktree": worktree.rootURL.path, "stage": stage
            ]) { value, _ in value })
        }
        func skip(_ reason: String) -> GitWorktreeCleanupResult {
            record("skipped", fields: ["reason": reason])
            return .skipped(reason)
        }
        record("start", fields: [
            "head": worktree.headOID ?? "unborn", "branch": worktree.branchRef ?? "detached",
            "cutoff": cutoff.ISO8601Format(), "locked": worktree.lockedReason ?? "",
            "prunable": worktree.prunableReason ?? ""
        ])
        defer { record("finish") }
        let members = try await worktrees(at: project.rootURL)
        guard let current = members.first(where: { $0.id == worktree.id }),
              current == worktree,
              members.first?.id != current.id,
              current.rootURL.resolvingSymlinksInPath() != project.rootURL.resolvingSymlinksInPath(),
              !current.isBare, !current.isUnborn,
              current.lockedReason == nil, current.prunableReason == nil else {
            return skip("Protected or changed worktree")
        }

        stage = "git_directory"
        record("check")
        let gitDirectoryData = try await run(
            ["rev-parse", "--absolute-git-dir"], at: current.rootURL
        )
        guard let gitDirectoryPath = String(data: gitDirectoryData, encoding: .utf8),
              gitDirectoryPath.hasPrefix("/"), gitDirectoryPath.hasSuffix("\n") else {
            return skip("Git directory is unavailable")
        }
        let gitDirectory = URL(fileURLWithPath: String(gitDirectoryPath.dropLast()))
        record("metadata", fields: ["gitDirectory": gitDirectory.path])
        if hasOperationInProgress(at: gitDirectory) {
            return skip("Git operation in progress")
        }
        stage = "local_changes"
        record("check")
        guard try await isClean(at: current.rootURL) else {
            return skip("Contains local files or changes")
        }
        stage = "inactivity"
        record("check")
        guard try await isInactive(current, since: cutoff) else {
            return skip("Recently active or activity time is unavailable")
        }
        // 移除 worktree 的 HEAD 后，detached 提交必须仍有其他引用保留。
        stage = "retaining_ref"
        record("check")
        guard try await hasRetainingRef(for: current) else {
            return skip("HEAD is not retained by a branch or tag")
        }
        // 已初始化子模块需要单次 --force；仍须通过同样的状态和目录保护检查。
        stage = "submodule_repositories"
        let modules = gitDirectory.appendingPathComponent("modules", isDirectory: true)
        var isDirectory: ObjCBool = false
        let forceForSubmodules = FileManager.default.fileExists(
            atPath: modules.path, isDirectory: &isDirectory
        ) && isDirectory.boolValue
        record("metadata", fields: [
            "submoduleRepositories": modules.path, "forceForSubmodules": String(forceForSubmodules)
        ])
        // 删除前核对 index 清单是否变化；是否存在本地改动以 Git 状态为准。
        stage = "index_snapshot"
        record("check")
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentGit-Cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let files = temporaryDirectory.appendingPathComponent("tracked-files")
        _ = try await run(["ls-files", "-v", "-z"], at: current.rootURL, standardOutputFile: files)

        stage = "reserve_worktree"
        record("check")
        guard try await willRemove() else {
            return skip("Worktree is in use")
        }
        // 调用方阻止目标上的界面操作后，再次读取 Git 与文件状态。
        stage = "recheck_members_and_refs"
        record("check")
        guard try await worktrees(at: project.rootURL).first(where: { $0.id == current.id }) == current,
              !hasOperationInProgress(at: gitDirectory),
              try await hasRetainingRef(for: current) else {
            return skip("Worktree changed during cleanup")
        }
        stage = "recheck_index_activity_and_status"
        record("check")
        let recheckedFiles = temporaryDirectory.appendingPathComponent("rechecked-tracked-files")
        _ = try await run(["ls-files", "-v", "-z"], at: current.rootURL, standardOutputFile: recheckedFiles)
        guard try filesMatch(files, recheckedFiles),
              try await isInactive(current, since: cutoff),
              try await isClean(at: current.rootURL) else {
            return skip("Worktree changed during cleanup")
        }
        try Task.checkCancellation()
        // Git 复核可能耗时；执行删除前再次读取用户的最新排除设置。
        stage = "removal_allowed"
        record("check")
        guard try await isRemovalAllowed() else {
            return skip("Worktree is excluded or in use")
        }
        if forceForSubmodules {
            stage = "final_status"
            record("check")
            guard !hasOperationInProgress(at: gitDirectory),
                  try await isClean(at: current.rootURL) else {
                return skip("Worktree changed during cleanup")
            }
            guard try await isRemovalAllowed() else {
                return skip("Worktree is excluded or in use")
            }
        }
        stage = "remove"
        record("check", fields: ["forceForSubmodules": String(forceForSubmodules)])
        do {
            _ = try await run(
                ["worktree", "remove"] + (forceForSubmodules ? ["--force"] : [])
                    + ["--", current.rootURL.path],
                at: project.rootURL
            )
        } catch let failure as GitCommandFailure
            where !forceForSubmodules
                && failure.stderr.contains("working trees containing submodules cannot be moved or removed") {
            // 独立 .git 目录形式的子模块也可能需要 --force，重新检查后仅重试一次。
            stage = "force_recheck"
            record("check", fields: ["reason": "Git requires forced removal for initialized submodules"])
            guard try await worktrees(at: project.rootURL).first(where: { $0.id == current.id }) == current,
                  !hasOperationInProgress(at: gitDirectory),
                  try await hasRetainingRef(for: current),
                  try await isInactive(current, since: cutoff) else {
                return skip("Worktree changed during cleanup")
            }
            let forceRecheckedFiles = temporaryDirectory.appendingPathComponent("force-rechecked-tracked-files")
            _ = try await run(
                ["ls-files", "-v", "-z"], at: current.rootURL, standardOutputFile: forceRecheckedFiles
            )
            guard try filesMatch(files, forceRecheckedFiles),
                  try await isClean(at: current.rootURL) else {
                return skip("Worktree changed during cleanup")
            }
            try Task.checkCancellation()
            guard try await isRemovalAllowed() else {
                return skip("Worktree is excluded or in use")
            }
            stage = "remove"
            record("check", fields: ["forceForSubmodules": "true", "retry": "true"])
            _ = try await run(
                ["worktree", "remove", "--force", "--", current.rootURL.path], at: project.rootURL
            )
        }
        stage = "verify_removal"
        record("check")
        guard !FileManager.default.fileExists(atPath: current.rootURL.path),
              try await !worktrees(at: project.rootURL).contains(where: { $0.id == current.id }) else {
            return skip("Removal could not be verified")
        }
        record("removed")
        return .removed
    }

    private func filesMatch(_ original: URL, _ current: URL) throws -> Bool {
        let originalHandle = try FileHandle(forReadingFrom: original)
        defer { try? originalHandle.close() }
        let currentHandle = try FileHandle(forReadingFrom: current)
        defer { try? currentHandle.close() }
        while true {
            try Task.checkCancellation()
            let originalChunk = try originalHandle.read(upToCount: 64 * 1_024) ?? Data()
            let currentChunk = try currentHandle.read(upToCount: 64 * 1_024) ?? Data()
            guard originalChunk == currentChunk else { return false }
            if originalChunk.isEmpty { return true }
        }
    }

    private func worktrees(at url: URL) async throws -> [GitWorktree] {
        try WorktreeListParser.parse(await run(["worktree", "list", "--porcelain", "-z"], at: url))
    }

    private func isClean(at url: URL) async throws -> Bool {
        do {
            _ = try await run([
                "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
                "status", "--porcelain=v1", "-z", "--untracked-files=all",
                "--ignore-submodules=none"
            ], at: url, maximumOutputBytes: 0)
            diagnostics.record("cleanup.status", fields: ["worktree": url.path, "clean": "true"])
            return true
        } catch let output as GitCommandOutputLimitError {
            // 预检只需确认有无改动；持续排空输出，不在内存里保留文件清单。
            diagnostics.record("cleanup.status", fields: [
                "worktree": url.path, "clean": "false", "statusBytes": String(output.actualByteCount)
            ])
            return false
        }
    }

    private func hasRetainingRef(for worktree: GitWorktree) async throws -> Bool {
        // 普通分支本身就保留 HEAD，无需遍历其他分支及其提交历史。
        if !worktree.isDetached, let branchRef = worktree.branchRef,
           branchRef.hasPrefix("refs/heads/") {
            let oid = try await run(
                ["rev-parse", "--verify", "\(branchRef)^{commit}"], at: worktree.rootURL
            )
            return String(data: oid, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) == worktree.headOID
        }
        // detached HEAD 常直接对应分支或标签，先做无需遍历提交历史的检查。
        let refPrefixes = ["refs/heads", "refs/tags", "refs/remotes"]
        if try await !run(
            ["for-each-ref", "--points-at=HEAD", "--count=1", "--format=%(refname)"] + refPrefixes,
            at: worktree.rootURL
        ).isEmpty {
            return true
        }
        // 只需找到一个保留 HEAD 的引用；Git 可在命中后停止遍历。
        return try await !run(
            ["for-each-ref", "--contains=HEAD", "--count=1", "--format=%(refname)"] + refPrefixes,
            at: worktree.rootURL
        ).isEmpty
    }

    private func isInactive(_ worktree: GitWorktree, since cutoff: Date) async throws -> Bool {
        let activityDate = try await repositoryService.loadActivityDate(for: worktree)
        diagnostics.record("cleanup.activity", fields: [
            "worktree": worktree.rootURL.path, "lastActivityAt": activityDate.ISO8601Format(),
            "cutoff": cutoff.ISO8601Format()
        ])
        return activityDate != .distantPast && activityDate < cutoff
    }

    private func hasOperationInProgress(at url: URL) -> Bool {
        ["index.lock", "HEAD.lock", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD",
         "rebase-merge", "rebase-apply", "sequencer", "BISECT_START"].contains {
            FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }

    private func run(
        _ arguments: [String], at url: URL,
        maximumOutputBytes: Int? = 8 * 1_024 * 1_024,
        standardOutputFile: URL? = nil
    ) async throws -> Data {
        // 大目录移除可能需要逐个删除大量文件；预检仍保持较短的时限。
        let timeoutSeconds = arguments.starts(with: ["worktree", "remove"]) ? 300 : 30
        do {
            return try await runner.run(
                arguments: arguments,
                workingDirectory: url,
                maximumOutputBytes: standardOutputFile == nil ? maximumOutputBytes : nil,
                maximumErrorBytes: 64 * 1_024,
                // partial clone 的引用检查可能下载缺失对象；清理预检仅使用本地对象。
                environment: ["GIT_NO_LAZY_FETCH": "1", "LC_ALL": "C"],
                timeout: .seconds(timeoutSeconds),
                standardOutputFile: standardOutputFile
            )
        } catch is GitCommandTimeoutError {
            let operation: String
            if arguments.contains("status") {
                operation = "checking local changes and untracked files"
            } else if arguments.first == "for-each-ref" || arguments.contains("--verify") {
                operation = "checking references that retain HEAD"
            } else if arguments.first == "ls-files" {
                operation = "reading tracked files"
            } else if arguments.starts(with: ["worktree", "remove"]) {
                operation = "removing the worktree"
            } else {
                operation = "reading worktree metadata"
            }
            throw GitWorktreeCleanupTimeout(operation: operation, seconds: timeoutSeconds)
        }
    }
}
