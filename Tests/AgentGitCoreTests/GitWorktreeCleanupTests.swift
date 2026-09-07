import Foundation
import XCTest
@testable import AgentGitCore

final class GitWorktreeCleanupTests: XCTestCase {
    func testRemovesOldCleanWorktreeAndRetainsUnpushedBranch() async throws {
        let fixture = try await CleanupFixture.make()
        defer { fixture.dispose() }
        let worktree = try await fixture.addWorktree("old clean")
        _ = try await fixture.git(["commit", "--allow-empty", "-m", "Local work"], at: worktree.rootURL)
        let current = try await fixture.member(worktree.rootURL)
        let result = try await fixture.remove(current)
        XCTAssertEqual(result, .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.id))
        let branch = try await fixture.git(["rev-parse", "refs/heads/old-clean"])
        XCTAssertEqual(String(decoding: branch, as: UTF8.self).trimmingCharacters(in: .newlines), current.headOID)
        let members = try await fixture.service.listWorktrees(at: fixture.repository)
        XCTAssertEqual(members.map(\.id), [fixture.repository.path])
    }

    func testPreservesDirtyUntrackedIgnoredAndHiddenIndexChanges() async throws {
        let fixture = try await CleanupFixture.make()
        defer { fixture.dispose() }
        for kind in ["tracked", "staged", "untracked", "ignored", "assume-unchanged", "skip-worktree"] {
            let worktree = try await fixture.addWorktree(kind)
            let path: String
            switch kind {
            case "untracked": path = "new.txt"
            case "ignored": path = "secret.local"
            default: path = "file.txt"
            }
            if kind == "assume-unchanged" || kind == "skip-worktree" {
                _ = try await fixture.git(["update-index", "--\(kind)", "file.txt"], at: worktree.rootURL)
            }
            let contents = Data("valuable local contents".utf8)
            try contents.write(to: worktree.rootURL.appendingPathComponent(path))
            if kind == "staged" {
                _ = try await fixture.git(["add", path], at: worktree.rootURL)
            }
            let result = try await fixture.remove(worktree)
            XCTAssertNotEqual(result, .removed, kind)
            XCTAssertEqual(try Data(contentsOf: worktree.rootURL.appendingPathComponent(path)), contents, kind)
        }
    }

    func testPreservesMainLockedAndInProgressWorktrees() async throws {
        let fixture = try await CleanupFixture.make()
        defer { fixture.dispose() }
        let main = try await fixture.member(fixture.repository)
        let mainResult = try await fixture.remove(main)
        XCTAssertNotEqual(mainResult, .removed)
        let locked = try await fixture.addWorktree("locked")
        _ = try await fixture.git(["worktree", "lock", locked.id])
        let lockedResult = try await fixture.remove(locked)
        XCTAssertNotEqual(lockedResult, .removed)
        let merging = try await fixture.addWorktree("merging")
        let gitDirectory = try await fixture.gitDirectory(merging)
        try Data("merge".utf8).write(to: gitDirectory.appendingPathComponent("MERGE_HEAD"))
        let mergeResult = try await fixture.remove(merging)
        XCTAssertNotEqual(mergeResult, .removed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: merging.id))
    }

    func testPreservesRecentlyCreatedWorktreeWithOldCommitAndNoReflog() async throws {
        let fixture = try await CleanupFixture.make()
        defer { fixture.dispose() }
        _ = try await fixture.git(["config", "core.logAllRefUpdates", "false"])
        let worktree = try await fixture.addWorktree("recent")
        let result = try await GitWorktreeCleanupService().removeIfInactive(
            worktree, project: fixture.project,
            inactiveSince: Date().addingTimeInterval(-7 * 86_400)
        )
        XCTAssertNotEqual(result, .removed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.id))
    }

    func testDetachedHeadRequiresAnotherRef() async throws {
        let fixture = try await CleanupFixture.make()
        defer { fixture.dispose() }
        let reachable = try await fixture.addWorktree("reachable", detached: true)
        let reachableResult = try await fixture.remove(reachable)
        XCTAssertEqual(reachableResult, .removed)
        let unique = try await fixture.addWorktree("unique", detached: true)
        _ = try await fixture.git(["commit", "--allow-empty", "-m", "Only detached HEAD retains this"], at: unique.rootURL)
        let current = try await fixture.member(unique.rootURL)
        let uniqueResult = try await fixture.remove(current)
        XCTAssertNotEqual(uniqueResult, .removed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unique.id))
    }

    func testPreservesRecentlyTouchedCleanFileAndCleanSubmodule() async throws {
        let fixture = try await CleanupFixture.make()
        defer { fixture.dispose() }
        let touched = try await fixture.addWorktree("touched")
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.cutoff.addingTimeInterval(60)],
            ofItemAtPath: touched.rootURL.appendingPathComponent("file.txt").path
        )
        let touchedResult = try await fixture.remove(touched)
        XCTAssertNotEqual(touchedResult, .removed)
        let submodule = try await fixture.addWorktree("submodule")
        _ = try await fixture.git([
            "-c", "protocol.file.allow=always", "submodule", "add", fixture.repository.path, "nested"
        ], at: submodule.rootURL)
        _ = try await fixture.git(["commit", "-m", "Add submodule"], at: submodule.rootURL)
        let current = try await fixture.member(submodule.rootURL)
        let submoduleResult = try await fixture.remove(current)
        XCTAssertNotEqual(submoduleResult, .removed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: submodule.rootURL.appendingPathComponent("nested/file.txt").path))
    }

    func testRechecksChangesAndCallerProtectionImmediatelyBeforeRemoval() async throws {
        let fixture = try await CleanupFixture.make()
        defer { fixture.dispose() }
        let worktree = try await fixture.addWorktree("changed-during-check")
        let file = worktree.rootURL.appendingPathComponent("file.txt")
        let result = try await GitWorktreeCleanupService().removeIfInactive(
            worktree, project: fixture.project, inactiveSince: fixture.cutoff
        ) {
            try Data("changed during cleanup".utf8).write(to: file)
            return true
        }
        XCTAssertNotEqual(result, .removed)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed during cleanup")
        let protected = try await fixture.addWorktree("in-use")
        let protectedResult = try await GitWorktreeCleanupService().removeIfInactive(
            protected, project: fixture.project, inactiveSince: fixture.cutoff,
            willRemove: { false }
        )
        XCTAssertNotEqual(protectedResult, .removed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: protected.id))
    }
}

private struct CleanupFixture: Sendable {
    let container: URL
    let repository: URL
    let service = GitRepositoryService()
    let cutoff = Date().addingTimeInterval(3 * 86_400)
    var project: GitProject { GitProject(rootURL: repository) }

    static func make() async throws -> CleanupFixture {
        let container = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("agentgit-cleanup-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let fixture = CleanupFixture(container: container, repository: repository)
        _ = try await fixture.git(["init", "-b", "main"])
        _ = try await fixture.git(["config", "user.name", "AgentGit Tests"])
        _ = try await fixture.git(["config", "user.email", "agentgit-tests@example.invalid"])
        try Data("base\n".utf8).write(to: repository.appendingPathComponent("file.txt"))
        try Data("*.local\n".utf8).write(to: repository.appendingPathComponent(".gitignore"))
        _ = try await fixture.git(["add", "."])
        _ = try await GitCommandRunner().run(
            arguments: ["commit", "-m", "Initial commit"], workingDirectory: repository,
            environment: ["GIT_AUTHOR_DATE": "2001-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2001-01-01T00:00:00Z"]
        )
        return fixture
    }

    func addWorktree(_ name: String, detached: Bool = false) async throws -> GitWorktree {
        let url = container.appendingPathComponent(name)
        let options = detached ? ["--detach"] : ["-b", name.replacingOccurrences(of: " ", with: "-")]
        _ = try await git(["worktree", "add"] + options + [url.path, "HEAD"])
        return try await member(url)
    }

    func member(_ url: URL) async throws -> GitWorktree {
        let members = try await service.listWorktrees(at: repository)
        return try XCTUnwrap(members.first(where: { $0.id == url.path }))
    }

    func gitDirectory(_ worktree: GitWorktree) async throws -> URL {
        let data = try await git(["rev-parse", "--absolute-git-dir"], at: worktree.rootURL)
        return URL(fileURLWithPath: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
    }

    func git(_ arguments: [String], at url: URL? = nil) async throws -> Data {
        try await GitCommandRunner().run(arguments: arguments, workingDirectory: url ?? repository)
    }

    func remove(_ worktree: GitWorktree) async throws -> GitWorktreeCleanupResult {
        try await GitWorktreeCleanupService().removeIfInactive(worktree, project: project, inactiveSince: cutoff)
    }

    func dispose() { try? FileManager.default.removeItem(at: container) }
}
