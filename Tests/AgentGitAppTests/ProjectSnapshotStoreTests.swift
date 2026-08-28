import AgentGitCore
@testable import AgentGitApp
import Foundation
import XCTest

final class ProjectSnapshotStoreTests: XCTestCase {
    func testRoundTripsSuccessfulSnapshotsWithPrivateFilePermissions() async throws {
        let container = cacheContainer(name: "round-trip")
        let fileURL = container.appendingPathComponent("snapshots.json")
        defer { try? FileManager.default.removeItem(at: container) }
        let snapshot = makeProjectSnapshot()
        let store = ProjectSnapshotStore(fileURL: fileURL)

        try await store.save(
            projectIDs: [snapshot.id],
            snapshots: [snapshot],
            eventID: 123_456,
            completeProjectIDs: [snapshot.id]
        )

        let restoredStore = ProjectSnapshotStore(fileURL: fileURL)
        let restored = try XCTUnwrap(restoredStore.initialPayload)
        XCTAssertEqual(restored.eventID, 123_456)
        XCTAssertEqual(restored.projects, [snapshot])
        XCTAssertEqual(restored.completeProjectIDs, [snapshot.id])
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let backupURL = fileURL.deletingPathExtension()
            .appendingPathExtension("backup")
            .appendingPathExtension("json")
        let backupAttributes = try FileManager.default.attributesOfItem(
            atPath: backupURL.path
        )
        XCTAssertEqual(
            (backupAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
    }

    func testFailedRefreshKeepsLastSuccessfulWorktreeSnapshot() async throws {
        let container = cacheContainer(name: "preserve-success")
        let fileURL = container.appendingPathComponent("snapshots.json")
        defer { try? FileManager.default.removeItem(at: container) }
        let successful = makeProjectSnapshot()
        let store = ProjectSnapshotStore(fileURL: fileURL)
        try await store.save(
            projectIDs: [successful.id],
            snapshots: [successful],
            eventID: 100,
            completeProjectIDs: [successful.id]
        )
        let previousWorktree = try XCTUnwrap(successful.worktrees.first)
        let failedWorktree = GitWorktreeSnapshot(
            worktree: previousWorktree.worktree,
            status: .clean,
            diffStat: .zero,
            lastActivityAt: .distantPast,
            errorMessage: "status timed out",
            hasUsableState: false,
            eventWatchURLs: previousWorktree.eventWatchURLs
        )
        let failed = GitProjectSnapshot(
            project: successful.project,
            worktrees: [failedWorktree],
            refreshedAt: successful.refreshedAt.addingTimeInterval(60)
        )

        try await store.save(
            projectIDs: [failed.id],
            snapshots: [failed],
            eventID: 101,
            completeProjectIDs: [failed.id]
        )

        let restoredStore = ProjectSnapshotStore(fileURL: fileURL)
        let restored = try XCTUnwrap(restoredStore.initialPayload)
        XCTAssertEqual(restored.eventID, 101)
        XCTAssertEqual(restored.projects.first?.worktrees, successful.worktrees)
    }

    func testMigratesVersionOneCacheWithoutDiscardingSnapshots() throws {
        let container = cacheContainer(name: "version-one")
        let fileURL = container.appendingPathComponent("snapshots.json")
        defer { try? FileManager.default.removeItem(at: container) }
        let snapshot = makeProjectSnapshot()
        let legacy = LegacyProjectSnapshotCachePayload(
            version: 1,
            eventID: 654_321,
            projects: [snapshot]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        try encoder.encode(legacy).write(to: fileURL)

        let store = ProjectSnapshotStore(fileURL: fileURL)
        let restored = try XCTUnwrap(store.initialPayload)

        XCTAssertEqual(restored.version, ProjectSnapshotCachePayload.schemaVersion)
        XCTAssertEqual(restored.eventID, legacy.eventID)
        XCTAssertEqual(restored.projects, legacy.projects)
        XCTAssertEqual(restored.completeProjectIDs, [snapshot.id])
    }

    func testRecoversPreviousValidSnapshotWhenPrimaryFileIsDamaged() async throws {
        let container = cacheContainer(name: "backup-recovery")
        let fileURL = container.appendingPathComponent("snapshots.json")
        defer { try? FileManager.default.removeItem(at: container) }
        let first = makeProjectSnapshot()
        let second = GitProjectSnapshot(
            project: first.project,
            worktrees: first.worktrees,
            refreshedAt: first.refreshedAt.addingTimeInterval(60)
        )
        let store = ProjectSnapshotStore(fileURL: fileURL)
        try await store.save(
            projectIDs: [first.id],
            snapshots: [first],
            eventID: 100,
            completeProjectIDs: [first.id]
        )
        try await store.save(
            projectIDs: [second.id],
            snapshots: [second],
            eventID: 101,
            completeProjectIDs: [second.id]
        )
        try Data("damaged cache".utf8).write(to: fileURL, options: .atomic)

        let recoveredStore = ProjectSnapshotStore(fileURL: fileURL)
        let recovered = try XCTUnwrap(recoveredStore.initialPayload)

        XCTAssertEqual(recovered.eventID, 100)
        XCTAssertEqual(recovered.projects, [first])
        XCTAssertNil(recoveredStore.initialErrorMessage)
        XCTAssertEqual(
            try ProjectSnapshotStore.load(from: fileURL),
            recovered
        )
    }

    func testRecoversBackupWhenPrimaryContainsDuplicateProjectIDs() async throws {
        let container = cacheContainer(name: "duplicate-project-recovery")
        let fileURL = container.appendingPathComponent("snapshots.json")
        defer { try? FileManager.default.removeItem(at: container) }
        let snapshot = makeProjectSnapshot()
        let store = ProjectSnapshotStore(fileURL: fileURL)
        try await store.save(
            projectIDs: [snapshot.id],
            snapshots: [snapshot],
            eventID: 100,
            completeProjectIDs: [snapshot.id]
        )
        let invalid = ProjectSnapshotCachePayload(
            eventID: 101,
            projects: [snapshot, snapshot],
            completeProjectIDs: [snapshot.id]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(invalid).write(to: fileURL, options: .atomic)

        let recoveredStore = ProjectSnapshotStore(fileURL: fileURL)
        let recovered = try XCTUnwrap(recoveredStore.initialPayload)

        XCTAssertEqual(recovered.eventID, 100)
        XCTAssertEqual(recovered.projects, [snapshot])
        XCTAssertNil(recoveredStore.initialErrorMessage)
        XCTAssertEqual(try ProjectSnapshotStore.load(from: fileURL), recovered)
    }

    func testRejectsDuplicateWorktreeIDsWithoutCrashing() throws {
        let container = cacheContainer(name: "duplicate-worktree")
        let fileURL = container.appendingPathComponent("snapshots.json")
        defer { try? FileManager.default.removeItem(at: container) }
        let snapshot = makeProjectSnapshot()
        let duplicateWorktrees = GitProjectSnapshot(
            project: snapshot.project,
            worktrees: snapshot.worktrees + snapshot.worktrees,
            refreshedAt: snapshot.refreshedAt
        )
        let invalid = ProjectSnapshotCachePayload(
            eventID: 101,
            projects: [duplicateWorktrees],
            completeProjectIDs: [snapshot.id]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        try encoder.encode(invalid).write(to: fileURL, options: .atomic)

        let store = ProjectSnapshotStore(fileURL: fileURL)

        XCTAssertNil(store.initialPayload)
        XCTAssertEqual(
            store.initialErrorMessage,
            "Project snapshot cache contains duplicate worktree ID: "
                + "\(snapshot.worktrees[0].id)."
        )
    }

    func testReadsLegacyNestedSnapshotFieldsWithoutDiscardingProject() throws {
        let container = cacheContainer(name: "nested-compatibility")
        let fileURL = container.appendingPathComponent("snapshots.json")
        defer { try? FileManager.default.removeItem(at: container) }
        let snapshot = makeProjectSnapshot()
        let payload = ProjectSnapshotCachePayload(
            eventID: 777,
            projects: [snapshot],
            completeProjectIDs: [snapshot.id]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let encoded = try encoder.encode(payload)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var projects = try XCTUnwrap(object["projects"] as? [[String: Any]])
        projects[0].removeValue(forKey: "refreshedAt")
        var worktrees = try XCTUnwrap(projects[0]["worktrees"] as? [[String: Any]])
        worktrees[0].removeValue(forKey: "refreshedAt")
        worktrees[0].removeValue(forKey: "hasUsableState")
        worktrees[0].removeValue(forKey: "eventWatchURLs")
        projects[0]["worktrees"] = worktrees
        object["projects"] = projects
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: object).write(to: fileURL)

        let store = ProjectSnapshotStore(fileURL: fileURL)
        let restored = try XCTUnwrap(store.initialPayload)
        let restoredWorktree = try XCTUnwrap(restored.projects.first?.worktrees.first)

        XCTAssertEqual(restored.eventID, payload.eventID)
        XCTAssertEqual(restored.completeProjectIDs, [snapshot.id])
        XCTAssertTrue(restoredWorktree.hasUsableState)
        XCTAssertEqual(restoredWorktree.eventWatchURLs, [snapshot.project.rootURL])
        XCTAssertNil(restoredWorktree.refreshedAt)
        XCTAssertEqual(
            restored.projects.first?.refreshedAt,
            restoredWorktree.lastActivityAt
        )
    }

    private func cacheContainer(name: String) -> URL {
        URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/snapshot-cache-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func makeProjectSnapshot() -> GitProjectSnapshot {
        let project = GitProject(rootURL: URL(fileURLWithPath: "/repositories/sample"))
        let worktree = GitWorktree(
            rootURL: project.rootURL,
            headOID: String(repeating: "a", count: 40),
            branchRef: "refs/heads/main",
            isBare: false,
            isDetached: false,
            lockedReason: nil,
            prunableReason: nil
        )
        let change = GitFileChange(
            path: "Sources/App.swift",
            originalPath: nil,
            indexStatus: ".",
            worktreeStatus: "M",
            kind: .ordinary
        )
        return GitProjectSnapshot(
            project: project,
            worktrees: [
                GitWorktreeSnapshot(
                    worktree: worktree,
                    status: GitStatusSnapshot(
                        changes: [change],
                        branch: GitBranchStatus(
                            upstreamRef: "origin/main",
                            aheadCount: 1,
                            behindCount: 2
                        ),
                        headOID: worktree.headOID,
                        branchHead: "main"
                    ),
                    diffStat: GitDiffStat(addedLineCount: 3, deletedLineCount: 1),
                    lastActivityAt: Date(timeIntervalSince1970: 200_000),
                    errorMessage: nil,
                    eventWatchURLs: [
                        project.rootURL,
                        project.rootURL.appendingPathComponent(".git", isDirectory: true)
                    ]
                )
            ],
            refreshedAt: Date(timeIntervalSince1970: 200_100)
        )
    }
}

private struct LegacyProjectSnapshotCachePayload: Codable {
    let version: Int
    let eventID: UInt64
    let projects: [GitProjectSnapshot]
}
