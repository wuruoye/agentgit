import Foundation
import XCTest
@testable import AgentGitCore

final class GitDiffTests: XCTestCase {
    func testParsesHunkLineNumbersAndChangeCounts() throws {
        let change = GitFileChange(
            path: "Sources/Feature.swift",
            originalPath: nil,
            indexStatus: ".",
            worktreeStatus: "M",
            kind: .ordinary
        )
        let patch = """
        diff --git a/Sources/Feature.swift b/Sources/Feature.swift
        index 1111111..2222222 100644
        --- a/Sources/Feature.swift
        +++ b/Sources/Feature.swift
        @@ -1,3 +1,4 @@ func feature() {
         first
        -old
        +new
        +added
         last
        \\ No newline at end of file
        """

        let diff = try UnifiedDiffParser.parse(
            Data(patch.utf8),
            change: change,
            scope: .working
        )

        XCTAssertEqual(diff.hunks.count, 1)
        XCTAssertEqual(diff.addedLineCount, 2)
        XCTAssertEqual(diff.deletedLineCount, 1)
        XCTAssertEqual(diff.hunks[0].lines[0].oldLineNumber, 1)
        XCTAssertEqual(diff.hunks[0].lines[0].newLineNumber, 1)
        XCTAssertEqual(diff.hunks[0].lines[1].oldLineNumber, 2)
        XCTAssertNil(diff.hunks[0].lines[1].newLineNumber)
        XCTAssertNil(diff.hunks[0].lines[2].oldLineNumber)
        XCTAssertEqual(diff.hunks[0].lines[2].newLineNumber, 2)
        XCTAssertEqual(diff.hunks[0].lines.last?.kind, .metadata)
    }

    func testCreatesReviewableDiffForUntrackedTextFile() {
        let change = GitFileChange(
            path: "notes.txt",
            originalPath: nil,
            indexStatus: "?",
            worktreeStatus: "?",
            kind: .untracked
        )

        let diff = UnifiedDiffParser.addedFile(
            data: Data("one\ntwo\n".utf8),
            change: change
        )

        XCTAssertEqual(diff.hunks.count, 1)
        XCTAssertEqual(diff.addedLineCount, 2)
        XCTAssertEqual(diff.hunks[0].lines.map(\.newLineNumber), [1, 2])
    }

    func testLoadsWorkingStagedAndUntrackedDiffsFromGit() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-diff-test-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
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

        let trackedFile = repository.appendingPathComponent("file.txt")
        try Data("base\n".utf8).write(to: trackedFile)
        _ = try await runner.run(arguments: ["add", "file.txt"], workingDirectory: repository)
        _ = try await runner.run(
            arguments: ["commit", "-m", "Initial commit"],
            workingDirectory: repository
        )

        try Data("base\nstaged\n".utf8).write(to: trackedFile)
        _ = try await runner.run(arguments: ["add", "file.txt"], workingDirectory: repository)
        try Data("base\nstaged\nworking\n".utf8).write(to: trackedFile)
        try Data("untracked one\nuntracked two\n".utf8).write(
            to: repository.appendingPathComponent("new.txt")
        )

        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first)
        let trackedChange = try XCTUnwrap(
            worktree.status.changes.first { $0.path == "file.txt" }
        )
        let untrackedChange = try XCTUnwrap(
            worktree.status.changes.first { $0.path == "new.txt" }
        )

        let workingDiff = try await service.loadDiff(
            worktree: worktree.worktree,
            change: trackedChange,
            scope: .working
        )
        let stagedDiff = try await service.loadDiff(
            worktree: worktree.worktree,
            change: trackedChange,
            scope: .staged
        )
        let untrackedDiff = try await service.loadDiff(
            worktree: worktree.worktree,
            change: untrackedChange,
            scope: .working
        )

        XCTAssertEqual(workingDiff.addedLineCount, 1)
        XCTAssertEqual(workingDiff.hunks[0].lines.first(where: { $0.kind == .addition })?.content, "working")
        XCTAssertEqual(stagedDiff.addedLineCount, 1)
        XCTAssertEqual(stagedDiff.hunks[0].lines.first(where: { $0.kind == .addition })?.content, "staged")
        XCTAssertEqual(untrackedDiff.addedLineCount, 2)
    }
}
