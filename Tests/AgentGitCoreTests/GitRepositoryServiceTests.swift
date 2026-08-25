import Foundation
import XCTest
@testable import AgentGitCore

final class GitRepositoryServiceTests: XCTestCase {
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
