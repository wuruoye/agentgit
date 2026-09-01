import Foundation
import XCTest
@testable import AgentGitCore

final class GitRepositoryServiceTests: XCTestCase {
    func testLoadsCommitTreeAndAuthorEmailForSummary() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-commit-metadata-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        defer { try? FileManager.default.removeItem(at: container) }
        try await makeRepository(at: repository)

        let runner = GitCommandRunner()
        let service = GitRepositoryService(runner: runner)
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first?.worktree)
        let history = try await service.loadHistory(worktree: worktree)
        let commit = try XCTUnwrap(history.first)
        XCTAssertEqual(commit.changedFileCount, 1)
        let metadata = try await service.loadCommitMetadata(
            worktree: worktree,
            commit: commit
        )
        let expectedTree = try await revision("HEAD^{tree}", in: repository, using: runner)

        XCTAssertEqual(metadata.treeOID, expectedTree)
        XCTAssertEqual(metadata.authorEmail, "agentgit-tests@example.invalid")
    }

    func testMixedEncodingDiffKeepsOtherFilesReviewableInEveryContext() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-mixed-encoding-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        defer { try? FileManager.default.removeItem(at: container) }
        try await makeRepository(at: repository)
        let runner = GitCommandRunner()
        let normalURL = repository.appendingPathComponent("normal.txt")
        let legacyURL = repository.appendingPathComponent("legacy.txt")
        try Data("before\n".utf8).write(to: normalURL)
        try Data([0x63, 0x61, 0x66, 0xE9, 0x0A]).write(to: legacyURL)
        _ = try await runner.run(
            arguments: ["add", "normal.txt", "legacy.txt"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["commit", "-m", "Add text fixtures"],
            workingDirectory: repository
        )
        let baseOID = try await revision("HEAD", in: repository, using: runner)

        try Data("after\n".utf8).write(to: normalURL)
        try Data([0x63, 0x61, 0x66, 0xE8, 0x0A]).write(to: legacyURL)

        let service = GitRepositoryService(runner: runner)
        let workingProject = try await service.loadProject(at: repository)
        let workingSnapshot = try XCTUnwrap(workingProject.worktrees.first)
        let workingChanges = workingSnapshot.status.changes.filter(\.isUnstaged)
        let workingDiffs = try await service.loadDiffs(
            worktree: workingSnapshot.worktree,
            changes: workingChanges,
            scope: .working
        )
        assertMixedEncodingDiffs(
            workingDiffs,
            expectedScope: .working
        )
        let legacyWorkingChange = try XCTUnwrap(
            workingChanges.first(where: { $0.path == "legacy.txt" })
        )
        let individualWorkingDiff = try await service.loadDiff(
            worktree: workingSnapshot.worktree,
            change: legacyWorkingChange,
            scope: .working
        )
        assertUnsupportedEncoding(individualWorkingDiff, expectedScope: .working)

        _ = try await runner.run(
            arguments: ["add", "normal.txt", "legacy.txt"],
            workingDirectory: repository
        )
        let stagedProject = try await service.loadProject(at: repository)
        let stagedSnapshot = try XCTUnwrap(stagedProject.worktrees.first)
        let stagedChanges = stagedSnapshot.status.changes.filter(\.isStaged)
        let stagedDiffs = try await service.loadDiffs(
            worktree: stagedSnapshot.worktree,
            changes: stagedChanges,
            scope: .staged
        )
        assertMixedEncodingDiffs(stagedDiffs, expectedScope: .staged)

        _ = try await runner.run(
            arguments: ["commit", "-m", "Update mixed encodings"],
            workingDirectory: repository
        )
        let headOID = try await revision("HEAD", in: repository, using: runner)
        let committedProject = try await service.loadProject(at: repository)
        let committedWorktree = try XCTUnwrap(committedProject.worktrees.first?.worktree)
        let history = try await service.loadHistoryPage(
            worktree: committedWorktree,
            revision: headOID,
            offset: 0,
            pageSize: 20
        )
        let commit = try XCTUnwrap(history.commits.first)
        let commitChanges = try await service.loadCommitChanges(
            worktree: committedWorktree,
            commit: commit
        )
        let commitDiffs = try await service.loadCommitDiffs(
            worktree: committedWorktree,
            commit: commit,
            changes: commitChanges
        )
        assertMixedEncodingDiffs(commitDiffs, expectedScope: .staged)

        let rangeChanges = try await service.loadRangeChanges(
            worktree: committedWorktree,
            baseOID: baseOID,
            headOID: headOID
        )
        let rangeDiffs = try await service.loadRangeDiffs(
            worktree: committedWorktree,
            baseOID: baseOID,
            headOID: headOID,
            changes: rangeChanges
        )
        assertMixedEncodingDiffs(rangeDiffs, expectedScope: .staged)
    }

    func testHistoryPaginationRejectsInvalidArgumentsWithoutTerminating() async throws {
        let worktree = GitWorktree(
            rootURL: FileManager.default.temporaryDirectory,
            headOID: String(repeating: "a", count: 40),
            branchRef: "refs/heads/main",
            isBare: false,
            isDetached: false,
            lockedReason: nil,
            prunableReason: nil
        )
        let service = GitRepositoryService()

        do {
            _ = try await service.loadHistoryPage(
                worktree: worktree,
                revision: nil,
                offset: -1,
                pageSize: 200
            )
            XCTFail("Expected a negative history offset to fail")
        } catch let error as GitHistoryLoadError {
            XCTAssertEqual(error, .invalidOffset(-1))
        }
        let query = try XCTUnwrap(GitHistorySearchQuery("message"))
        do {
            _ = try await service.searchHistoryPage(
                worktree: worktree,
                revision: nil,
                query: query,
                offset: 0,
                pageSize: 0
            )
            XCTFail("Expected an empty history page to fail")
        } catch let error as GitHistoryLoadError {
            XCTAssertEqual(error, .invalidPageSize(0))
        }
    }

    func testChecksSavedCommitReachabilityAgainstPinnedHistory() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agentgit-history-reachability-\(UUID().uuidString)"
            )
        let repository = container.appendingPathComponent("repository")
        defer { try? FileManager.default.removeItem(at: container) }
        try await makeRepository(at: repository)
        let runner = GitCommandRunner()
        _ = try await runner.run(
            arguments: ["commit", "--allow-empty", "-m", "Root"],
            workingDirectory: repository
        )
        let rootOID = try await revision("HEAD", in: repository, using: runner)
        _ = try await runner.run(
            arguments: ["commit", "--allow-empty", "-m", "Head"],
            workingDirectory: repository
        )
        let headOID = try await revision("HEAD", in: repository, using: runner)
        let service = GitRepositoryService()
        let mainProject = try await service.loadProject(at: repository)
        let mainWorktree = try XCTUnwrap(mainProject.worktrees.first?.worktree)

        let mainContainsCommits = try await service.historyContainsCommits(
            worktree: mainWorktree,
            revision: headOID,
            commitIDs: [rootOID, headOID]
        )
        XCTAssertTrue(mainContainsCommits)
        let acceptsInvalidCommit = try await service.historyContainsCommits(
            worktree: mainWorktree,
            revision: headOID,
            commitIDs: ["invalid"]
        )
        XCTAssertFalse(acceptsInvalidCommit)

        _ = try await runner.run(
            arguments: ["checkout", "--orphan", "unrelated"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["commit", "--allow-empty", "-m", "Unrelated"],
            workingDirectory: repository
        )
        let unrelatedOID = try await revision(
            "HEAD",
            in: repository,
            using: runner
        )
        let unrelatedProject = try await service.loadProject(at: repository)
        let unrelatedWorktree = try XCTUnwrap(
            unrelatedProject.worktrees.first?.worktree
        )

        let unrelatedContainsRoot = try await service.historyContainsCommits(
            worktree: unrelatedWorktree,
            revision: unrelatedOID,
            commitIDs: [rootOID]
        )
        XCTAssertFalse(unrelatedContainsRoot)
    }

    func testCommitMessageOutputIsBoundedInRealRepository() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-large-message-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        let messageURL = container.appendingPathComponent("message.txt")
        defer { try? FileManager.default.removeItem(at: container) }
        try await makeRepository(at: repository)
        var message = Data("Large body\n\n".utf8)
        message.append(Data(repeating: 0x61, count: 3 * 1_024 * 1_024))
        try message.write(to: messageURL)
        let runner = GitCommandRunner()
        _ = try await runner.run(
            arguments: ["commit", "--allow-empty", "-F", messageURL.path],
            workingDirectory: repository
        )
        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first)
        let history = try await service.loadHistory(worktree: worktree.worktree)
        let commit = try XCTUnwrap(history.first)

        do {
            _ = try await service.loadCommitMessage(
                worktree: worktree.worktree,
                commit: commit
            )
            XCTFail("Expected a very large commit message to be bounded")
        } catch let error as GitCommandOutputLimitError {
            XCTAssertGreaterThan(error.actualByteCount, error.limit)
        }
    }

    func testHistoryOutputIsBoundedInRealRepository() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-large-history-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        let messageURL = container.appendingPathComponent("message.txt")
        defer { try? FileManager.default.removeItem(at: container) }
        try await makeRepository(at: repository)
        try Data(repeating: 0x62, count: 9 * 1_024 * 1_024).write(to: messageURL)
        let runner = GitCommandRunner()
        _ = try await runner.run(
            arguments: ["commit", "--allow-empty", "-F", messageURL.path],
            workingDirectory: repository
        )
        let project = try await GitRepositoryService().loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first)

        do {
            _ = try await GitRepositoryService().loadHistoryPage(
                worktree: worktree.worktree,
                revision: worktree.worktree.headOID,
                offset: 0,
                pageSize: 200
            )
            XCTFail("Expected an oversized history page to be bounded")
        } catch let error as GitCommandOutputLimitError {
            XCTAssertGreaterThan(error.actualByteCount, error.limit)
        }
    }

    /// 三个 diff 选项都只是 git 参数，必须验证 git 的实际输出确实变了。
    func testDiffOptionsChangeContextAndWhitespaceHandling() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-options-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: container)
        }

        let runner = GitCommandRunner()
        _ = try await runner.run(arguments: ["init", "-b", "main"], workingDirectory: container)
        _ = try await runner.run(
            arguments: ["config", "user.name", "AgentGit Tests"],
            workingDirectory: container
        )
        _ = try await runner.run(
            arguments: ["config", "user.email", "agentgit-tests@example.invalid"],
            workingDirectory: container
        )

        let file = container.appendingPathComponent("sample.txt")
        let baseLines = (1...40).map { "line \($0)" }
        try Data(baseLines.joined(separator: "\n").appending("\n").utf8).write(to: file)
        _ = try await runner.run(arguments: ["add", "."], workingDirectory: container)
        _ = try await runner.run(
            arguments: ["commit", "-m", "base"],
            workingDirectory: container
        )

        var editedLines = baseLines
        editedLines[19] = "line 20 changed"
        try Data(editedLines.joined(separator: "\n").appending("\n").utf8).write(to: file)

        let service = GitRepositoryService(runner: runner)
        let worktree = GitWorktree(
            rootURL: container,
            headOID: nil,
            branchRef: "refs/heads/main",
            isBare: false,
            isDetached: false,
            lockedReason: nil,
            prunableReason: nil
        )
        let change = GitFileChange(
            path: "sample.txt",
            originalPath: nil,
            indexStatus: ".",
            worktreeStatus: "M",
            kind: .ordinary
        )

        let compact = try await service.loadDiff(
            worktree: worktree,
            change: change,
            scope: .working,
            options: GitDiffOptions(context: .lines(1))
        )
        let wide = try await service.loadDiff(
            worktree: worktree,
            change: change,
            scope: .working,
            options: GitDiffOptions(context: .lines(10))
        )
        let whole = try await service.loadDiff(
            worktree: worktree,
            change: change,
            scope: .working,
            options: GitDiffOptions(context: .wholeFile)
        )

        func lineCount(_ diff: GitFileDiff) -> Int {
            diff.hunks.reduce(0) { $0 + $1.lines.count }
        }

        XCTAssertLessThan(lineCount(compact), lineCount(wide))
        XCTAssertLessThan(lineCount(wide), lineCount(whole))
        XCTAssertEqual(lineCount(whole), 41, "整文件应覆盖全部行（40 行上下文 + 1 行新增）")

        // 只改缩进：忽略空白后应当没有可显示的 hunk
        let indented = baseLines.map { "    " + $0 }
        try Data(indented.joined(separator: "\n").appending("\n").utf8).write(to: file)

        let withWhitespace = try await service.loadDiff(
            worktree: worktree,
            change: change,
            scope: .working,
            options: GitDiffOptions(ignoresWhitespace: false)
        )
        let ignoringWhitespace = try await service.loadDiff(
            worktree: worktree,
            change: change,
            scope: .working,
            options: GitDiffOptions(ignoresWhitespace: true)
        )

        XCTAssertFalse(withWhitespace.hunks.isEmpty)
        XCTAssertTrue(ignoringWhitespace.hunks.isEmpty)
    }

    func testLoadsWholeFileForCommitRange() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-range-whole-file-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        let lines = (1...30).map { "line \($0)" }
        try await makeRepository(
            at: repository,
            initialContents: lines.joined(separator: "\n") + "\n"
        )
        let runner = GitCommandRunner()
        let baseOID = String(
            decoding: try await runner.run(
                arguments: ["rev-parse", "HEAD"],
                workingDirectory: repository
            ),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        var changedLines = lines
        changedLines[14] = "line 15 changed"
        try Data((changedLines.joined(separator: "\n") + "\n").utf8).write(
            to: repository.appendingPathComponent("README.md")
        )
        _ = try await runner.run(arguments: ["add", "README.md"], workingDirectory: repository)
        _ = try await runner.run(
            arguments: ["commit", "-m", "Change middle line"],
            workingDirectory: repository
        )
        let headOID = String(
            decoding: try await runner.run(
                arguments: ["rev-parse", "HEAD"],
                workingDirectory: repository
            ),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first?.worktree)
        let changes = try await service.loadRangeChanges(
            worktree: worktree,
            baseOID: baseOID,
            headOID: headOID
        )
        let change = try XCTUnwrap(changes.first)
        let diff = try await service.loadRangeDiff(
            worktree: worktree,
            baseOID: baseOID,
            headOID: headOID,
            change: change,
            options: GitDiffOptions(context: .wholeFile)
        )

        XCTAssertEqual(diff.hunks.flatMap(\.lines).count, 31)
    }

    func testDiscardRestoresSubmoduleRecordedCommit() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-submodule-discard-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        let submoduleSource = container.appendingPathComponent("submodule-source")
        let submodulePath = repository.appendingPathComponent("Modules/Shared")
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        try await makeRepository(at: repository)
        try await makeRepository(at: submoduleSource, initialContents: "submodule base\n")
        let runner = GitCommandRunner()
        _ = try await runner.run(
            arguments: [
                "-c", "protocol.file.allow=always",
                "submodule", "add", submoduleSource.path, "Modules/Shared"
            ],
            workingDirectory: repository
        )
        _ = try await runner.run(arguments: ["add", "."], workingDirectory: repository)
        _ = try await runner.run(
            arguments: ["commit", "-m", "Add submodule"],
            workingDirectory: repository
        )
        let recordedOID = String(
            decoding: try await runner.run(
                arguments: ["rev-parse", "HEAD"],
                workingDirectory: submodulePath
            ),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await runner.run(
            arguments: ["config", "user.name", "AgentGit Tests"],
            workingDirectory: submodulePath
        )
        _ = try await runner.run(
            arguments: ["config", "user.email", "agentgit-tests@example.invalid"],
            workingDirectory: submodulePath
        )
        try Data("submodule changed\n".utf8).write(
            to: submodulePath.appendingPathComponent("README.md")
        )
        _ = try await runner.run(arguments: ["add", "README.md"], workingDirectory: submodulePath)
        _ = try await runner.run(
            arguments: ["commit", "-m", "Advance submodule"],
            workingDirectory: submodulePath
        )

        let recoveryRoot = container.appendingPathComponent(
            "recovery",
            isDirectory: true
        )
        let service = GitRepositoryService(
            discardRecoveryStore: GitDiscardRecoveryStore(
                destination: .directory(recoveryRoot)
            )
        )
        var project = try await service.loadProject(at: repository)
        var worktree = try XCTUnwrap(project.worktrees.first)
        let change = try XCTUnwrap(
            worktree.status.changes.first { $0.path == "Modules/Shared" }
        )
        XCTAssertTrue(change.submoduleStatus?.commitChanged == true)

        try await service.discardFile(worktree: worktree.worktree, change: change)

        let restoredOID = String(
            decoding: try await runner.run(
                arguments: ["rev-parse", "HEAD"],
                workingDirectory: submodulePath
            ),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(restoredOID, recordedOID)
        project = try await service.loadProject(at: repository)
        worktree = try XCTUnwrap(project.worktrees.first)
        XCTAssertFalse(worktree.status.changes.contains { $0.path == "Modules/Shared" })

        let submoduleFile = submodulePath.appendingPathComponent("README.md")
        let untrackedFile = submodulePath.appendingPathComponent("untracked.txt")
        try Data("dirty tracked contents\n".utf8).write(to: submoduleFile)
        try Data("dirty untracked contents\n".utf8).write(to: untrackedFile)

        let lightweight = await service.loadWorktree(worktree.worktree)
        XCTAssertFalse(lightweight.status.changes.contains { $0.path == "Modules/Shared" })
        let selected = await service.loadWorktree(
            worktree.worktree,
            submoduleScanMode: .allChanges
        )
        let dirtyChange = try XCTUnwrap(
            selected.status.changes.first { $0.path == "Modules/Shared" }
        )
        XCTAssertTrue(dirtyChange.submoduleStatus?.hasTrackedChanges == true)
        XCTAssertTrue(dirtyChange.submoduleStatus?.hasUntrackedChanges == true)

        try await service.discardFile(worktree: selected.worktree, change: dirtyChange)

        let clean = await service.loadWorktree(
            selected.worktree,
            submoduleScanMode: .allChanges
        )
        XCTAssertFalse(clean.status.changes.contains { $0.path == "Modules/Shared" })
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: submoduleFile), as: UTF8.self),
            "submodule base\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: untrackedFile.path))
        XCTAssertEqual(
            String(
                decoding: try Data(
                    contentsOf: recoveredItem(
                        relativePath: "Modules/Shared/Submodule Recovery/Untracked/untracked.txt",
                        in: recoveryRoot
                    )
                ),
                as: UTF8.self
            ),
            "dirty untracked contents\n"
        )
        let recoveryPatch = String(
            decoding: try Data(
                contentsOf: recoveredItem(
                    relativePath: "Modules/Shared/Submodule Recovery/Changes.patch",
                    in: recoveryRoot
                )
            ),
            as: UTF8.self
        )
        XCTAssertTrue(recoveryPatch.contains("dirty tracked contents"))
    }

    func testSubmoduleDiscardRejectsSymlinkOutsideWorktree() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-submodule-symlink-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        let external = container.appendingPathComponent("external")
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: external,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        let marker = external.appendingPathComponent("keep.txt")
        try Data("keep\n".utf8).write(to: marker)
        try FileManager.default.createSymbolicLink(
            at: repository.appendingPathComponent("linked-submodule"),
            withDestinationURL: external
        )
        let worktree = GitWorktree(
            rootURL: repository,
            headOID: String(repeating: "a", count: 40),
            branchRef: "refs/heads/main",
            isBare: false,
            isDetached: false,
            lockedReason: nil,
            prunableReason: nil
        )
        let change = GitFileChange(
            path: "linked-submodule",
            originalPath: nil,
            indexStatus: ".",
            worktreeStatus: "M",
            kind: .ordinary,
            submoduleStatus: GitSubmoduleStatus(
                commitChanged: false,
                hasTrackedChanges: true,
                hasUntrackedChanges: true
            )
        )

        do {
            try await GitRepositoryService().discardFile(
                worktree: worktree,
                change: change
            )
            XCTFail("Expected an external submodule path to be rejected")
        } catch let error as GitMutationError {
            XCTAssertEqual(error, .pathOutsideWorktree)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    /// 取消必须真的干掉子进程，否则切换上下文时旧命令会一直跑到底。
    func testCancellationTerminatesRunningProcess() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-cancel-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: container)
        }

        // git 本身没有稳定的长时子命令，用 sleep 精确覆盖“进程还在跑时取消”。
        let runner = GitCommandRunner(executableURL: URL(fileURLWithPath: "/bin/sleep"))
        let startedAt = Date()
        let task = Task {
            _ = try await runner.run(arguments: ["30"], workingDirectory: container)
        }

        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled run should not succeed")
        } catch is CancellationError {
            XCTAssertLessThan(
                Date().timeIntervalSince(startedAt),
                5,
                "cancellation should not wait for the child to exit on its own"
            )
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testRunnerUsesConfiguredEnvironmentAndClosedStandardInput() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/runner-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        let runner = GitCommandRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))

        let output = try await runner.run(
            arguments: [
                "-c",
                "read value || printf '%s' \"$AGENTGIT_RUNNER_ENV\""
            ],
            workingDirectory: container,
            environment: ["AGENTGIT_RUNNER_ENV": "configured"]
        )

        XCTAssertEqual(String(decoding: output, as: UTF8.self), "configured")
    }

    func testDiscoversAndSortsLinkedWorktreesByVisibleActivity() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-service-test-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        let featureWorktree = container.appendingPathComponent("feature")
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: container)
        }

        let runner = GitCommandRunner()
        _ = try await runner.run(arguments: ["init", "-b", "main"], workingDirectory: repository)
        _ = try await runner.run(
            arguments: ["config", "user.name", "AgentGit Tests"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["config", "user.email", "agentgit-tests@example.invalid"],
            workingDirectory: repository
        )

        let trackedFile = repository.appendingPathComponent("README.md")
        try Data("base\n".utf8).write(to: trackedFile)
        _ = try await runner.run(arguments: ["add", "README.md"], workingDirectory: repository)
        _ = try await runner.run(
            arguments: ["commit", "-m", "Initial commit"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["worktree", "add", "-b", "feature", featureWorktree.path],
            workingDirectory: repository
        )

        let untrackedDirectory = featureWorktree.appendingPathComponent("Generated")
        try FileManager.default.createDirectory(
            at: untrackedDirectory,
            withIntermediateDirectories: false
        )
        let recentFile = untrackedDirectory.appendingPathComponent("recent.txt")
        try Data("recent\n".utf8).write(to: recentFile)
        let futureDate = Date().addingTimeInterval(3_600)
        try FileManager.default.setAttributes(
            [.modificationDate: futureDate],
            ofItemAtPath: recentFile.path
        )

        let service = GitRepositoryService()
        let resolvedFromPrimary = try await service.resolveProject(at: repository)
        let resolvedFromLinked = try await service.resolveProject(at: featureWorktree)
        let snapshot = try await service.loadProject(at: repository)

        XCTAssertEqual(resolvedFromPrimary.id, repository.standardizedFileURL.path)
        XCTAssertEqual(resolvedFromLinked, resolvedFromPrimary)
        XCTAssertEqual(snapshot.worktrees.count, 2)
        XCTAssertEqual(snapshot.worktrees.first?.worktree.rootURL.path, featureWorktree.path)
        XCTAssertEqual(snapshot.worktrees.first?.status.untrackedFileCount, 1)
        XCTAssertEqual(snapshot.worktrees.first?.status.changes.first?.path, "Generated/recent.txt")
        XCTAssertEqual(snapshot.worktrees.last?.worktree.branchName, "main")
        XCTAssertTrue(
            snapshot.worktrees.allSatisfy { worktree in
                worktree.eventWatchURLs.contains(worktree.worktree.rootURL.standardizedFileURL)
                    && worktree.eventWatchURLs.count >= 2
            }
        )
    }

    func testStatusRefreshAllowsGitToPersistPerformanceCaches() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-locks-test-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        try await makeRepository(at: repository)
        let runner = GitCommandRunner()
        _ = try await runner.run(
            arguments: ["config", "core.untrackedCache", "true"],
            workingDirectory: repository
        )

        try Data("base\nmodified\n".utf8).write(
            to: repository.appendingPathComponent("README.md")
        )
        let indexPath = repository.appendingPathComponent(".git/index").path
        let staleDate = Date(timeIntervalSinceNow: -86_400)
        try FileManager.default.setAttributes(
            [.modificationDate: staleDate],
            ofItemAtPath: indexPath
        )

        _ = try await GitRepositoryService().loadProject(at: repository)

        let attributes = try FileManager.default.attributesOfItem(atPath: indexPath)
        let indexDate = try XCTUnwrap(attributes[.modificationDate] as? Date)
        XCTAssertGreaterThan(indexDate, staleDate)
    }

    func testMissingUpstreamKeepsStatusAndReturnsCompactWarning() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-missing-upstream-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        defer { try? FileManager.default.removeItem(at: container) }
        try await makeRepository(at: repository)
        let runner = GitCommandRunner()
        _ = try await runner.run(
            arguments: ["remote", "add", "origin", container.appendingPathComponent("missing.git").path],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["config", "branch.main.remote", "origin"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["config", "branch.main.merge", "refs/heads/main"],
            workingDirectory: repository
        )

        let project = try await GitRepositoryService().loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first)
        let expected = "Ahead/behind: Upstream origin/main is unavailable."

        XCTAssertTrue(worktree.hasUsableState)
        XCTAssertEqual(worktree.status.branch?.upstreamError, expected)
        XCTAssertEqual(worktree.errorMessage, expected)
        XCTAssertFalse(worktree.errorMessage?.contains("fatal:") == true)
        XCTAssertFalse(worktree.errorMessage?.contains("\n") == true)
    }

    func testActivityIgnoresIndexCacheWritesAndRefreshesHeadOID() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/activity-cache-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        try await makeRepository(at: repository)
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        let service = GitRepositoryService()
        let initial = try await service.loadProject(at: repository)
        let initialWorktree = try XCTUnwrap(initial.worktrees.first?.worktree)
        let runner = GitCommandRunner()

        _ = try await runner.run(
            arguments: ["commit", "--allow-empty", "-m", "Refresh head"],
            workingDirectory: repository
        )
        let futureIndexDate = Date().addingTimeInterval(86_400)
        try FileManager.default.setAttributes(
            [.modificationDate: futureIndexDate],
            ofItemAtPath: repository.appendingPathComponent(".git/index").path
        )

        let refreshed = await service.loadWorktree(initialWorktree)
        let liveHead = String(
            decoding: try await runner.run(
                arguments: ["rev-parse", "HEAD"],
                workingDirectory: repository
            ),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(refreshed.worktree.headOID, liveHead)
        XCTAssertLessThan(refreshed.lastActivityAt, futureIndexDate)
    }

    func testLoadsFullCommitMessage() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-message-test-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        try await makeRepository(at: repository)

        let runner = GitCommandRunner()
        _ = try await runner.run(
            arguments: [
                "commit",
                "--allow-empty",
                "-m", "Explain the history view",
                "-m", "Show the complete body.\n\nKeep paragraph spacing."
            ],
            workingDirectory: repository
        )

        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first?.worktree)
        let history = try await service.loadHistory(worktree: worktree)
        let commit = try XCTUnwrap(history.first)

        let message = try await service.loadCommitMessage(
            worktree: worktree,
            commit: commit
        )

        XCTAssertEqual(
            message,
            "Explain the history view\n\nShow the complete body.\n\nKeep paragraph spacing."
        )
    }

    func testLoadsHistoryPagesAgainstPinnedHeadWithoutDuplicates() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/history-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        try await makeRepository(at: repository)

        let runner = GitCommandRunner()
        for index in 1...5 {
            _ = try await runner.run(
                arguments: ["commit", "--allow-empty", "-m", "History \(index)"],
                workingDirectory: repository
            )
        }

        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first?.worktree)
        let revision = try XCTUnwrap(worktree.headOID)
        let first = try await service.loadHistoryPage(
            worktree: worktree,
            revision: revision,
            offset: 0,
            pageSize: 2
        )

        _ = try await runner.run(
            arguments: ["commit", "--allow-empty", "-m", "New after paging"],
            workingDirectory: repository
        )

        let second = try await service.loadHistoryPage(
            worktree: worktree,
            revision: revision,
            offset: first.nextOffset,
            pageSize: 2
        )
        let third = try await service.loadHistoryPage(
            worktree: worktree,
            revision: revision,
            offset: second.nextOffset,
            pageSize: 2
        )
        let combined = first.commits + second.commits + third.commits

        XCTAssertEqual(first.commits.map(\.subject), ["History 5", "History 4"])
        XCTAssertEqual(second.commits.map(\.subject), ["History 3", "History 2"])
        XCTAssertEqual(third.commits.map(\.subject), ["History 1", "Initial commit"])
        XCTAssertTrue(first.hasMore)
        XCTAssertTrue(second.hasMore)
        XCTAssertFalse(third.hasMore)
        XCTAssertEqual(Set(combined.map(\.id)).count, combined.count)
    }

    func testLoadsHistoryForOnlyTheRequestedFileLines() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-line-history-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        defer { try? FileManager.default.removeItem(at: container) }
        try await makeRepository(
            at: repository,
            initialContents: "first\ntarget v1\nthird\n"
        )
        let runner = GitCommandRunner()
        try Data("first\ntarget v2\nthird\n".utf8).write(
            to: repository.appendingPathComponent("README.md")
        )
        _ = try await runner.run(
            arguments: ["add", "README.md"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["commit", "-m", "Update target line"],
            workingDirectory: repository
        )
        try Data("first\ntarget v2\nthird\nunrelated\n".utf8).write(
            to: repository.appendingPathComponent("README.md")
        )
        _ = try await runner.run(
            arguments: ["add", "README.md"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["commit", "-m", "Append unrelated line"],
            workingDirectory: repository
        )

        let service = GitRepositoryService(runner: runner)
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first?.worktree)
        let history = try await service.loadLineHistory(
            worktree: worktree,
            revision: worktree.headOID,
            path: "README.md",
            startLine: 2,
            endLine: 2
        )

        XCTAssertEqual(
            history.map(\.subject),
            ["Update target line", "Initial commit"]
        )
    }

    func testSearchesCompleteHistoryByMessageAndAuthorWithPagination() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/search-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        try await makeRepository(at: repository)

        let runner = GitCommandRunner()
        for subject in ["Search token one", "Search token two"] {
            _ = try await runner.run(
                arguments: ["commit", "--allow-empty", "-m", subject],
                workingDirectory: repository
            )
        }
        _ = try await runner.run(
            arguments: [
                "-c", "user.name=Bob Example",
                "-c", "user.email=bob@example.com",
                "commit", "--allow-empty", "-m", "Search token [preview]"
            ],
            workingDirectory: repository
        )

        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first?.worktree)
        let revision = try XCTUnwrap(worktree.headOID)
        let query = try XCTUnwrap(GitHistorySearchQuery("SEARCH TOKEN"))
        let first = try await service.searchHistoryPage(
            worktree: worktree,
            revision: revision,
            query: query,
            offset: 0,
            pageSize: 2
        )
        let second = try await service.searchHistoryPage(
            worktree: worktree,
            revision: revision,
            query: query,
            offset: first.nextOffset,
            pageSize: 2
        )
        let author = try await service.searchHistoryPage(
            worktree: worktree,
            revision: revision,
            query: try XCTUnwrap(GitHistorySearchQuery("author:Bob Example")),
            offset: 0,
            pageSize: 10
        )
        let fixedString = try await service.searchHistoryPage(
            worktree: worktree,
            revision: revision,
            query: try XCTUnwrap(GitHistorySearchQuery("[preview]")),
            offset: 0,
            pageSize: 10
        )

        XCTAssertEqual(first.commits.count, 2)
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(second.commits.count, 1)
        XCTAssertFalse(second.hasMore)
        XCTAssertEqual(author.commits.map(\.authorName), ["Bob Example"])
        XCTAssertEqual(fixedString.commits.map(\.subject), ["Search token [preview]"])
    }

    func testStagedRenameDiffShowsRenameModification() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-rename-test-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        try await makeRepository(
            at: repository,
            initialContents: "one\ntwo\nthree\nfour\n"
        )

        let runner = GitCommandRunner()
        _ = try await runner.run(
            arguments: ["mv", "README.md", "RENAMED.md"],
            workingDirectory: repository
        )
        try Data("one\ntwo\nthree\nfour\nfive\n".utf8).write(
            to: repository.appendingPathComponent("RENAMED.md")
        )
        _ = try await runner.run(
            arguments: ["add", "RENAMED.md"],
            workingDirectory: repository
        )

        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first)
        let renameChange = try XCTUnwrap(
            worktree.status.changes.first { $0.kind == .renamedOrCopied }
        )
        XCTAssertEqual(renameChange.originalPath, "README.md")

        let stagedDiff = try await service.loadDiff(
            worktree: worktree.worktree,
            change: renameChange,
            scope: .staged
        )

        XCTAssertEqual(stagedDiff.addedLineCount, 1)
        XCTAssertEqual(
            stagedDiff.hunks.flatMap(\.lines)
                .first(where: { $0.kind == .addition })?.content,
            "five"
        )
    }

    func testStagesAndUnstagesBothSidesOfRename() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/rename-actions-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        try await makeRepository(at: repository)
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        try FileManager.default.moveItem(
            at: repository.appendingPathComponent("README.md"),
            to: repository.appendingPathComponent("RENAMED.md")
        )
        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first?.worktree)
        let rename = GitFileChange(
            path: "RENAMED.md",
            originalPath: "README.md",
            indexStatus: ".",
            worktreeStatus: "R",
            kind: .renamedOrCopied
        )

        try await service.stageFile(worktree: worktree, change: rename)

        let stagedProject = try await service.loadProject(at: repository)
        let stagedWorktree = try XCTUnwrap(stagedProject.worktrees.first)
        let stagedRename = try XCTUnwrap(
            stagedWorktree.status.changes.first { $0.kind == .renamedOrCopied }
        )
        XCTAssertEqual(stagedRename.path, "RENAMED.md")
        XCTAssertEqual(stagedRename.originalPath, "README.md")
        XCTAssertTrue(stagedRename.isStaged)

        try await service.unstageFile(worktree: stagedWorktree.worktree, change: stagedRename)

        let cachedDiff = try await GitCommandRunner().run(
            arguments: ["diff", "--cached", "--name-status"],
            workingDirectory: repository
        )
        XCTAssertTrue(cachedDiff.isEmpty)
    }

    func testDiscardOnStagedRenameKeepsRenameAndRestoresIndexContents() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/rename-discard-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        try await makeRepository(at: repository)
        defer { try? FileManager.default.removeItem(at: container) }
        let runner = GitCommandRunner()
        _ = try await runner.run(
            arguments: ["mv", "README.md", "RENAMED.md"],
            workingDirectory: repository
        )
        let renamedURL = repository.appendingPathComponent("RENAMED.md")
        try Data("base\nworking change\n".utf8).write(to: renamedURL)
        let service = GitRepositoryService(
            discardRecoveryStore: testDiscardRecoveryStore(in: container)
        )
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first)
        let rename = try XCTUnwrap(
            worktree.status.changes.first { $0.kind == .renamedOrCopied }
        )
        XCTAssertTrue(rename.isStaged)
        XCTAssertTrue(rename.isUnstaged)

        try await service.discardFile(
            worktree: worktree.worktree,
            change: rename
        )

        XCTAssertEqual(
            String(decoding: try Data(contentsOf: renamedURL), as: UTF8.self),
            "base\n"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: repository.appendingPathComponent("README.md").path
            )
        )
        let stagedNameStatus = String(
            decoding: try await runner.run(
                arguments: ["diff", "--cached", "--name-status", "--find-renames"],
                workingDirectory: repository
            ),
            as: UTF8.self
        )
        XCTAssertTrue(stagedNameStatus.contains("R100\tREADME.md\tRENAMED.md"))
    }

    func testSelectedLineStageUpdatesTheNewPathOfAStagedRename() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-rename-working-selection-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        defer { try? FileManager.default.removeItem(at: container) }
        try await makeRepository(
            at: repository,
            initialContents: "one\ntwo\nthree\nfour\nfive\n"
        )

        let runner = GitCommandRunner()
        _ = try await runner.run(
            arguments: ["mv", "README.md", "RENAMED.md"],
            workingDirectory: repository
        )
        let renamedURL = repository.appendingPathComponent("RENAMED.md")
        try Data("one\ntwo\nthree\nfour\nfive\nsix\n".utf8).write(to: renamedURL)

        let service = GitRepositoryService()
        let snapshot = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(snapshot.worktrees.first)
        let change = try XCTUnwrap(
            worktree.status.changes.first(where: { $0.kind == .renamedOrCopied })
        )
        XCTAssertTrue(change.isStaged)
        XCTAssertTrue(change.isUnstaged)
        let diff = try await service.loadDiff(
            worktree: worktree.worktree,
            change: change,
            scope: .working,
            options: GitDiffOptions(context: .lines(0))
        )
        let lineID = try XCTUnwrap(
            diff.hunks.flatMap(\.lines).first(where: {
                $0.kind == .addition && $0.content == "six"
            })?.id
        )

        try await service.applySelection(
            .stage,
            worktree: worktree.worktree,
            diff: diff,
            selectedLineIDs: [lineID]
        )

        let stagedContents = try await runner.run(
            arguments: ["show", ":RENAMED.md"],
            workingDirectory: repository
        )
        let stagedNameStatus = String(
            decoding: try await runner.run(
                arguments: ["diff", "--cached", "--name-status", "--find-renames"],
                workingDirectory: repository
            ),
            as: UTF8.self
        )
        XCTAssertEqual(
            String(decoding: stagedContents, as: UTF8.self),
            "one\ntwo\nthree\nfour\nfive\nsix\n"
        )
        XCTAssertTrue(stagedNameStatus.contains("README.md\tRENAMED.md"))
    }

    func testSelectedLineUnstageKeepsTheStagedRename() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-rename-staged-selection-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        defer { try? FileManager.default.removeItem(at: container) }
        try await makeRepository(
            at: repository,
            initialContents: "one\ntwo\nthree\nfour\nfive\n"
        )

        let runner = GitCommandRunner()
        _ = try await runner.run(
            arguments: ["mv", "README.md", "RENAMED.md"],
            workingDirectory: repository
        )
        let renamedURL = repository.appendingPathComponent("RENAMED.md")
        try Data("one\ntwo\nthree\nfour\nfive\nsix\n".utf8).write(to: renamedURL)
        _ = try await runner.run(
            arguments: ["add", "--", "RENAMED.md"],
            workingDirectory: repository
        )

        let service = GitRepositoryService()
        let snapshot = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(snapshot.worktrees.first)
        let change = try XCTUnwrap(
            worktree.status.changes.first(where: { $0.kind == .renamedOrCopied })
        )
        let diff = try await service.loadDiff(
            worktree: worktree.worktree,
            change: change,
            scope: .staged,
            options: GitDiffOptions(context: .lines(0))
        )
        let lineID = try XCTUnwrap(
            diff.hunks.flatMap(\.lines).first(where: {
                $0.kind == .addition && $0.content == "six"
            })?.id
        )

        try await service.applySelection(
            .unstage,
            worktree: worktree.worktree,
            diff: diff,
            selectedLineIDs: [lineID]
        )

        let stagedContents = try await runner.run(
            arguments: ["show", ":RENAMED.md"],
            workingDirectory: repository
        )
        let stagedNameStatus = String(
            decoding: try await runner.run(
                arguments: ["diff", "--cached", "--name-status", "--find-renames"],
                workingDirectory: repository
            ),
            as: UTF8.self
        )
        XCTAssertEqual(
            String(decoding: stagedContents, as: UTF8.self),
            "one\ntwo\nthree\nfour\nfive\n"
        )
        XCTAssertTrue(stagedNameStatus.contains("R100\tREADME.md\tRENAMED.md"))
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: renamedURL), as: UTF8.self),
            "one\ntwo\nthree\nfour\nfive\nsix\n"
        )
    }

    func testUnstagingCopyKeepsSourceFileStaged() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/copy-actions-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        try await makeRepository(at: repository)
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        let sourceURL = repository.appendingPathComponent("README.md")
        let copyURL = repository.appendingPathComponent("COPY.md")
        try Data("updated source\n".utf8).write(to: sourceURL)
        try FileManager.default.copyItem(at: sourceURL, to: copyURL)
        let runner = GitCommandRunner()
        _ = try await runner.run(
            arguments: ["add", "README.md", "COPY.md"],
            workingDirectory: repository
        )
        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first?.worktree)
        let copy = GitFileChange(
            path: "COPY.md",
            originalPath: "README.md",
            indexStatus: "C",
            worktreeStatus: ".",
            kind: .renamedOrCopied
        )

        try await service.unstageFile(worktree: worktree, change: copy)

        let stagedPaths = String(
            decoding: try await runner.run(
                arguments: ["diff", "--cached", "--name-only"],
                workingDirectory: repository
            ),
            as: UTF8.self
        ).split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(stagedPaths, ["README.md"])
    }

    func testLoadsImageContentsAcrossWorkingStagedCommitAndRange() async throws {
        XCTAssertTrue(GitImageDiff.supports(path: "Assets/icon.png"))
        XCTAssertTrue(GitImageDiff.supports(path: "Assets/photo.HEIC"))
        XCTAssertFalse(GitImageDiff.supports(path: "Sources/icon.swift"))

        let oldImageData = try XCTUnwrap(
            Data(
                base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            )
        )
        let newImageData = try XCTUnwrap(
            Data(
                base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII="
            )
        )
        XCTAssertNotEqual(oldImageData, newImageData)

        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-image-diff-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        try await makeRepository(at: repository)

        let runner = GitCommandRunner()
        let imageURL = repository.appendingPathComponent("icon.png")
        try oldImageData.write(to: imageURL)
        _ = try await runner.run(arguments: ["add", "icon.png"], workingDirectory: repository)
        _ = try await runner.run(
            arguments: ["commit", "-m", "Add image"],
            workingDirectory: repository
        )
        let baseOID = String(
            decoding: try await runner.run(
                arguments: ["rev-parse", "HEAD"],
                workingDirectory: repository
            ),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        try newImageData.write(to: imageURL)
        let service = GitRepositoryService()
        var project = try await service.loadProject(at: repository)
        var worktree = try XCTUnwrap(project.worktrees.first)
        var change = try XCTUnwrap(
            worktree.status.changes.first { $0.path == "icon.png" }
        )
        let workingDiff = try await service.loadDiff(
            worktree: worktree.worktree,
            change: change,
            scope: .working
        )
        XCTAssertEqual(workingDiff.state, .binary)
        var imageDiff = try await service.loadImageDiff(
            worktree: worktree.worktree,
            change: change,
            scope: .working
        )
        XCTAssertEqual(imageDiff.oldImage?.contents, oldImageData)
        XCTAssertEqual(imageDiff.newImage?.contents, newImageData)

        _ = try await runner.run(arguments: ["add", "icon.png"], workingDirectory: repository)
        project = try await service.loadProject(at: repository)
        worktree = try XCTUnwrap(project.worktrees.first)
        change = try XCTUnwrap(worktree.status.changes.first { $0.path == "icon.png" })
        imageDiff = try await service.loadImageDiff(
            worktree: worktree.worktree,
            change: change,
            scope: .staged
        )
        XCTAssertEqual(imageDiff.oldImage?.contents, oldImageData)
        XCTAssertEqual(imageDiff.newImage?.contents, newImageData)

        _ = try await runner.run(
            arguments: ["commit", "-m", "Update image"],
            workingDirectory: repository
        )
        let headOID = String(
            decoding: try await runner.run(
                arguments: ["rev-parse", "HEAD"],
                workingDirectory: repository
            ),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        project = try await service.loadProject(at: repository)
        worktree = try XCTUnwrap(project.worktrees.first)
        let history = try await service.loadHistory(worktree: worktree.worktree)
        let commit = try XCTUnwrap(history.first)
        let commitChanges = try await service.loadCommitChanges(
            worktree: worktree.worktree,
            commit: commit
        )
        let commitChange = try XCTUnwrap(
            commitChanges.first { $0.path == "icon.png" }
        )
        let commitImageDiff = try await service.loadCommitImageDiff(
            worktree: worktree.worktree,
            commit: commit,
            change: commitChange
        )
        XCTAssertEqual(commitImageDiff.oldImage?.contents, oldImageData)
        XCTAssertEqual(commitImageDiff.newImage?.contents, newImageData)

        let rangeChanges = try await service.loadRangeChanges(
            worktree: worktree.worktree,
            baseOID: baseOID,
            headOID: headOID
        )
        let rangeChange = try XCTUnwrap(
            rangeChanges.first { $0.path == "icon.png" }
        )
        let rangeImageDiff = try await service.loadRangeImageDiff(
            worktree: worktree.worktree,
            baseOID: baseOID,
            headOID: headOID,
            change: rangeChange
        )
        XCTAssertEqual(rangeImageDiff.oldImage?.contents, oldImageData)
        XCTAssertEqual(rangeImageDiff.newImage?.contents, newImageData)

        let addedImageURL = repository.appendingPathComponent("added.png")
        try oldImageData.write(to: addedImageURL)
        project = try await service.loadProject(at: repository)
        worktree = try XCTUnwrap(project.worktrees.first)
        let untrackedChange = try XCTUnwrap(
            worktree.status.changes.first { $0.path == "added.png" }
        )
        let addedWorkingImageDiff = try await service.loadImageDiff(
            worktree: worktree.worktree,
            change: untrackedChange,
            scope: .working
        )
        XCTAssertNil(addedWorkingImageDiff.oldImage)
        XCTAssertEqual(addedWorkingImageDiff.newImage?.contents, oldImageData)

        _ = try await runner.run(arguments: ["add", "added.png"], workingDirectory: repository)
        project = try await service.loadProject(at: repository)
        worktree = try XCTUnwrap(project.worktrees.first)
        let stagedAddition = try XCTUnwrap(
            worktree.status.changes.first { $0.path == "added.png" }
        )
        let addedStagedImageDiff = try await service.loadImageDiff(
            worktree: worktree.worktree,
            change: stagedAddition,
            scope: .staged
        )
        XCTAssertNil(addedStagedImageDiff.oldImage)
        XCTAssertEqual(addedStagedImageDiff.newImage?.contents, oldImageData)

        try FileManager.default.removeItem(at: imageURL)
        project = try await service.loadProject(at: repository)
        worktree = try XCTUnwrap(project.worktrees.first)
        let workingDeletion = try XCTUnwrap(
            worktree.status.changes.first { $0.path == "icon.png" }
        )
        let deletedWorkingImageDiff = try await service.loadImageDiff(
            worktree: worktree.worktree,
            change: workingDeletion,
            scope: .working
        )
        XCTAssertEqual(deletedWorkingImageDiff.oldImage?.contents, newImageData)
        XCTAssertNil(deletedWorkingImageDiff.newImage)

        _ = try await runner.run(arguments: ["add", "icon.png"], workingDirectory: repository)
        project = try await service.loadProject(at: repository)
        worktree = try XCTUnwrap(project.worktrees.first)
        let stagedDeletion = try XCTUnwrap(
            worktree.status.changes.first { $0.path == "icon.png" }
        )
        let deletedStagedImageDiff = try await service.loadImageDiff(
            worktree: worktree.worktree,
            change: stagedDeletion,
            scope: .staged
        )
        XCTAssertEqual(deletedStagedImageDiff.oldImage?.contents, newImageData)
        XCTAssertNil(deletedStagedImageDiff.newImage)
    }

    func testRejectsOversizedWorkingImageBeforeReadingItIntoMemory() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/large-image-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        try await makeRepository(at: repository)
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        let imageURL = repository.appendingPathComponent("large.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: imageURL.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: imageURL)
        try handle.truncate(
            atOffset: UInt64(GitImageDiff.maximumBlobByteCount + 1)
        )
        try handle.close()

        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first)
        let change = try XCTUnwrap(
            worktree.status.changes.first { $0.path == "large.png" }
        )

        do {
            _ = try await service.loadImageDiff(
                worktree: worktree.worktree,
                change: change,
                scope: .working
            )
            XCTFail("Oversized image preview should fail")
        } catch let error as GitImageDiffError {
            XCTAssertEqual(
                error,
                .tooLarge(
                    path: "large.png",
                    byteCount: GitImageDiff.maximumBlobByteCount + 1,
                    limit: GitImageDiff.maximumBlobByteCount
                )
            )
        }
    }

    func testUntrackedImageNamedSymlinkRendersLinkTargetAsText() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/symlink-diff-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        let externalFile = container.appendingPathComponent("external-secret.txt")
        try await makeRepository(at: repository)
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        try Data("contents outside the repository\n".utf8).write(to: externalFile)
        let destination = "../external-secret.txt"
        try FileManager.default.createSymbolicLink(
            atPath: repository.appendingPathComponent("linked.png").path,
            withDestinationPath: destination
        )

        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first)
        let change = try XCTUnwrap(
            worktree.status.changes.first { $0.path == "linked.png" }
        )
        let diff = try await service.loadDiff(
            worktree: worktree.worktree,
            change: change,
            scope: .working
        )

        XCTAssertEqual(diff.state, .textual)
        XCTAssertEqual(
            diff.hunks.flatMap(\.lines).filter { $0.kind == .addition }.map(\.content),
            [destination]
        )
        XCTAssertFalse(
            diff.hunks.flatMap(\.lines).contains {
                $0.content.contains("contents outside the repository")
            }
        )
    }

    func testReportsDiffStatRelativeToHead() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-diffstat-test-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        try await makeRepository(
            at: repository,
            initialContents: "one\ntwo\nthree\n"
        )

        try Data("one\nthree\nfour\nfive\n".utf8).write(
            to: repository.appendingPathComponent("README.md")
        )
        try Data("untracked\n".utf8).write(
            to: repository.appendingPathComponent("new.txt")
        )

        let snapshot = try await GitRepositoryService().loadProject(at: repository)
        let worktree = try XCTUnwrap(snapshot.worktrees.first)

        XCTAssertEqual(worktree.diffStat.addedLineCount, 2)
        XCTAssertEqual(worktree.diffStat.deletedLineCount, 1)
        XCTAssertNotNil(worktree.worktree.shortHeadOID)
    }

    func testUnbornRepositoryReportsStagedAndWorkingDiffStat() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-unborn-test-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        let runner = GitCommandRunner()
        _ = try await runner.run(arguments: ["init", "-b", "main"], workingDirectory: repository)

        try Data("one\ntwo\n".utf8).write(
            to: repository.appendingPathComponent("staged.txt")
        )
        _ = try await runner.run(arguments: ["add", "staged.txt"], workingDirectory: repository)
        try Data("one\ntwo\nthree\n".utf8).write(
            to: repository.appendingPathComponent("staged.txt")
        )

        let snapshot = try await GitRepositoryService().loadProject(at: repository)
        let worktree = try XCTUnwrap(snapshot.worktrees.first)

        XCTAssertNil(worktree.errorMessage)
        XCTAssertTrue(worktree.worktree.isUnborn)
        XCTAssertNil(worktree.worktree.shortHeadOID)
        XCTAssertEqual(worktree.diffStat.addedLineCount, 3)
        XCTAssertEqual(worktree.diffStat.deletedLineCount, 0)
    }

    func testFailedInitialWorktreeLoadHasNoUsableState() async {
        let missingURL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/missing-worktree-\(UUID().uuidString)",
            isDirectory: true
        )
        let worktree = GitWorktree(
            rootURL: missingURL,
            headOID: nil,
            branchRef: "refs/heads/main",
            isBare: false,
            isDetached: false,
            lockedReason: nil,
            prunableReason: nil
        )

        let snapshot = await GitRepositoryService().loadWorktree(worktree)

        XCTAssertFalse(snapshot.hasUsableState)
        XCTAssertNotNil(snapshot.errorMessage)
    }

    func testBatchDiffLoadsQuotedFileNamesAndDeduplicatesChanges() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/quoted-diff-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        try await makeRepository(at: repository)
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        let runner = GitCommandRunner()
        let quotedName = "quoted\"name.txt"
        let quotedFile = repository.appendingPathComponent(quotedName)
        let regularFile = repository.appendingPathComponent("regular.txt")
        try Data("base\n".utf8).write(to: quotedFile)
        try Data("base\n".utf8).write(to: regularFile)
        _ = try await runner.run(arguments: ["add", "."], workingDirectory: repository)
        _ = try await runner.run(
            arguments: ["commit", "-m", "Add files"],
            workingDirectory: repository
        )
        let baseOID = String(
            decoding: try await runner.run(
                arguments: ["rev-parse", "HEAD"],
                workingDirectory: repository
            ),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        try Data("base\nquoted change\n".utf8).write(to: quotedFile)
        try Data("base\nregular change\n".utf8).write(to: regularFile)

        let service = GitRepositoryService(runner: runner)
        let snapshot = await service.loadWorktree(
            GitWorktree(
                rootURL: repository,
                headOID: nil,
                branchRef: "refs/heads/main",
                isBare: false,
                isDetached: false,
                lockedReason: nil,
                prunableReason: nil
            )
        )
        let diffs = try await service.loadDiffs(
            worktree: snapshot.worktree,
            changes: snapshot.status.changes + snapshot.status.changes,
            scope: .working
        )
        let diffsByPath = Dictionary(uniqueKeysWithValues: diffs.map {
            ($0.change.path, $0)
        })

        XCTAssertEqual(diffs.count, 2)
        XCTAssertEqual(Set(diffsByPath.keys), [quotedName, "regular.txt"])
        XCTAssertTrue(
            diffsByPath[quotedName]?.hunks.flatMap(\.lines).contains(where: {
                $0.content == "quoted change"
            }) == true
        )
        XCTAssertTrue(
            diffsByPath["regular.txt"]?.hunks.flatMap(\.lines).contains(where: {
                $0.content == "regular change"
            }) == true
        )

        _ = try await runner.run(arguments: ["add", "."], workingDirectory: repository)
        _ = try await runner.run(
            arguments: ["commit", "-m", "Change quoted files"],
            workingDirectory: repository
        )
        let history = try await service.loadHistory(worktree: snapshot.worktree)
        let commit = try XCTUnwrap(history.first)
        let commitChanges = try await service.loadCommitChanges(
            worktree: snapshot.worktree,
            commit: commit
        )
        let commitDiffs = try await service.loadCommitDiffs(
            worktree: snapshot.worktree,
            commit: commit,
            changes: commitChanges + commitChanges
        )
        XCTAssertEqual(commitDiffs.count, 2)
        XCTAssertTrue(
            commitDiffs.first(where: { $0.change.path == quotedName })?
                .hunks.flatMap(\.lines).contains(where: {
                    $0.content == "quoted change"
                }) == true
        )

        let rangeChanges = try await service.loadRangeChanges(
            worktree: snapshot.worktree,
            baseOID: baseOID,
            headOID: commit.oid
        )
        let rangeDiffs = try await service.loadRangeDiffs(
            worktree: snapshot.worktree,
            baseOID: baseOID,
            headOID: commit.oid,
            changes: rangeChanges + rangeChanges
        )
        XCTAssertEqual(rangeDiffs.count, 2)
        XCTAssertTrue(
            rangeDiffs.first(where: { $0.change.path == quotedName })?
                .hunks.flatMap(\.lines).contains(where: {
                    $0.content == "quoted change"
                }) == true
        )
    }

    func testExcludesBareRepositoryEntryFromWorktrees() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-bare-test-\(UUID().uuidString)")
        let seed = container.appendingPathComponent("seed")
        let bare = container.appendingPathComponent("repository.git")
        let worktree = container.appendingPathComponent("work")
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        try await makeRepository(at: seed)

        let runner = GitCommandRunner()
        _ = try await runner.run(
            arguments: ["clone", "--bare", seed.path, bare.path],
            workingDirectory: container
        )
        _ = try await runner.run(
            arguments: ["worktree", "add", worktree.path, "main"],
            workingDirectory: bare
        )

        let snapshot = try await GitRepositoryService().loadProject(at: bare)

        XCTAssertEqual(snapshot.worktrees.count, 1)
        XCTAssertEqual(snapshot.worktrees.first?.worktree.rootURL.path, worktree.path)
        XCTAssertNil(snapshot.worktrees.first?.errorMessage)
    }

    func testStagesUnstagesAndDiscardsWholeFiles() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-file-actions-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        try await makeRepository(at: repository)

        let recoveryRoot = container.appendingPathComponent(
            "recovery",
            isDirectory: true
        )
        let service = GitRepositoryService(
            discardRecoveryStore: GitDiscardRecoveryStore(
                destination: .directory(recoveryRoot)
            )
        )
        let runner = GitCommandRunner()
        let file = repository.appendingPathComponent("README.md")
        try Data("base\nchanged\n".utf8).write(to: file)
        var snapshot = try await service.loadProject(at: repository)
        var worktree = try XCTUnwrap(snapshot.worktrees.first)
        var change = try XCTUnwrap(worktree.status.changes.first)

        try await service.stageFile(worktree: worktree.worktree, change: change)
        let staged = try await runner.run(
            arguments: ["diff", "--cached", "--", "README.md"],
            workingDirectory: repository
        )
        XCTAssertTrue(String(decoding: staged, as: UTF8.self).contains("+changed"))

        snapshot = try await service.loadProject(at: repository)
        worktree = try XCTUnwrap(snapshot.worktrees.first)
        change = try XCTUnwrap(worktree.status.changes.first)
        try await service.unstageFile(worktree: worktree.worktree, change: change)
        let unstaged = try await runner.run(
            arguments: ["diff", "--cached", "--", "README.md"],
            workingDirectory: repository
        )
        XCTAssertTrue(unstaged.isEmpty)

        snapshot = try await service.loadProject(at: repository)
        worktree = try XCTUnwrap(snapshot.worktrees.first)
        change = try XCTUnwrap(worktree.status.changes.first)
        try await service.discardFile(worktree: worktree.worktree, change: change)
        XCTAssertEqual(String(decoding: try Data(contentsOf: file), as: UTF8.self), "base\n")

        let untrackedFile = repository.appendingPathComponent("temporary.txt")
        try Data("temporary\n".utf8).write(to: untrackedFile)
        snapshot = try await service.loadProject(at: repository)
        worktree = try XCTUnwrap(snapshot.worktrees.first)
        change = try XCTUnwrap(worktree.status.changes.first { $0.isUntracked })
        try await service.discardFile(worktree: worktree.worktree, change: change)
        XCTAssertFalse(FileManager.default.fileExists(atPath: untrackedFile.path))
        XCTAssertEqual(
            String(
                decoding: try Data(
                    contentsOf: recoveredItem(
                        relativePath: "README.md",
                        in: recoveryRoot
                    )
                ),
                as: UTF8.self
            ),
            "base\nchanged\n"
        )
        XCTAssertEqual(
            String(
                decoding: try Data(
                    contentsOf: recoveredItem(
                        relativePath: "temporary.txt",
                        in: recoveryRoot
                    )
                ),
                as: UTF8.self
            ),
            "temporary\n"
        )
    }

    func testPullsFastForwardAndPushesConfiguredUpstream() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-remote-actions-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        let remote = container.appendingPathComponent("remote.git")
        let peer = container.appendingPathComponent("peer")
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        try await makeRepository(at: repository)
        let runner = GitCommandRunner()
        _ = try await runner.run(
            arguments: ["init", "--bare", "--initial-branch=main", remote.path],
            workingDirectory: container
        )
        _ = try await runner.run(
            arguments: ["remote", "add", "origin", remote.path],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["push", "--set-upstream", "origin", "main"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["clone", remote.path, peer.path],
            workingDirectory: container
        )
        _ = try await runner.run(
            arguments: ["config", "user.name", "AgentGit Peer"],
            workingDirectory: peer
        )
        _ = try await runner.run(
            arguments: ["config", "user.email", "peer@example.invalid"],
            workingDirectory: peer
        )
        try Data("base\nfrom peer\n".utf8).write(
            to: peer.appendingPathComponent("README.md")
        )
        _ = try await runner.run(arguments: ["add", "README.md"], workingDirectory: peer)
        _ = try await runner.run(
            arguments: ["commit", "-m", "Peer update"],
            workingDirectory: peer
        )
        _ = try await runner.run(arguments: ["push"], workingDirectory: peer)

        let service = GitRepositoryService()
        var project = try await service.loadProject(at: repository)
        var worktree = try XCTUnwrap(project.worktrees.first?.worktree)
        try await service.performRemoteAction(.pull, worktree: worktree)
        XCTAssertEqual(
            String(
                decoding: try Data(contentsOf: repository.appendingPathComponent("README.md")),
                as: UTF8.self
            ),
            "base\nfrom peer\n"
        )

        try Data("base\nfrom peer\nfrom AgentGit\n".utf8).write(
            to: repository.appendingPathComponent("README.md")
        )
        _ = try await runner.run(arguments: ["add", "README.md"], workingDirectory: repository)
        _ = try await runner.run(
            arguments: ["commit", "-m", "AgentGit update"],
            workingDirectory: repository
        )
        project = try await service.loadProject(at: repository)
        worktree = try XCTUnwrap(project.worktrees.first?.worktree)
        try await service.performRemoteAction(.push, worktree: worktree)
        let remoteContents = try await runner.run(
            arguments: ["show", "main:README.md"],
            workingDirectory: remote
        )
        XCTAssertEqual(
            String(decoding: remoteContents, as: UTF8.self),
            "base\nfrom peer\nfrom AgentGit\n"
        )
    }

    func testPushPublishesBranchWithoutConfiguredUpstream() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-publish-branch-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        let remote = container.appendingPathComponent("remote.git")
        defer { try? FileManager.default.removeItem(at: container) }
        try await makeRepository(at: repository)

        let runner = GitCommandRunner()
        _ = try await runner.run(
            arguments: ["init", "--bare", "--initial-branch=main", remote.path],
            workingDirectory: container
        )
        _ = try await runner.run(
            arguments: ["remote", "add", "origin", remote.path],
            workingDirectory: repository
        )
        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first?.worktree)

        try await service.performRemoteAction(.push, worktree: worktree)

        let upstream = String(
            decoding: try await runner.run(
                arguments: [
                    "rev-parse",
                    "--abbrev-ref",
                    "--symbolic-full-name",
                    "@{upstream}"
                ],
                workingDirectory: repository
            ),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let localHead = try await revision("HEAD", in: repository, using: runner)
        let remoteHead = try await revision("refs/heads/main", in: remote, using: runner)
        XCTAssertEqual(upstream, "origin/main")
        XCTAssertEqual(remoteHead, localHead)
    }

    func testPublishRequiresAnUnambiguousRemote() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-publish-remotes-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        let firstRemote = container.appendingPathComponent("first.git")
        let secondRemote = container.appendingPathComponent("second.git")
        defer { try? FileManager.default.removeItem(at: container) }
        try await makeRepository(at: repository)

        let runner = GitCommandRunner()
        for remote in [firstRemote, secondRemote] {
            _ = try await runner.run(
                arguments: ["init", "--bare", "--initial-branch=main", remote.path],
                workingDirectory: container
            )
        }
        _ = try await runner.run(
            arguments: ["remote", "add", "team", firstRemote.path],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["remote", "add", "backup", secondRemote.path],
            workingDirectory: repository
        )
        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first?.worktree)

        do {
            try await service.performRemoteAction(.push, worktree: worktree)
            XCTFail("Expected Publish to require an upstream choice")
        } catch let error as GitRemoteActionError {
            XCTAssertEqual(error, .ambiguousRemotes(["backup", "team"]))
        }
    }

    func testPushKeepsConfiguredRemoteWhenItsTrackingRefIsMissing() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-push-missing-ref-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        let origin = container.appendingPathComponent("origin.git")
        let team = container.appendingPathComponent("team.git")
        defer { try? FileManager.default.removeItem(at: container) }
        try await makeRepository(at: repository)

        let runner = GitCommandRunner()
        for remote in [origin, team] {
            _ = try await runner.run(
                arguments: ["init", "--bare", "--initial-branch=main", remote.path],
                workingDirectory: container
            )
        }
        _ = try await runner.run(
            arguments: ["remote", "add", "origin", origin.path],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["remote", "add", "team", team.path],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["config", "branch.main.remote", "team"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["config", "branch.main.merge", "refs/heads/main"],
            workingDirectory: repository
        )
        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first?.worktree)

        try await service.performRemoteAction(.push, worktree: worktree)

        let localHead = try await revision("HEAD", in: repository, using: runner)
        let teamHead = try await revision("refs/heads/main", in: team, using: runner)
        XCTAssertEqual(teamHead, localHead)
        do {
            _ = try await revision("refs/heads/main", in: origin, using: runner)
            XCTFail("Origin should remain untouched")
        } catch is GitCommandFailure {
        }
    }

    func testPullRestoresConfiguredTrackingRefWhenMissing() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-pull-missing-ref-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        let remote = container.appendingPathComponent("remote.git")
        defer { try? FileManager.default.removeItem(at: container) }
        try await makeRepository(at: repository)

        let runner = GitCommandRunner()
        _ = try await runner.run(
            arguments: ["init", "--bare", "--initial-branch=main", remote.path],
            workingDirectory: container
        )
        _ = try await runner.run(
            arguments: ["remote", "add", "origin", remote.path],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["push", "origin", "main"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["config", "branch.main.remote", "origin"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["config", "branch.main.merge", "refs/heads/main"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["update-ref", "-d", "refs/remotes/origin/main"],
            workingDirectory: repository
        )

        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let snapshot = try XCTUnwrap(project.worktrees.first)
        XCTAssertEqual(snapshot.status.branch?.upstreamRef, "origin/main")
        XCTAssertNotNil(snapshot.status.branch?.upstreamError)

        try await service.performRemoteAction(.pull, worktree: snapshot.worktree)

        let trackingHead = try await revision(
            "refs/remotes/origin/main",
            in: repository,
            using: runner
        )
        let localHead = try await revision("HEAD", in: repository, using: runner)
        XCTAssertEqual(trackingHead, localHead)
    }

    func testRemoteActionsPreserveDivergedLocalAndRemoteHeads() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agentgit-diverged-remote-\(UUID().uuidString)"
            )
        let repository = container.appendingPathComponent("repository")
        let remote = container.appendingPathComponent("remote.git")
        let peer = container.appendingPathComponent("peer")
        defer { try? FileManager.default.removeItem(at: container) }
        try await makeRepository(at: repository)
        let runner = GitCommandRunner()
        _ = try await runner.run(
            arguments: ["init", "--bare", "--initial-branch=main", remote.path],
            workingDirectory: container
        )
        _ = try await runner.run(
            arguments: ["remote", "add", "origin", remote.path],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["push", "--set-upstream", "origin", "main"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["clone", remote.path, peer.path],
            workingDirectory: container
        )
        _ = try await runner.run(
            arguments: ["config", "user.name", "AgentGit Peer"],
            workingDirectory: peer
        )
        _ = try await runner.run(
            arguments: ["config", "user.email", "peer@example.invalid"],
            workingDirectory: peer
        )
        _ = try await runner.run(
            arguments: ["commit", "--allow-empty", "-m", "Local commit"],
            workingDirectory: repository
        )
        let localHead = try await revision("HEAD", in: repository, using: runner)
        _ = try await runner.run(
            arguments: ["commit", "--allow-empty", "-m", "Peer commit"],
            workingDirectory: peer
        )
        _ = try await runner.run(
            arguments: ["push"],
            workingDirectory: peer
        )
        let remoteHead = try await revision("HEAD", in: remote, using: runner)
        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first?.worktree)

        do {
            try await service.performRemoteAction(.pull, worktree: worktree)
            XCTFail("Expected fast-forward-only Pull to reject diverged history")
        } catch let failure as GitCommandFailure {
            XCTAssertNotEqual(failure.exitCode, 0)
        }
        let localAfterPull = try await revision(
            "HEAD",
            in: repository,
            using: runner
        )
        XCTAssertEqual(localAfterPull, localHead)

        do {
            try await service.performRemoteAction(.push, worktree: worktree)
            XCTFail("Expected Push to reject a non-fast-forward update")
        } catch let failure as GitCommandFailure {
            XCTAssertNotEqual(failure.exitCode, 0)
        }
        let localAfterPush = try await revision(
            "HEAD",
            in: repository,
            using: runner
        )
        let remoteAfterPush = try await revision(
            "HEAD",
            in: remote,
            using: runner
        )
        XCTAssertEqual(localAfterPush, localHead)
        XCTAssertEqual(remoteAfterPush, remoteHead)

        let refreshed = try await service.loadProject(at: repository)
        let branch = try XCTUnwrap(refreshed.worktrees.first?.status.branch)
        XCTAssertEqual(branch.aheadCount, 1)
        XCTAssertEqual(branch.behindCount, 1)
    }

    func testCancellingPushTerminatesRemoteHookWait() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agentgit-cancel-remote-\(UUID().uuidString)"
            )
        let repository = container.appendingPathComponent("repository")
        let remote = container.appendingPathComponent("remote.git")
        defer { try? FileManager.default.removeItem(at: container) }
        try await makeRepository(at: repository)
        let runner = GitCommandRunner()
        _ = try await runner.run(
            arguments: ["init", "--bare", "--initial-branch=main", remote.path],
            workingDirectory: container
        )
        _ = try await runner.run(
            arguments: ["remote", "add", "origin", remote.path],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["push", "--set-upstream", "origin", "main"],
            workingDirectory: repository
        )
        let hookURL = remote.appendingPathComponent("hooks/pre-receive")
        try Data("#!/bin/sh\nsleep 10\n".utf8).write(to: hookURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: hookURL.path
        )
        _ = try await runner.run(
            arguments: ["commit", "--allow-empty", "-m", "Blocked push"],
            workingDirectory: repository
        )
        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first?.worktree)
        let startedAt = ContinuousClock.now
        let pushTask = Task {
            try await service.performRemoteAction(.push, worktree: worktree)
        }
        try await Task.sleep(for: .milliseconds(250))
        pushTask.cancel()

        do {
            try await pushTask.value
            XCTFail("Expected cancelled Push to throw CancellationError")
        } catch is CancellationError {
        }
        XCTAssertLessThan(ContinuousClock.now - startedAt, .seconds(3))
    }

    func testLoadsManyDiffsInProgressiveBatches() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-diff-batches-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        try await makeRepository(at: repository)
        let runner = GitCommandRunner()
        for index in 0..<30 {
            try Data("base \(index)\n".utf8).write(
                to: repository.appendingPathComponent("file-\(index).txt")
            )
        }
        _ = try await runner.run(arguments: ["add", "."], workingDirectory: repository)
        _ = try await runner.run(
            arguments: ["commit", "-m", "Add batch files"],
            workingDirectory: repository
        )
        for index in 0..<30 {
            try Data("changed \(index)\n".utf8).write(
                to: repository.appendingPathComponent("file-\(index).txt")
            )
        }

        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first)
        var batches: [[GitFileDiff]] = []
        for try await batch in service.loadDiffBatches(
            worktree: worktree.worktree,
            changes: worktree.status.changes,
            scope: .working
        ) {
            batches.append(batch)
        }

        XCTAssertEqual(batches.map(\.count), [24, 6])
        XCTAssertEqual(batches.flatMap { $0 }.count, 30)
        XCTAssertTrue(batches.flatMap { $0 }.allSatisfy { $0.state == .textual })
    }

    func testLoadsWorkingAndStagedDiffsAsConcurrentPendingBatches() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/pending-batches-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        try await makeRepository(at: repository)
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        let runner = GitCommandRunner()
        let stagedURL = repository.appendingPathComponent("staged.txt")
        let workingURL = repository.appendingPathComponent("working.txt")
        try Data("base\n".utf8).write(to: stagedURL)
        try Data("base\n".utf8).write(to: workingURL)
        _ = try await runner.run(arguments: ["add", "."], workingDirectory: repository)
        _ = try await runner.run(
            arguments: ["commit", "-m", "Add pending files"],
            workingDirectory: repository
        )
        try Data("staged change\n".utf8).write(to: stagedURL)
        _ = try await runner.run(
            arguments: ["add", "staged.txt"],
            workingDirectory: repository
        )
        try Data("working change\n".utf8).write(to: workingURL)

        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first)
        let workingChanges = worktree.status.changes.filter(\.isUnstaged)
        let stagedChanges = worktree.status.changes.filter(\.isStaged)
        var batches: [GitPendingDiffBatch] = []
        for try await batch in service.loadPendingDiffBatches(
            worktree: worktree.worktree,
            workingChanges: workingChanges,
            stagedChanges: stagedChanges
        ) {
            batches.append(batch)
        }

        XCTAssertEqual(Set(batches.map(\.scope)), Set([.working, .staged]))
        XCTAssertEqual(batches.flatMap(\.diffs).count, 2)
        XCTAssertTrue(
            batches.allSatisfy { batch in
                batch.diffs.allSatisfy { $0.scope == batch.scope && $0.state == .textual }
            }
        )
    }

    func testLargeDiffStopsBeforeConstructingEveryRenderedLine() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-large-diff-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        try await makeRepository(at: repository)
        let runner = GitCommandRunner()
        let fileURL = repository.appendingPathComponent("large.txt")
        try Data().write(to: fileURL)
        _ = try await runner.run(arguments: ["add", "large.txt"], workingDirectory: repository)
        _ = try await runner.run(
            arguments: ["commit", "-m", "Add large file"],
            workingDirectory: repository
        )
        let lineCount = UnifiedDiffParser.maximumRenderedLines + 100
        try Data((0..<lineCount).map { "line \($0)" }.joined(separator: "\n").utf8)
            .write(to: fileURL)

        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first)
        let change = try XCTUnwrap(worktree.status.changes.first { $0.path == "large.txt" })
        let diff = try await service.loadDiff(
            worktree: worktree.worktree,
            change: change,
            scope: .working
        )

        guard case let .tooLarge(reportedLineCount) = diff.state else {
            return XCTFail("Expected a bounded large-diff result")
        }
        XCTAssertGreaterThan(reportedLineCount, UnifiedDiffParser.maximumRenderedLines)
        XCTAssertTrue(diff.hunks.isEmpty)
        XCTAssertEqual(diff.addedLineCount, lineCount)
        XCTAssertEqual(diff.deletedLineCount, 0)
    }

    func testStagesUnstagesAndDiscardsSelectedChangedLines() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-line-actions-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        try await makeRepository(
            at: repository,
            initialContents: "one\ntwo\nthree\nfour\nfive\n"
        )

        let recoveryRoot = container.appendingPathComponent(
            "recovery",
            isDirectory: true
        )
        let service = GitRepositoryService(
            discardRecoveryStore: GitDiscardRecoveryStore(
                destination: .directory(recoveryRoot)
            )
        )
        let runner = GitCommandRunner()
        let file = repository.appendingPathComponent("README.md")
        try Data("ONE\ntwo\nthree\nfour\nFIVE\n".utf8).write(to: file)

        var snapshot = try await service.loadProject(at: repository)
        var worktree = try XCTUnwrap(snapshot.worktrees.first)
        var change = try XCTUnwrap(worktree.status.changes.first)
        var diff = try await service.loadDiff(
            worktree: worktree.worktree,
            change: change,
            scope: .working,
            options: GitDiffOptions(context: .lines(0))
        )
        let firstHunk = try XCTUnwrap(diff.hunks.first)
        let firstIDs = Set(
            firstHunk.lines.filter { $0.kind == .addition || $0.kind == .deletion }.map(\.id)
        )
        try await service.applySelection(
            .stage,
            worktree: worktree.worktree,
            diff: diff,
            selectedLineIDs: firstIDs
        )

        let cachedPatch = String(
            decoding: try await runner.run(
                arguments: ["diff", "--cached", "--", "README.md"],
                workingDirectory: repository
            ),
            as: UTF8.self
        )
        XCTAssertTrue(cachedPatch.contains("+ONE"))
        XCTAssertFalse(cachedPatch.contains("+FIVE"))

        snapshot = try await service.loadProject(at: repository)
        worktree = try XCTUnwrap(snapshot.worktrees.first)
        change = try XCTUnwrap(worktree.status.changes.first)
        diff = try await service.loadDiff(
            worktree: worktree.worktree,
            change: change,
            scope: .staged,
            options: GitDiffOptions(context: .lines(0))
        )
        let stagedIDs = Set(
            diff.hunks.flatMap(\.lines)
                .filter { $0.kind == .addition || $0.kind == .deletion }
                .map(\.id)
        )
        try await service.applySelection(
            .unstage,
            worktree: worktree.worktree,
            diff: diff,
            selectedLineIDs: stagedIDs
        )
        let emptyCachedPatch = try await runner.run(
            arguments: ["diff", "--cached", "--", "README.md"],
            workingDirectory: repository
        )
        XCTAssertTrue(emptyCachedPatch.isEmpty)

        snapshot = try await service.loadProject(at: repository)
        worktree = try XCTUnwrap(snapshot.worktrees.first)
        change = try XCTUnwrap(worktree.status.changes.first)
        diff = try await service.loadDiff(
            worktree: worktree.worktree,
            change: change,
            scope: .working,
            options: GitDiffOptions(context: .lines(0))
        )
        let lastHunk = try XCTUnwrap(diff.hunks.last)
        let lastIDs = Set(
            lastHunk.lines.filter { $0.kind == .addition || $0.kind == .deletion }.map(\.id)
        )
        try await service.applySelection(
            .discard,
            worktree: worktree.worktree,
            diff: diff,
            selectedLineIDs: lastIDs
        )

        XCTAssertEqual(
            String(decoding: try Data(contentsOf: file), as: UTF8.self),
            "ONE\ntwo\nthree\nfour\nfive\n"
        )
        XCTAssertEqual(
            String(
                decoding: try Data(
                    contentsOf: recoveredItem(
                        relativePath: "README.md",
                        in: recoveryRoot
                    )
                ),
                as: UTF8.self
            ),
            "ONE\ntwo\nthree\nfour\nFIVE\n"
        )
    }

    func testStagesAndDiscardsSelectedLinesInUntrackedFile() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-untracked-lines-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        try await makeRepository(at: repository)

        let recoveryRoot = container.appendingPathComponent(
            "recovery",
            isDirectory: true
        )
        let service = GitRepositoryService(
            discardRecoveryStore: GitDiscardRecoveryStore(
                destination: .directory(recoveryRoot)
            )
        )
        let runner = GitCommandRunner()
        let file = repository.appendingPathComponent("partial.txt")
        try Data("first\nsecond\nthird\n".utf8).write(to: file)

        var snapshot = try await service.loadProject(at: repository)
        var worktree = try XCTUnwrap(snapshot.worktrees.first)
        var change = try XCTUnwrap(worktree.status.changes.first { $0.isUntracked })
        var diff = try await service.loadDiff(
            worktree: worktree.worktree,
            change: change,
            scope: .working,
            options: GitDiffOptions(context: .lines(0))
        )
        let firstLineID = try XCTUnwrap(
            diff.hunks.flatMap(\.lines).first { $0.newLineNumber == 1 }?.id
        )
        try await service.applySelection(
            .stage,
            worktree: worktree.worktree,
            diff: diff,
            selectedLineIDs: [firstLineID]
        )

        let stagedContents = try await runner.run(
            arguments: ["show", ":partial.txt"],
            workingDirectory: repository
        )
        XCTAssertEqual(String(decoding: stagedContents, as: UTF8.self), "first\n")

        snapshot = try await service.loadProject(at: repository)
        worktree = try XCTUnwrap(snapshot.worktrees.first)
        change = try XCTUnwrap(worktree.status.changes.first { $0.indexStatus == "A" })
        diff = try await service.loadDiff(
            worktree: worktree.worktree,
            change: change,
            scope: .staged,
            options: GitDiffOptions(context: .lines(0))
        )
        let stagedIDs = Set(diff.hunks.flatMap(\.lines).map(\.id))
        try await service.applySelection(
            .unstage,
            worktree: worktree.worktree,
            diff: diff,
            selectedLineIDs: stagedIDs
        )

        snapshot = try await service.loadProject(at: repository)
        worktree = try XCTUnwrap(snapshot.worktrees.first)
        change = try XCTUnwrap(worktree.status.changes.first { $0.isUntracked })
        diff = try await service.loadDiff(
            worktree: worktree.worktree,
            change: change,
            scope: .working,
            options: GitDiffOptions(context: .lines(0))
        )
        let secondLineID = try XCTUnwrap(
            diff.hunks.flatMap(\.lines).first { $0.newLineNumber == 2 }?.id
        )
        try await service.applySelection(
            .discard,
            worktree: worktree.worktree,
            diff: diff,
            selectedLineIDs: [secondLineID]
        )
        XCTAssertEqual(String(decoding: try Data(contentsOf: file), as: UTF8.self), "first\nthird\n")
        XCTAssertEqual(
            String(
                decoding: try Data(
                    contentsOf: recoveredItem(
                        relativePath: "partial.txt",
                        in: recoveryRoot
                    )
                ),
                as: UTF8.self
            ),
            "first\nsecond\nthird\n"
        )
    }

    func testSelectedLineStagePreservesExecutableModeForUntrackedFile() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-untracked-executable-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        defer { try? FileManager.default.removeItem(at: container) }
        try await makeRepository(at: repository)

        let service = GitRepositoryService()
        let runner = GitCommandRunner()
        let file = repository.appendingPathComponent("script.sh")
        try Data("first\nsecond\n".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: file.path
        )
        let snapshot = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(snapshot.worktrees.first)
        let change = try XCTUnwrap(
            worktree.status.changes.first(where: { $0.path == "script.sh" })
        )
        let diff = try await service.loadDiff(
            worktree: worktree.worktree,
            change: change,
            scope: .working,
            options: GitDiffOptions(context: .lines(0))
        )
        let firstLineID = try XCTUnwrap(
            diff.hunks.flatMap(\.lines).first(where: {
                $0.kind == .addition && $0.newLineNumber == 1
            })?.id
        )

        try await service.applySelection(
            .stage,
            worktree: worktree.worktree,
            diff: diff,
            selectedLineIDs: [firstLineID]
        )

        let stagedMode = String(
            decoding: try await runner.run(
                arguments: ["ls-files", "--format=%(objectmode)", "--", "script.sh"],
                workingDirectory: repository
            ),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let stagedContents = try await runner.run(
            arguments: ["show", ":script.sh"],
            workingDirectory: repository
        )
        XCTAssertEqual(stagedMode, "100755")
        XCTAssertEqual(String(decoding: stagedContents, as: UTF8.self), "first\n")
    }

    func testSelectedLineStagePreservesUntrackedSymbolicLink() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-untracked-symlink-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        defer { try? FileManager.default.removeItem(at: container) }
        try await makeRepository(at: repository)

        let service = GitRepositoryService()
        let runner = GitCommandRunner()
        let link = repository.appendingPathComponent("current-link")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "target-file"
        )
        let snapshot = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(snapshot.worktrees.first)
        let change = try XCTUnwrap(
            worktree.status.changes.first(where: { $0.path == "current-link" })
        )
        let diff = try await service.loadDiff(
            worktree: worktree.worktree,
            change: change,
            scope: .working,
            options: GitDiffOptions(context: .lines(0))
        )
        let lineID = try XCTUnwrap(
            diff.hunks.flatMap(\.lines).first(where: { $0.kind == .addition })?.id
        )

        try await service.applySelection(
            .stage,
            worktree: worktree.worktree,
            diff: diff,
            selectedLineIDs: [lineID]
        )

        let stagedMode = String(
            decoding: try await runner.run(
                arguments: ["ls-files", "--format=%(objectmode)", "--", "current-link"],
                workingDirectory: repository
            ),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let stagedContents = try await runner.run(
            arguments: ["show", ":current-link"],
            workingDirectory: repository
        )
        XCTAssertEqual(stagedMode, "120000")
        XCTAssertEqual(String(decoding: stagedContents, as: UTF8.self), "target-file")
    }

    func testSelectedLineStageUpdatesAnAlreadyStagedNewFile() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-staged-new-working-edit-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        defer { try? FileManager.default.removeItem(at: container) }
        try await makeRepository(at: repository)

        let service = GitRepositoryService()
        let runner = GitCommandRunner()
        let file = repository.appendingPathComponent("script.sh")
        try Data("first\nsecond\n".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: file.path
        )
        _ = try await runner.run(
            arguments: ["add", "--", "script.sh"],
            workingDirectory: repository
        )
        try Data("first\nsecond\nthird\n".utf8).write(to: file)

        let snapshot = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(snapshot.worktrees.first)
        let change = try XCTUnwrap(
            worktree.status.changes.first(where: { $0.path == "script.sh" })
        )
        XCTAssertEqual(change.indexStatus, "A")
        XCTAssertEqual(change.worktreeStatus, "M")
        let diff = try await service.loadDiff(
            worktree: worktree.worktree,
            change: change,
            scope: .working,
            options: GitDiffOptions(context: .lines(0))
        )
        let addedLineID = try XCTUnwrap(
            diff.hunks.flatMap(\.lines).first(where: {
                $0.kind == .addition && $0.content == "third"
            })?.id
        )

        try await service.applySelection(
            .stage,
            worktree: worktree.worktree,
            diff: diff,
            selectedLineIDs: [addedLineID]
        )

        let stagedContents = try await runner.run(
            arguments: ["show", ":script.sh"],
            workingDirectory: repository
        )
        let stagedMode = String(
            decoding: try await runner.run(
                arguments: ["ls-files", "--format=%(objectmode)", "--", "script.sh"],
                workingDirectory: repository
            ),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            String(decoding: stagedContents, as: UTF8.self),
            "first\nsecond\nthird\n"
        )
        XCTAssertEqual(stagedMode, "100755")
    }

    func testSelectedLineUnstageKeepsRemainingExecutableNewFile() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-partial-unstage-new-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        defer { try? FileManager.default.removeItem(at: container) }
        try await makeRepository(at: repository)

        let service = GitRepositoryService()
        let runner = GitCommandRunner()
        let file = repository.appendingPathComponent("script.sh")
        try Data("first\nsecond\nthird\n".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: file.path
        )
        _ = try await runner.run(
            arguments: ["add", "--", "script.sh"],
            workingDirectory: repository
        )

        let snapshot = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(snapshot.worktrees.first)
        let change = try XCTUnwrap(
            worktree.status.changes.first(where: { $0.path == "script.sh" })
        )
        let diff = try await service.loadDiff(
            worktree: worktree.worktree,
            change: change,
            scope: .staged,
            options: GitDiffOptions(context: .lines(0))
        )
        let thirdLineID = try XCTUnwrap(
            diff.hunks.flatMap(\.lines).first(where: {
                $0.kind == .addition && $0.content == "third"
            })?.id
        )

        try await service.applySelection(
            .unstage,
            worktree: worktree.worktree,
            diff: diff,
            selectedLineIDs: [thirdLineID]
        )

        let stagedContents = try await runner.run(
            arguments: ["show", ":script.sh"],
            workingDirectory: repository
        )
        let stagedMode = String(
            decoding: try await runner.run(
                arguments: ["ls-files", "--format=%(objectmode)", "--", "script.sh"],
                workingDirectory: repository
            ),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            String(decoding: stagedContents, as: UTF8.self),
            "first\nsecond\n"
        )
        XCTAssertEqual(stagedMode, "100755")
        XCTAssertEqual(String(decoding: try Data(contentsOf: file), as: UTF8.self), "first\nsecond\nthird\n")
    }

    func testUnstageInUnbornRepositoryReturnsFileToUntrackedState() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-unborn-unstage-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        let runner = GitCommandRunner()
        _ = try await runner.run(
            arguments: ["init", "-b", "main"],
            workingDirectory: repository
        )
        let file = repository.appendingPathComponent("first.txt")
        try Data("first\n".utf8).write(to: file)
        _ = try await runner.run(
            arguments: ["add", "--", "first.txt"],
            workingDirectory: repository
        )

        let service = GitRepositoryService()
        var snapshot = try await service.loadProject(at: repository)
        var worktree = try XCTUnwrap(snapshot.worktrees.first)
        XCTAssertTrue(worktree.worktree.isUnborn)
        var change = try XCTUnwrap(
            worktree.status.changes.first(where: { $0.path == "first.txt" })
        )
        try await service.unstageFile(
            worktree: worktree.worktree,
            change: change
        )

        snapshot = try await service.loadProject(at: repository)
        worktree = try XCTUnwrap(snapshot.worktrees.first)
        change = try XCTUnwrap(
            worktree.status.changes.first(where: { $0.path == "first.txt" })
        )
        XCTAssertTrue(change.isUntracked)
        XCTAssertEqual(worktree.status.stagedFileCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testDiffStatCacheInvalidatesWhenChangedFileMetadataChanges() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/diff-stat-cache-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        try await makeRepository(at: repository)
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        let service = GitRepositoryService()
        let initial = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(initial.worktrees.first?.worktree)
        let file = repository.appendingPathComponent("README.md")

        try Data("base\none\n".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 10_000)],
            ofItemAtPath: file.path
        )
        let first = await service.loadWorktree(worktree)
        XCTAssertEqual(first.diffStat.addedLineCount, 1)
        XCTAssertEqual(first.diffStat.deletedLineCount, 0)

        try Data("base\none\ntwo\n".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 10_002)],
            ofItemAtPath: file.path
        )
        let second = await service.loadWorktree(worktree)
        XCTAssertEqual(second.diffStat.addedLineCount, 2)
        XCTAssertEqual(second.diffStat.deletedLineCount, 0)

        let unchanged = await service.loadWorktree(worktree)
        XCTAssertEqual(unchanged.diffStat, second.diffStat)
    }

    func testProjectRefreshEventsDiscoverWorktreesBeforeSnapshotsFinish() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/project-events-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        try await makeRepository(at: repository)
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        var eventKinds: [String] = []
        var loadedWorktreeIDs: [GitWorktree.ID] = []

        for try await event in GitRepositoryService().projectRefreshEvents(
            at: repository,
            prioritizedWorktreeID: repository.standardizedFileURL.path
        ) {
            switch event {
            case let .discovered(_, worktrees):
                eventKinds.append("discovered:\(worktrees.count)")
            case let .worktree(snapshot):
                eventKinds.append("worktree")
                loadedWorktreeIDs.append(snapshot.id)
            }
        }

        XCTAssertEqual(eventKinds, ["discovered:1", "worktree"])
        XCTAssertEqual(loadedWorktreeIDs, [repository.standardizedFileURL.path])
    }

    func testPrioritizedProjectRefreshPublishesLightweightThenCompleteSubmoduleStatus() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/project-priority-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        try await makeRepository(at: repository)
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        var loadedWorktreeIDs: [GitWorktree.ID] = []

        for try await event in GitRepositoryService().projectRefreshEvents(
            at: repository,
            prioritizedWorktreeID: repository.standardizedFileURL.path,
            prioritizedSubmoduleScanMode: .allChanges
        ) {
            if case let .worktree(snapshot) = event {
                loadedWorktreeIDs.append(snapshot.id)
            }
        }

        XCTAssertEqual(
            loadedWorktreeIDs,
            [repository.standardizedFileURL.path, repository.standardizedFileURL.path]
        )
    }

    func testUnmergedFileShowsOursDiffAndStagesResolvedFile() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/unmerged-review-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        try await makeRepository(at: repository)
        defer { try? FileManager.default.removeItem(at: container) }
        let runner = GitCommandRunner()
        _ = try await runner.run(
            arguments: ["switch", "-c", "feature"],
            workingDirectory: repository
        )
        try Data("feature\n".utf8).write(
            to: repository.appendingPathComponent("README.md")
        )
        _ = try await runner.run(
            arguments: ["commit", "-am", "Feature"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["switch", "main"],
            workingDirectory: repository
        )
        try Data("main\n".utf8).write(
            to: repository.appendingPathComponent("README.md")
        )
        _ = try await runner.run(
            arguments: ["commit", "-am", "Main"],
            workingDirectory: repository
        )
        do {
            _ = try await runner.run(
                arguments: ["merge", "feature"],
                workingDirectory: repository
            )
            XCTFail("Expected a merge conflict")
        } catch is GitCommandFailure {
        }

        let service = GitRepositoryService(
            runner: runner,
            discardRecoveryStore: testDiscardRecoveryStore(in: container)
        )
        let conflictedProject = try await service.loadProject(at: repository)
        let conflictedWorktree = try XCTUnwrap(conflictedProject.worktrees.first)
        let change = try XCTUnwrap(
            conflictedWorktree.status.changes.first(where: { $0.path == "README.md" })
        )
        XCTAssertEqual(change.kind, .unmerged)
        let diff = try await service.loadDiff(
            worktree: conflictedWorktree.worktree,
            change: change,
            scope: .working
        )
        XCTAssertEqual(diff.state, .textual)
        XCTAssertEqual(diff.hunks.count, 1)
        XCTAssertTrue(
            diff.hunks.flatMap(\.lines).contains(where: {
                $0.content == "<<<<<<< HEAD"
            })
        )
        do {
            try await service.discardFile(
                worktree: conflictedWorktree.worktree,
                change: change
            )
            XCTFail("Expected unmerged discard to fail")
        } catch let error as GitCommandFailure {
            XCTAssertTrue(error.stderr.contains("unmerged"))
        }

        try Data("resolved\n".utf8).write(
            to: repository.appendingPathComponent("README.md")
        )
        try await service.stageFile(
            worktree: conflictedWorktree.worktree,
            change: change
        )
        let resolvedProject = try await service.loadProject(at: repository)
        let resolvedWorktree = try XCTUnwrap(resolvedProject.worktrees.first)
        XCTAssertFalse(resolvedWorktree.status.changes.contains(where: {
            $0.kind == .unmerged
        }))
        XCTAssertEqual(resolvedWorktree.status.stagedFileCount, 1)
    }

    func testWorkingTreeEventFilterUsesRealGitIgnoreRulesAndKeepsTrackedFiles() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/event-ignore-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        try await makeRepository(at: repository)
        defer { try? FileManager.default.removeItem(at: container) }
        let runner = GitCommandRunner()
        try Data("build/\n*.generated\n".utf8).write(
            to: repository.appendingPathComponent(".gitignore")
        )
        try Data("tracked\n".utf8).write(
            to: repository.appendingPathComponent("tracked.generated")
        )
        _ = try await runner.run(
            arguments: ["add", ".gitignore"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["add", "-f", "tracked.generated"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["commit", "-m", "Add ignore rules"],
            workingDirectory: repository
        )
        let buildDirectory = repository.appendingPathComponent(
            "build",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: buildDirectory,
            withIntermediateDirectories: true
        )
        let ignoredBuildFile = buildDirectory.appendingPathComponent("output.o")
        let ignoredGeneratedFile = repository.appendingPathComponent("cache.generated")
        try Data("object\n".utf8).write(to: ignoredBuildFile)
        try Data("generated\n".utf8).write(to: ignoredGeneratedFile)

        let service = GitRepositoryService(runner: runner)
        let worktrees = try await service.listWorktrees(at: repository)
        let worktree = try XCTUnwrap(worktrees.first)
        let ignoredFilesAreRelevant = try await service
            .containsGitRelevantWorkingTreeEvent(
                worktree: worktree,
                absolutePaths: [ignoredBuildFile.path, ignoredGeneratedFile.path]
            )
        let removedIgnoredFileIsRelevant = try await service
            .containsGitRelevantWorkingTreeEvent(
                worktree: worktree,
                absolutePaths: [
                    buildDirectory.appendingPathComponent("removed.o").path
                ]
            )
        let trackedFileIsRelevant = try await service
            .containsGitRelevantWorkingTreeEvent(
                worktree: worktree,
                absolutePaths: [
                    repository.appendingPathComponent("tracked.generated").path
                ]
            )
        let mixedFilesAreRelevant = try await service
            .containsGitRelevantWorkingTreeEvent(
                worktree: worktree,
                absolutePaths: [
                    repository.appendingPathComponent("README.md").path,
                    ignoredBuildFile.path
                ]
            )

        XCTAssertFalse(ignoredFilesAreRelevant)
        XCTAssertFalse(removedIgnoredFileIsRelevant)
        XCTAssertTrue(trackedFileIsRelevant)
        XCTAssertTrue(mixedFilesAreRelevant)
    }

    private func makeRepository(
        at repository: URL,
        initialContents: String = "base\n"
    ) async throws {
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        let runner = GitCommandRunner()
        _ = try await runner.run(arguments: ["init", "-b", "main"], workingDirectory: repository)
        _ = try await runner.run(
            arguments: ["config", "user.name", "AgentGit Tests"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["config", "user.email", "agentgit-tests@example.invalid"],
            workingDirectory: repository
        )
        try Data(initialContents.utf8).write(
            to: repository.appendingPathComponent("README.md")
        )
        _ = try await runner.run(arguments: ["add", "README.md"], workingDirectory: repository)
        _ = try await runner.run(
            arguments: ["commit", "-m", "Initial commit"],
            workingDirectory: repository
        )
    }

    private func revision(
        _ revision: String,
        in repository: URL,
        using runner: GitCommandRunner
    ) async throws -> String {
        String(
            decoding: try await runner.run(
                arguments: ["rev-parse", revision],
                workingDirectory: repository
            ),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func testDiscardRecoveryStore(
        in container: URL
    ) -> GitDiscardRecoveryStore {
        GitDiscardRecoveryStore(
            destination: .directory(
                container.appendingPathComponent("recovery", isDirectory: true)
            )
        )
    }

    private func recoveredItem(
        relativePath: String,
        in recoveryRoot: URL
    ) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(
            at: recoveryRoot,
            includingPropertiesForKeys: nil
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let suffix = "/Files/\(relativePath)"
        for case let fileURL as URL in enumerator {
            if fileURL.path.hasSuffix(suffix) {
                return fileURL
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func assertMixedEncodingDiffs(
        _ diffs: [GitFileDiff],
        expectedScope: GitDiffScope,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(Set(diffs.map(\.change.path)), ["legacy.txt", "normal.txt"], file: file, line: line)
        let normal = diffs.first(where: { $0.change.path == "normal.txt" })
        XCTAssertEqual(normal?.scope, expectedScope, file: file, line: line)
        XCTAssertEqual(normal?.state, .textual, file: file, line: line)
        XCTAssertTrue(
            normal?.hunks.flatMap(\.lines).contains(where: {
                $0.kind == .addition && $0.content == "after"
            }) == true,
            file: file,
            line: line
        )
        guard let legacy = diffs.first(where: { $0.change.path == "legacy.txt" }) else {
            XCTFail("Missing legacy.txt diff", file: file, line: line)
            return
        }
        assertUnsupportedEncoding(
            legacy,
            expectedScope: expectedScope,
            file: file,
            line: line
        )
    }

    private func assertUnsupportedEncoding(
        _ diff: GitFileDiff,
        expectedScope: GitDiffScope,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(diff.scope, expectedScope, file: file, line: line)
        XCTAssertEqual(
            diff.state,
            .unavailable("Text diff uses an unsupported encoding."),
            file: file,
            line: line
        )
        XCTAssertTrue(diff.hunks.isEmpty, file: file, line: line)
        XCTAssertEqual(diff.addedLineCount, 1, file: file, line: line)
        XCTAssertEqual(diff.deletedLineCount, 1, file: file, line: line)
    }
}
