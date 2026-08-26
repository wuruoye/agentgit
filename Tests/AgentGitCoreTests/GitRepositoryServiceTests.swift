import Foundation
import XCTest
@testable import AgentGitCore

final class GitRepositoryServiceTests: XCTestCase {
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

        let recentFile = featureWorktree.appendingPathComponent("recent.txt")
        try Data("recent\n".utf8).write(to: recentFile)
        let futureDate = Date().addingTimeInterval(3_600)
        try FileManager.default.setAttributes(
            [.modificationDate: futureDate],
            ofItemAtPath: recentFile.path
        )

        let snapshot = try await GitRepositoryService().loadProject(at: repository)

        XCTAssertEqual(snapshot.worktrees.count, 2)
        XCTAssertEqual(snapshot.worktrees.first?.worktree.rootURL.path, featureWorktree.path)
        XCTAssertEqual(snapshot.worktrees.first?.status.untrackedFileCount, 1)
        XCTAssertEqual(snapshot.worktrees.last?.worktree.branchName, "main")
    }

    func testStatusRefreshDoesNotTouchIndex() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-locks-test-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        try await makeRepository(at: repository)

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
        XCTAssertEqual(
            indexDate.timeIntervalSince1970,
            staleDate.timeIntervalSince1970,
            accuracy: 1
        )
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

        let service = GitRepositoryService()
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

        let service = GitRepositoryService()
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
    }

    func testStagesAndDiscardsSelectedLinesInUntrackedFile() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-untracked-lines-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        try await makeRepository(at: repository)

        let service = GitRepositoryService()
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
}
