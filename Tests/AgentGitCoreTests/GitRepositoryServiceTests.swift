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
        _ = try runner.run(arguments: ["init", "-b", "main"], workingDirectory: repository)
        _ = try runner.run(
            arguments: ["config", "user.name", "AgentGit Tests"],
            workingDirectory: repository
        )
        _ = try runner.run(
            arguments: ["config", "user.email", "agentgit-tests@example.invalid"],
            workingDirectory: repository
        )

        let trackedFile = repository.appendingPathComponent("README.md")
        try Data("base\n".utf8).write(to: trackedFile)
        _ = try runner.run(arguments: ["add", "README.md"], workingDirectory: repository)
        _ = try runner.run(
            arguments: ["commit", "-m", "Initial commit"],
            workingDirectory: repository
        )
        _ = try runner.run(
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
}
