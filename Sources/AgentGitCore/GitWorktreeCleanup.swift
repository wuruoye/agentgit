import Foundation

public enum GitWorktreeCleanupResult: Equatable, Sendable {
    case removed
    case skipped(String)
}

private struct GitWorktreeCleanupTimeout: Error, CustomStringConvertible {
    let operation: String
    var description: String {
        "Timed out after 30 seconds while \(operation). Cleanup stopped for this worktree."
    }
}

/// 自动删除采用比 Review 状态缓存更严格的检查。
public struct GitWorktreeCleanupService: Sendable {
    private let runner: GitCommandRunner
    private let repositoryService: GitRepositoryService

    public init(runner: GitCommandRunner = GitCommandRunner()) {
        self.runner = runner
        self.repositoryService = GitRepositoryService(runner: runner)
    }

    public func removeIfInactive(
        _ worktree: GitWorktree,
        project: GitProject,
        inactiveSince cutoff: Date,
        willRemove: @Sendable () async throws -> Bool = { true },
        isRemovalAllowed: @Sendable () async throws -> Bool = { true }
    ) async throws -> GitWorktreeCleanupResult {
        let members = try await worktrees(at: project.rootURL)
        guard let current = members.first(where: { $0.id == worktree.id }),
              current == worktree,
              members.first?.id != current.id,
              current.rootURL.resolvingSymlinksInPath() != project.rootURL.resolvingSymlinksInPath(),
              !current.isBare, !current.isUnborn,
              current.lockedReason == nil, current.prunableReason == nil else {
            return .skipped("Protected or changed worktree")
        }

        let gitDirectoryData = try await run(
            ["rev-parse", "--absolute-git-dir"], at: current.rootURL
        )
        guard let gitDirectoryPath = String(data: gitDirectoryData, encoding: .utf8),
              gitDirectoryPath.hasPrefix("/"), gitDirectoryPath.hasSuffix("\n") else {
            return .skipped("Git directory is unavailable")
        }
        let gitDirectory = URL(fileURLWithPath: String(gitDirectoryPath.dropLast()))
        if hasOperationInProgress(at: gitDirectory) {
            return .skipped("Git operation in progress")
        }
        guard try await isInactive(current, since: cutoff) else {
            return .skipped("Recently active or activity time is unavailable")
        }
        // 移除 worktree 的 HEAD 后，detached 提交必须仍有其他引用保留。
        guard try await hasRetainingRef(for: current) else {
            return .skipped("HEAD is not retained by a branch or tag")
        }
        guard try await isClean(at: current.rootURL) else {
            return .skipped("Contains local files or changes")
        }

        // 隐藏本地改动的 index 标记直接跳过，不使用干净文件的时间增加闲置条件。
        let files = try await run(["ls-files", "-v", "-z"], at: current.rootURL)
        for record in files.split(separator: 0) {
            guard record.starts(with: [UInt8(ascii: "H"), UInt8(ascii: " ")]),
                  let path = String(data: record.dropFirst(2), encoding: .utf8) else {
                return .skipped("Index flags or paths cannot be verified")
            }
            let url = current.rootURL.appendingPathComponent(path)
            // gitlink 指向另一个仓库，自动清理保留整个 worktree。
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if attributes[.type] as? FileAttributeType == .typeDirectory {
                return .skipped("Contains a submodule or nested repository")
            }
        }

        guard try await willRemove() else {
            return .skipped("Worktree is in use")
        }
        // 调用方阻止目标上的界面操作后，再次读取 Git 与文件状态。
        guard try await worktrees(at: project.rootURL).first(where: { $0.id == current.id }) == current,
              !hasOperationInProgress(at: gitDirectory),
              try await hasRetainingRef(for: current),
              try await run(["ls-files", "-v", "-z"], at: current.rootURL) == files,
              try await isInactive(current, since: cutoff),
              try await isClean(at: current.rootURL) else {
            return .skipped("Worktree changed during cleanup")
        }
        try Task.checkCancellation()
        // Git 复核可能耗时；执行删除前再次读取用户的最新排除设置。
        guard try await isRemovalAllowed() else {
            return .skipped("Worktree is excluded or in use")
        }
        _ = try await run(["worktree", "remove", "--", current.rootURL.path], at: project.rootURL)
        guard !FileManager.default.fileExists(atPath: current.rootURL.path),
              try await !worktrees(at: project.rootURL).contains(where: { $0.id == current.id }) else {
            return .skipped("Removal could not be verified")
        }
        return .removed
    }

    private func worktrees(at url: URL) async throws -> [GitWorktree] {
        try WorktreeListParser.parse(await run(["worktree", "list", "--porcelain", "-z"], at: url))
    }

    private func isClean(at url: URL) async throws -> Bool {
        try await run([
            "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
            "status", "--porcelain=v1", "-z", "--untracked-files=all",
            "--ignore-submodules=none"
        ], at: url).isEmpty
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
        return try await !run(
            ["for-each-ref", "--contains=HEAD", "--format=%(refname)", "refs/heads", "refs/tags", "refs/remotes"],
            at: worktree.rootURL
        ).isEmpty
    }

    private func isInactive(_ worktree: GitWorktree, since cutoff: Date) async throws -> Bool {
        let activityDate = try await repositoryService.loadActivityDate(for: worktree)
        return activityDate != .distantPast && activityDate < cutoff
    }

    private func hasOperationInProgress(at url: URL) -> Bool {
        ["index.lock", "HEAD.lock", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD",
         "rebase-merge", "rebase-apply", "sequencer", "BISECT_START"].contains {
            FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }

    private func run(_ arguments: [String], at url: URL) async throws -> Data {
        do {
            return try await runner.run(
                arguments: arguments,
                workingDirectory: url,
                maximumOutputBytes: 8 * 1_024 * 1_024,
                maximumErrorBytes: 64 * 1_024,
                timeout: .seconds(30)
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
            throw GitWorktreeCleanupTimeout(operation: operation)
        }
    }
}
