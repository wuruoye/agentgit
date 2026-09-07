import AgentGitCore
import AgentGitIntegrationShared
import Foundation
import XCTest
@testable import AgentGitApp

@MainActor
final class WorktreeCleanupTests: XCTestCase {
    func testCleanupIsOptInAndPreferencesPersist() async throws {
        let fixture = try await AppCleanupFixture.make()
        defer { fixture.dispose() }
        let model = fixture.model()
        XCTAssertFalse(model.cleanupSettings.isEnabled)
        XCTAssertEqual(model.cleanupSettings.inactiveDays, 7)
        XCTAssertEqual(model.cleanupSettings.intervalHours, 1)
        await model.runWorktreeCleanupIfNeeded(now: fixture.now)
        XCTAssertNil(model.cleanupReport)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths["old"]!.path))
        model.cleanupSettings = WorktreeCleanupSettings(isEnabled: true, intervalHours: 24, inactiveDays: 14)
        let restored = fixture.model()
        XCTAssertEqual(restored.cleanupSettings, model.cleanupSettings)
    }

    func testCleanupKeepsProtectedWorktreesUpdatesSnapshotsAndRespectsIntervalAcrossRestart() async throws {
        let fixture = try await AppCleanupFixture.make()
        defer { fixture.dispose() }
        let recent = fixture.paths["recent"]!.path
        fixture.defaults.set([recent: fixture.now], forKey: "agentgit.worktree-last-used")
        let model = fixture.model()
        model.cleanupSettings.isEnabled = true
        await model.refreshAll()
        model.selectedWorktreeID = fixture.paths["selected"]!.path
        model.pinnedWorktreeIDs = [fixture.paths["pinned"]!.path]
        _ = try fixture.associations.upsert(AgentAssociation(
            provider: .codex, sessionID: UUID().uuidString,
            worktreePath: fixture.paths["agent"]!.path, title: "Active session", updatedAt: fixture.now
        ))
        // Exercise the background path with an association added after the UI cache loaded.
        model.setApplicationActive(false)
        await model.runWorktreeCleanupIfNeeded(now: fixture.now)
        let report = try XCTUnwrap(model.cleanupReport)
        XCTAssertEqual(report.removedPaths, [fixture.paths["old"]!.path])
        XCTAssertTrue(report.errors.isEmpty, report.errors.joined(separator: "\n"))
        for name in ["selected", "pinned", "recent", "agent"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths[name]!.path), name)
        }
        XCTAssertFalse(model.projects.flatMap { $0.snapshot?.worktrees ?? [] }.contains { $0.id == fixture.paths["old"]!.path })
        let added = try await fixture.addWorktree("next")
        let restored = fixture.model()
        XCTAssertEqual(restored.cleanupReport?.removedPaths, report.removedPaths)
        await restored.runWorktreeCleanupIfNeeded(now: fixture.now.addingTimeInterval(1_800))
        XCTAssertTrue(FileManager.default.fileExists(atPath: added.path))
        await restored.runWorktreeCleanupIfNeeded(now: fixture.now.addingTimeInterval(3_601))
        XCTAssertFalse(FileManager.default.fileExists(atPath: added.path))
    }

    func testCorruptAssociationStoragePreventsAutomaticRemoval() async throws {
        let fixture = try await AppCleanupFixture.make()
        defer { fixture.dispose() }
        try Data("{bad-json".utf8).write(to: fixture.associationURL)
        let model = fixture.model()
        model.cleanupSettings.isEnabled = true
        await model.runWorktreeCleanupIfNeeded(now: fixture.now)
        XCTAssertFalse(try XCTUnwrap(model.cleanupReport).errors.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths["old"]!.path))
    }

    func testEnabledCleanupStartsAutomaticallyWhenProjectsLoad() async throws {
        let fixture = try await AppCleanupFixture.make()
        defer { fixture.dispose() }
        let model = fixture.model()
        model.cleanupSettings.isEnabled = true
        await model.loadProjectsIfNeeded()
        model.setApplicationActive(false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.cleanupReport == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(model.cleanupReport)
        XCTAssertTrue(model.cleanupReport?.removedPaths.isEmpty == true)
        await model.prepareForTermination()
    }
}

@MainActor
private struct AppCleanupFixture {
    let container: URL
    let repository: URL
    let defaults: UserDefaults
    let suiteName: String
    let paths: [String: URL]
    let now = Date().addingTimeInterval(10 * 86_400)
    var associationURL: URL { container.appendingPathComponent("associations.json") }
    var associations: AgentAssociationStore { AgentAssociationStore(storeURL: associationURL) }

    static func make() async throws -> AppCleanupFixture {
        let container = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("agentgit-app-cleanup-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let runner = GitCommandRunner()
        for arguments in [
            ["init", "-b", "main"], ["config", "user.name", "AgentGit Tests"],
            ["config", "user.email", "agentgit-tests@example.invalid"],
            ["commit", "--allow-empty", "-m", "Initial commit"]
        ] {
            _ = try await runner.run(arguments: arguments, workingDirectory: repository)
        }
        var paths: [String: URL] = [:]
        for name in ["old", "selected", "pinned", "recent", "agent"] {
            let url = container.appendingPathComponent(name)
            _ = try await runner.run(arguments: ["worktree", "add", "-b", name, url.path], workingDirectory: repository)
            paths[name] = url
        }
        let suiteName = "AgentGitAppTests.Cleanup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set([repository.path], forKey: "agentgit.project-paths")
        return AppCleanupFixture(container: container, repository: repository, defaults: defaults, suiteName: suiteName, paths: paths)
    }

    func model() -> AppModel {
        AppModel(
            defaults: defaults,
            agentAssociations: AgentAssociationController(
                store: associations,
                auditStore: AgentRegistrationAuditStore(storeURL: container.appendingPathComponent("audit.json"))
            )
        )
    }

    func addWorktree(_ name: String) async throws -> URL {
        let url = container.appendingPathComponent(name)
        _ = try await GitCommandRunner().run(
            arguments: ["worktree", "add", "-b", name, url.path], workingDirectory: repository
        )
        return url
    }

    func dispose() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: container)
    }
}
