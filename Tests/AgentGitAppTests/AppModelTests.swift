import AgentGitCore
import AgentGitIntegrationShared
import AppKit
import CoreServices
import SwiftUI
import XCTest
@testable import AgentGitApp

@MainActor
final class AppModelTests: XCTestCase {
    func testVisualTestAppearanceRequiresExplicitSupportedValue() {
        XCTAssertEqual(
            requestedVisualTestAppearance(
                environment: ["AGENTGIT_VISUAL_TEST_APPEARANCE": "LIGHT"]
            ),
            .aqua
        )
        XCTAssertEqual(
            requestedVisualTestAppearance(
                environment: ["AGENTGIT_VISUAL_TEST_APPEARANCE": "dark"]
            ),
            .darkAqua
        )
        XCTAssertNil(requestedVisualTestAppearance(environment: [:]))
        XCTAssertNil(
            requestedVisualTestAppearance(
                environment: ["AGENTGIT_VISUAL_TEST_APPEARANCE": "automatic"]
            )
        )
    }

    func testDiffSettingsPersistAcrossModelInstances() throws {
        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(defaults: defaults)
        model.diffLayout = .sideBySide
        model.diffOptions = GitDiffOptions(
            context: .lines(25),
            ignoresWhitespace: true
        )

        let restored = AppModel(defaults: defaults)
        XCTAssertEqual(restored.diffLayout, .sideBySide)
        XCTAssertEqual(restored.diffOptions.context, .lines(25))
        XCTAssertTrue(restored.diffOptions.ignoresWhitespace)
    }

    func testUnknownStoredDiffSettingsUseDefaults() throws {
        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("unknown", forKey: "agentgit.diff-context")
        defaults.set("unknown", forKey: "agentgit.diff-layout")

        let model = AppModel(defaults: defaults)
        XCTAssertEqual(model.diffLayout, .unified)
        XCTAssertEqual(model.diffOptions.context, .lines(3))
    }

    func testApplicationActivityControlsBackgroundRepositoryWork() throws {
        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults)
        defer { model.setApplicationActive(false) }

        XCTAssertTrue(model.isApplicationActive)
        model.setApplicationActive(false)
        XCTAssertFalse(model.isApplicationActive)
        model.setApplicationActive(true)
        XCTAssertTrue(model.isApplicationActive)
    }

    func testBackgroundLaunchLoadsProjectsWhenActivated() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: container) }
        try await initializeRepository(at: container, using: GitCommandRunner())
        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([container.path], forKey: "agentgit.project-paths")
        let model = AppModel(defaults: defaults)
        defer { model.setApplicationActive(false) }
        model.setApplicationActive(false)
        await model.loadProjectsIfNeeded()
        XCTAssertNil(model.projects.first?.snapshot)
        model.setApplicationActive(true)
        let deadline = Date().addingTimeInterval(5)
        while model.projects.first?.snapshot == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.projects.first?.snapshot?.worktrees.count, 1)
    }

    func testAgentPersistenceRepairRecoversBothCorruptStores() throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/agent-storage-repair-\(UUID().uuidString)",
            isDirectory: true
        )
        let associationURL = container.appendingPathComponent("associations.json")
        let auditURL = container.appendingPathComponent("registration-events.json")
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        try Data("{invalid".utf8).write(to: associationURL)
        try Data("[invalid".utf8).write(to: auditURL)
        let controller = AgentAssociationController(
            store: AgentAssociationStore(storeURL: associationURL),
            auditStore: AgentRegistrationAuditStore(storeURL: auditURL)
        )

        controller.refresh()
        XCTAssertTrue(controller.canRepairPersistence)
        XCTAssertEqual(
            controller.persistenceErrorMessage,
            "Associations: Agent associations contain invalid data.\n"
                + "Registration history: Registration history contains invalid data."
        )

        controller.repairPersistence()

        XCTAssertFalse(controller.canRepairPersistence)
        XCTAssertNil(controller.persistenceErrorMessage)
        XCTAssertTrue(controller.associations.isEmpty)
        XCTAssertTrue(controller.registrationEvents.isEmpty)
        XCTAssertTrue(controller.recoveryMessage?.contains("Backups:") == true)
        let backups = try FileManager.default.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".corrupt-") }
        XCTAssertEqual(backups.count, 2)
    }

    func testRepeatedAgentRefreshKeepsResolvedBadgeAvailable() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/agent-refresh-retention-\(UUID().uuidString)",
            isDirectory: true
        )
        let associationURL = container.appendingPathComponent("associations.json")
        let auditURL = container.appendingPathComponent("registration-events.json")
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        let store = AgentAssociationStore(storeURL: associationURL)
        let association = AgentAssociation(
            provider: .codex,
            sessionID: "01a03c04-ee8f-7c00-9731-978fcf7a8768",
            worktreePath: "/worktrees/sample",
            title: "Codex task",
            updatedAt: Date()
        )
        _ = try store.upsert(association)
        let controller = AgentAssociationController(
            store: store,
            auditStore: AgentRegistrationAuditStore(storeURL: auditURL)
        )
        defer { controller.setApplicationActive(false) }

        controller.refresh()
        for _ in 0..<100 {
            if controller.navigationAvailability(for: association) == .available {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            controller.navigationAvailability(for: association),
            .available
        )

        controller.refresh()

        XCTAssertEqual(
            controller.navigationAvailability(for: association),
            .available
        )
    }

    func testEnteringBackgroundFlushesReviewState() throws {
        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = ReviewStateKey(worktreeID: "/worktrees/feature", context: .pending)
        let model = AppModel(defaults: defaults)
        model.reviewStates.save(
            ReviewState(collapsedFileIDs: ["pending:working:file.swift"]),
            for: key
        )

        model.setApplicationActive(false)

        let restored = AppModel(defaults: defaults)
        XCTAssertEqual(
            restored.reviewStates.state(for: key).collapsedFileIDs,
            ["pending:working:file.swift"]
        )
    }

    func testRepositoryRefreshRunsOnlyInBackground() async throws {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-background-\(UUID().uuidString)")
        try await initializeRepository(at: repository, using: GitCommandRunner())
        defer { try? FileManager.default.removeItem(at: repository) }
        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            defaults: defaults,
            backgroundRefreshInterval: .milliseconds(100)
        )
        defer { model.setApplicationActive(true) }
        await model.addProject(at: repository)
        await model.loadProjectsIfNeeded()
        let baseline = try XCTUnwrap(model.selectedWorktree?.refreshedAt)
        try Data("new file\n".utf8).write(to: repository.appendingPathComponent("new.txt"))
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(model.selectedWorktree?.refreshedAt, baseline)
        XCTAssertFalse(model.isRefreshing(worktreeID: repository.path))

        model.setApplicationActive(false)
        for _ in 0..<100 {
            if model.selectedWorktree?.status.changes.contains(where: { $0.path == "new.txt" }) == true {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(model.selectedWorktree?.status.changes.contains(where: { $0.path == "new.txt" }) == true)
        let backgroundSnapshot = model.selectedWorktree?.refreshedAt
        model.setApplicationActive(true)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(model.selectedWorktree?.refreshedAt, backgroundSnapshot)
        let foregroundSnapshot = model.selectedWorktree?.refreshedAt
        try Data("another file\n".utf8).write(to: repository.appendingPathComponent("manual.txt"))
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(model.selectedWorktree?.refreshedAt, foregroundSnapshot)
        await model.refreshSelectedWorktree()
        XCTAssertTrue(model.selectedWorktree?.status.changes.contains(where: { $0.path == "manual.txt" }) == true)
        await model.prepareForTermination()
    }

    func testTerminationFlushesProjectSnapshotAndReviewState() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/termination-flush-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        let cacheURL = container.appendingPathComponent("project-snapshots.json")
        try await initializeRepository(at: repository, using: GitCommandRunner())
        defer { try? FileManager.default.removeItem(at: container) }
        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            defaults: defaults,
            snapshotStore: ProjectSnapshotStore(fileURL: cacheURL)
        )
        await model.addProject(at: repository)
        let selected = try XCTUnwrap(model.selectedWorktree)
        let key = ReviewStateKey(worktreeID: selected.id, context: .pending)
        model.reviewStates.save(
            ReviewState(
                collapsedFileIDs: ["working:README.md"],
                focusedFileID: "working:README.md"
            ),
            for: key
        )
        model.reviewStates.saveScrollOffset(456.5, for: key)

        model.setApplicationActive(false)
        await model.prepareForTermination()

        let payload = try XCTUnwrap(ProjectSnapshotStore.load(from: cacheURL))
        XCTAssertEqual(payload.projects.map(\.id), [repository.standardizedFileURL.path])
        XCTAssertEqual(payload.projects.first?.worktrees.first?.id, selected.id)
        let restoredReviewStore = ReviewStateStore(defaults: defaults)
        XCTAssertEqual(
            restoredReviewStore.state(for: key).collapsedFileIDs,
            ["working:README.md"]
        )
        XCTAssertEqual(
            restoredReviewStore.scrollOffset(for: key),
            456.5,
            accuracy: 0.01
        )
    }

    func testRefreshSelectedProjectLeavesOtherProjectsUnchanged() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-project-refresh-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("selected")
        let other = container.appendingPathComponent("other")
        let linked = container.appendingPathComponent("linked")
        let runner = GitCommandRunner()
        try await initializeRepository(at: repository, using: runner)
        try await initializeRepository(at: other, using: runner)
        defer { try? FileManager.default.removeItem(at: container) }
        _ = try await runner.run(
            arguments: ["worktree", "add", "-b", "linked", linked.path],
            workingDirectory: repository
        )
        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults)
        await model.addProject(at: repository)
        await model.addProject(at: other)
        let selectedProject = try XCTUnwrap(model.projects.first(where: {
            $0.project.rootURL.standardizedFileURL == repository.standardizedFileURL
        }))
        let selectedID = try XCTUnwrap(selectedProject.snapshot?.worktrees.first?.id)
        _ = model.selectWorktree(id: selectedID)
        let otherSnapshot = model.projects.first(where: { $0.id != selectedProject.id })?.snapshot
        for url in [repository, linked, other] {
            try Data("changed\n".utf8).write(to: url.appendingPathComponent("new.txt"))
        }
        await model.refreshSelectedProject()
        let refreshed = try XCTUnwrap(model.projects.first(where: { $0.id == selectedProject.id })?.snapshot)
        XCTAssertEqual(refreshed.worktrees.count, 2)
        XCTAssertTrue(refreshed.worktrees.allSatisfy {
            $0.status.changes.contains(where: { $0.path == "new.txt" })
        })
        XCTAssertEqual(model.projects.first(where: { $0.id != selectedProject.id })?.snapshot, otherSnapshot)
        await model.prepareForTermination()
    }

    func testCollapsedProjectsPersistAcrossModelInstances() throws {
        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(defaults: defaults)
        model.toggleProjectCollapsed(id: "/projects/sample")

        let restored = AppModel(defaults: defaults)
        XCTAssertEqual(restored.collapsedProjectIDs, Set(["/projects/sample"]))
    }

    func testManualProjectOrderPersistsAcrossModelInstances() throws {
        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            ["/projects/Alpha", "/projects/Beta", "/projects/Gamma"],
            forKey: "agentgit.project-paths"
        )

        let model = AppModel(defaults: defaults)
        model.moveProject(
            id: "/projects/Gamma",
            relativeTo: "/projects/Alpha",
            placeAfterTarget: false
        )
        XCTAssertEqual(
            model.projects.map(\.id),
            ["/projects/Gamma", "/projects/Alpha", "/projects/Beta"]
        )

        let restored = AppModel(defaults: defaults)
        XCTAssertEqual(restored.projects.map(\.id), model.projects.map(\.id))
    }

    func testSelectedWorktreePersistsAcrossModelInstances() throws {
        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let selectedID = "/worktrees/feature"

        let model = AppModel(defaults: defaults)
        model.selectedWorktreeID = selectedID

        let restored = AppModel(defaults: defaults)
        XCTAssertEqual(restored.selectedWorktreeID, selectedID)
        restored.selectedWorktreeID = nil
        XCTAssertNil(defaults.string(forKey: "agentgit.selected-worktree-id"))
    }

    func testStaleSelectionFallsBackToCachedWorktreeAndRestoresReviewContent() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/cached-selection-fallback-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        let snapshotCacheURL = container.appendingPathComponent("project-snapshots.json")
        let reviewCacheURL = container.appendingPathComponent(
            "review-content",
            isDirectory: true
        )
        try await initializeRepository(at: repository, using: GitCommandRunner())
        defer { try? FileManager.default.removeItem(at: container) }
        try Data("base\ncached change\n".utf8).write(
            to: repository.appendingPathComponent("README.md")
        )

        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first)
        let options = GitDiffOptions(context: .lines(3), ignoresWhitespace: false)
        let history = try await service.loadHistoryPage(
            worktree: worktree.worktree,
            revision: worktree.worktree.headOID,
            offset: 0,
            pageSize: StartupReviewContent.historyPageSize
        )
        let diffs = try await service.loadDiffs(
            worktree: worktree.worktree,
            changes: worktree.status.changes.filter {
                $0.isUnstaged || $0.isUntracked
            },
            scope: .working,
            options: options
        )
        let reviewStore = ReviewContentStore(directoryURL: reviewCacheURL)
        try await reviewStore.saveHistoryPage(
            history,
            for: HistoryReviewContentCacheKey(
                worktreeID: worktree.id,
                revision: worktree.worktree.headOID,
                pageSize: StartupReviewContent.historyPageSize
            )
        )
        try await reviewStore.savePendingDiffs(
            diffs,
            for: PendingReviewContentCacheKey(
                snapshot: worktree,
                options: options
            )
        )
        let snapshotStore = ProjectSnapshotStore(fileURL: snapshotCacheURL)
        try await snapshotStore.save(
            projectIDs: [project.id],
            snapshots: [project],
            eventID: FSEventsGetCurrentEventId(),
            completeProjectIDs: [project.id]
        )

        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([repository.path], forKey: "agentgit.project-paths")
        defaults.set(1, forKey: "agentgit.project-identity-version")
        defaults.set("/missing/worktree", forKey: "agentgit.selected-worktree-id")
        defaults.set("/missing/project", forKey: "agentgit.selected-worktree-project-id")

        let model = AppModel(
            defaults: defaults,
            snapshotStore: ProjectSnapshotStore(fileURL: snapshotCacheURL),
            reviewContentStore: ReviewContentStore(directoryURL: reviewCacheURL)
        )
        defer { model.setApplicationActive(false) }

        XCTAssertEqual(model.selectedWorktreeID, worktree.id)
        XCTAssertEqual(
            defaults.string(forKey: "agentgit.selected-worktree-id"),
            worktree.id
        )
        let startupContent = try XCTUnwrap(
            model.startupReviewContent(for: worktree)
        )
        XCTAssertEqual(startupContent.historyPage, history)
        XCTAssertEqual(startupContent.pendingDiffs, diffs)
        XCTAssertTrue(startupContent.pendingDiffsAreComplete)
    }

    func testIncompleteSnapshotKeepsStoredSelectionUntilMissingProjectLoads() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/incomplete-selection-\(UUID().uuidString)",
            isDirectory: true
        )
        let cachedRepository = container.appendingPathComponent(
            "cached",
            isDirectory: true
        )
        let selectedRepository = container.appendingPathComponent(
            "selected",
            isDirectory: true
        )
        let linkedWorktree = container.appendingPathComponent(
            "selected-feature",
            isDirectory: true
        )
        let snapshotCacheURL = container.appendingPathComponent(
            "project-snapshots.json"
        )
        let runner = GitCommandRunner()
        try await initializeRepository(at: cachedRepository, using: runner)
        try await initializeRepository(at: selectedRepository, using: runner)
        _ = try await runner.run(
            arguments: [
                "worktree",
                "add",
                "-b",
                "selected-feature",
                linkedWorktree.path,
            ],
            workingDirectory: selectedRepository
        )
        defer { try? FileManager.default.removeItem(at: container) }

        let service = GitRepositoryService()
        let cachedProject = try await service.loadProject(at: cachedRepository)
        let selectedProjectID = selectedRepository.standardizedFileURL.path
        let linkedWorktreeID = linkedWorktree.standardizedFileURL.path
        let snapshotStore = ProjectSnapshotStore(fileURL: snapshotCacheURL)
        try await snapshotStore.save(
            projectIDs: [cachedProject.id, selectedProjectID],
            snapshots: [cachedProject],
            eventID: FSEventsGetCurrentEventId(),
            completeProjectIDs: [cachedProject.id]
        )

        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            [cachedRepository.path, selectedRepository.path],
            forKey: "agentgit.project-paths"
        )
        defaults.set(1, forKey: "agentgit.project-identity-version")
        defaults.set(linkedWorktreeID, forKey: "agentgit.selected-worktree-id")
        defaults.set(
            selectedProjectID,
            forKey: "agentgit.selected-worktree-project-id"
        )

        let model = AppModel(
            defaults: defaults,
            snapshotStore: ProjectSnapshotStore(fileURL: snapshotCacheURL)
        )
        defer { model.setApplicationActive(false) }

        XCTAssertEqual(model.selectedWorktreeID, linkedWorktreeID)
        XCTAssertNil(model.selectedWorktree)
        XCTAssertEqual(
            defaults.string(forKey: "agentgit.selected-worktree-id"),
            linkedWorktreeID
        )

        await model.loadProjectsIfNeeded()

        XCTAssertEqual(model.selectedWorktreeID, linkedWorktreeID)
        XCTAssertEqual(model.selectedWorktree?.id, linkedWorktreeID)
        XCTAssertEqual(
            defaults.string(forKey: "agentgit.selected-worktree-id"),
            linkedWorktreeID
        )
    }


    func testSelectingCompleteCachedWorktreeRunsNoGitCommands() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/cached-selection-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        let linked = container.appendingPathComponent("feature", isDirectory: true)
        let cacheURL = container.appendingPathComponent("project-snapshots.json")
        let commandLogURL = container.appendingPathComponent("git-commands.log")
        let gitWrapperURL = container.appendingPathComponent("git-wrapper.sh")
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: container) }

        let systemRunner = GitCommandRunner()
        try await initializeRepository(at: repository, using: systemRunner)
        _ = try await systemRunner.run(
            arguments: ["worktree", "add", "-b", "feature", linked.path],
            workingDirectory: repository
        )
        let snapshot = try await GitRepositoryService().loadProject(at: repository)
        let rootID = repository.standardizedFileURL.path
        let linkedID = linked.standardizedFileURL.path
        XCTAssertNotNil(snapshot.worktrees.first(where: { $0.id == rootID }))
        XCTAssertNotNil(snapshot.worktrees.first(where: { $0.id == linkedID }))
        let cacheStore = ProjectSnapshotStore(fileURL: cacheURL)
        try await cacheStore.save(
            projectIDs: [snapshot.id],
            snapshots: [snapshot],
            eventID: FSEventsGetCurrentEventId(),
            completeProjectIDs: [snapshot.id]
        )

        let quotedLogPath = commandLogURL.path.replacingOccurrences(
            of: "'",
            with: "'\\''"
        )
        let wrapper = """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(quotedLogPath)'
        exec /usr/bin/git "$@"
        """
        try Data(wrapper.utf8).write(to: gitWrapperURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: gitWrapperURL.path
        )

        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([rootID], forKey: "agentgit.project-paths")
        defaults.set(1, forKey: "agentgit.project-identity-version")
        defaults.set(rootID, forKey: "agentgit.selected-worktree-id")
        defaults.set(rootID, forKey: "agentgit.selected-worktree-project-id")
        let model = AppModel(
            defaults: defaults,
            repositoryService: GitRepositoryService(
                runner: GitCommandRunner(executableURL: gitWrapperURL)
            ),
            snapshotStore: ProjectSnapshotStore(fileURL: cacheURL)
        )

        let requiresRefresh = model.selectWorktree(id: linkedID)
        if requiresRefresh {
            _ = await model.refreshSelectedWorktree()
        }

        XCTAssertFalse(requiresRefresh)
        XCTAssertEqual(model.selectedWorktreeID, linkedID)
        let commands = (try? String(
            contentsOf: commandLogURL,
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            commands.isEmpty,
            "Cached worktree selection executed Git commands: \(commands)"
        )

        model.setBlockingGitRefreshError(
            "Repository status is stale.",
            for: linkedID
        )
        XCTAssertFalse(model.selectWorktree(id: rootID))
        XCTAssertFalse(model.selectWorktree(id: linkedID))
        XCTAssertEqual(
            model.blockingGitRefreshError(for: linkedID),
            "Repository status is stale."
        )

        XCTAssertFalse(model.selectWorktree(id: "/worktrees/missing"))
        XCTAssertEqual(model.selectedWorktreeID, linkedID)
        XCTAssertEqual(
            defaults.string(forKey: "agentgit.selected-worktree-id"),
            linkedID
        )
    }

    func testAddingLinkedWorktreeKeepsOneCanonicalProject() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/app-project-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        let linked = container.appendingPathComponent("feature", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        let runner = GitCommandRunner()
        _ = try await runner.run(
            arguments: ["init", "-b", "main"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["config", "user.name", "AgentGit Tests"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["config", "user.email", "agentgit-tests@example.invalid"],
            workingDirectory: repository
        )
        try Data("base\n".utf8).write(
            to: repository.appendingPathComponent("README.md")
        )
        _ = try await runner.run(arguments: ["add", "README.md"], workingDirectory: repository)
        _ = try await runner.run(
            arguments: ["commit", "-m", "Initial commit"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["worktree", "add", "-b", "feature", linked.path],
            workingDirectory: repository
        )
        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults)

        await model.addProject(at: linked)
        XCTAssertEqual(model.projects.count, 1)
        XCTAssertEqual(model.projects[0].id, repository.standardizedFileURL.path)
        XCTAssertEqual(model.selectedWorktreeID, linked.standardizedFileURL.path)
        XCTAssertEqual(
            defaults.string(forKey: "agentgit.selected-worktree-id"),
            linked.standardizedFileURL.path
        )
        XCTAssertEqual(
            defaults.string(forKey: "agentgit.selected-worktree-project-id"),
            repository.standardizedFileURL.path
        )

        await model.addProject(at: repository)
        XCTAssertEqual(model.projects.count, 1)
        XCTAssertEqual(
            defaults.stringArray(forKey: "agentgit.project-paths"),
            [repository.standardizedFileURL.path]
        )
        XCTAssertEqual(model.selectedWorktreeID, repository.standardizedFileURL.path)
        model.setApplicationActive(false)
    }

    func testBackgroundRefreshDiscoversAddedAndRemovedWorktrees() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/worktree-discovery-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        let linked = container.appendingPathComponent("feature", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        let runner = GitCommandRunner()
        _ = try await runner.run(
            arguments: ["init", "-b", "main"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["config", "user.name", "AgentGit Tests"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["config", "user.email", "agentgit-tests@example.invalid"],
            workingDirectory: repository
        )
        try Data("base\n".utf8).write(
            to: repository.appendingPathComponent("README.md")
        )
        _ = try await runner.run(
            arguments: ["add", "README.md"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["commit", "-m", "Initial commit"],
            workingDirectory: repository
        )
        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults, backgroundRefreshInterval: .milliseconds(100))
        defer { model.setApplicationActive(true) }
        await model.addProject(at: repository)
        model.setApplicationActive(false)

        _ = try await runner.run(
            arguments: ["worktree", "add", "-b", "feature", linked.path],
            workingDirectory: repository
        )
        for _ in 0..<100 {
            if model.projects.first?.snapshot?.worktrees.contains(where: {
                $0.id == linked.standardizedFileURL.path
            }) == true {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(
            model.projects.first?.snapshot?.worktrees.contains(where: {
                $0.id == linked.standardizedFileURL.path
            }) == true
        )

        _ = try await runner.run(
            arguments: ["worktree", "remove", linked.path],
            workingDirectory: repository
        )
        for _ in 0..<100 {
            if model.projects.first?.snapshot?.worktrees.contains(where: {
                $0.id == linked.standardizedFileURL.path
            }) == false {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(
            model.projects.first?.snapshot?.worktrees.contains(where: {
                $0.id == linked.standardizedFileURL.path
            }) == true
        )
    }



    func testCompleteCachedStartupUsesCacheUntilManualRefresh() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/cached-startup-command-audit-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        let cacheURL = container.appendingPathComponent("project-snapshots.json")
        let reviewCacheURL = container.appendingPathComponent(
            "review-content",
            isDirectory: true
        )
        let commandLogURL = container.appendingPathComponent("git-commands.log")
        let gitWrapperURL = container.appendingPathComponent("git-wrapper.sh")
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: container) }

        let systemRunner = GitCommandRunner()
        try await initializeRepository(at: repository, using: systemRunner)
        try Data("base\ncached\n".utf8).write(
            to: repository.appendingPathComponent("README.md")
        )
        let snapshot = try await GitRepositoryService().loadProject(at: repository)
        let selectedSnapshot = try XCTUnwrap(snapshot.worktrees.first)
        let reviewOptions = GitDiffOptions(
            context: .lines(3),
            ignoresWhitespace: false
        )
        let reviewService = GitRepositoryService()
        let history = try await reviewService.loadHistoryPage(
            worktree: selectedSnapshot.worktree,
            revision: selectedSnapshot.worktree.headOID,
            offset: 0,
            pageSize: StartupReviewContent.historyPageSize
        )
        let workingChanges = selectedSnapshot.status.changes.filter {
            $0.isUnstaged || $0.isUntracked
        }
        let diffs = try await reviewService.loadDiffs(
            worktree: selectedSnapshot.worktree,
            changes: workingChanges,
            scope: .working,
            options: reviewOptions
        )
        let reviewWriter = ReviewContentStore(directoryURL: reviewCacheURL)
        try await reviewWriter.saveHistoryPage(
            history,
            for: HistoryReviewContentCacheKey(
                worktreeID: selectedSnapshot.id,
                revision: selectedSnapshot.worktree.headOID,
                pageSize: StartupReviewContent.historyPageSize
            )
        )
        try await reviewWriter.savePendingDiffs(
            diffs,
            for: PendingReviewContentCacheKey(
                snapshot: selectedSnapshot,
                options: reviewOptions
            )
        )
        try await Task.sleep(for: .milliseconds(500))
        let cacheStore = ProjectSnapshotStore(fileURL: cacheURL)
        try await cacheStore.save(
            projectIDs: [snapshot.id],
            snapshots: [snapshot],
            eventID: FSEventsGetCurrentEventId(),
            completeProjectIDs: [snapshot.id]
        )
        let quotedLogPath = commandLogURL.path.replacingOccurrences(
            of: "'",
            with: "'\\''"
        )
        let wrapper = """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(quotedLogPath)'
        exec /usr/bin/git "$@"
        """
        try Data(wrapper.utf8).write(to: gitWrapperURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: gitWrapperURL.path
        )

        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([repository.path], forKey: "agentgit.project-paths")
        defaults.set(1, forKey: "agentgit.project-identity-version")
        defaults.set(repository.path, forKey: "agentgit.selected-worktree-id")
        defaults.set(repository.path, forKey: "agentgit.selected-worktree-project-id")
        let service = GitRepositoryService(
            runner: GitCommandRunner(executableURL: gitWrapperURL)
        )
        let model = AppModel(
            defaults: defaults,
            repositoryService: service,
            snapshotStore: ProjectSnapshotStore(fileURL: cacheURL),
            reviewContentStore: ReviewContentStore(directoryURL: reviewCacheURL)
        )
        defer { model.setApplicationActive(false) }

        let startupContent = try XCTUnwrap(
            model.startupReviewContent(for: selectedSnapshot)
        )
        XCTAssertEqual(startupContent.historyPage, history)
        XCTAssertEqual(startupContent.pendingDiffs, diffs)
        XCTAssertTrue(startupContent.pendingDiffsAreComplete)

        await model.loadProjectsIfNeeded()
        try await Task.sleep(for: .milliseconds(800))
        let startupCommands = (try? String(
            contentsOf: commandLogURL,
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            startupCommands.isEmpty,
            "Complete cache launch executed Git commands: \(startupCommands)"
        )

        try Data("base\nchanged\n".utf8).write(
            to: repository.appendingPathComponent("README.md")
        )
        await model.refreshSelectedWorktree()
        for _ in 0..<100 {
            let commands = (try? String(
                contentsOf: commandLogURL,
                encoding: .utf8
            )) ?? ""
            if commands.contains("status --porcelain=v2") {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(
            model.selectedWorktree?.status.changes.contains(where: {
                $0.path == "README.md"
            }) == true
        )
        let commands = try String(contentsOf: commandLogURL, encoding: .utf8)
        XCTAssertTrue(commands.contains("status --porcelain=v2"))
    }

    func testWarmRestartUsesCacheUntilManualMembershipRefresh() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/warm-restart-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        let linked = container.appendingPathComponent("feature", isDirectory: true)
        let cacheURL = container.appendingPathComponent("project-snapshots.json")
        let commandLogURL = container.appendingPathComponent("git-commands.log")
        let gitWrapperURL = container.appendingPathComponent("git-wrapper.sh")
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: container) }

        let systemRunner = GitCommandRunner()
        try await initializeRepository(at: repository, using: systemRunner)
        _ = try await systemRunner.run(
            arguments: ["worktree", "add", "-b", "feature", linked.path],
            workingDirectory: repository
        )
        let quotedLogPath = commandLogURL.path.replacingOccurrences(
            of: "'",
            with: "'\\''"
        )
        let wrapper = """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(quotedLogPath)'
        exec /usr/bin/git "$@"
        """
        try Data(wrapper.utf8).write(to: gitWrapperURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: gitWrapperURL.path
        )

        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([repository.path], forKey: "agentgit.project-paths")
        defaults.set(1, forKey: "agentgit.project-identity-version")
        defaults.set(repository.path, forKey: "agentgit.selected-worktree-id")
        defaults.set(repository.path, forKey: "agentgit.selected-worktree-project-id")
        let service = GitRepositoryService(
            runner: GitCommandRunner(executableURL: gitWrapperURL)
        )

        let firstModel = AppModel(
            defaults: defaults,
            repositoryService: service,
            snapshotStore: ProjectSnapshotStore(fileURL: cacheURL)
        )
        await firstModel.loadProjectsIfNeeded()
        await firstModel.prepareForTermination()

        let writtenPayload = try XCTUnwrap(ProjectSnapshotStore.load(from: cacheURL))
        XCTAssertEqual(writtenPayload.completeProjectIDs, [repository.path])
        XCTAssertEqual(
            Set(writtenPayload.projects.first?.worktrees.map(\.id) ?? []),
            [repository.standardizedFileURL.path, linked.standardizedFileURL.path]
        )
        try? FileManager.default.removeItem(at: commandLogURL)

        let secondModel = AppModel(
            defaults: defaults,
            repositoryService: service,
            snapshotStore: ProjectSnapshotStore(fileURL: cacheURL)
        )
        defer { secondModel.setApplicationActive(false) }
        XCTAssertEqual(secondModel.projects.first?.snapshot, writtenPayload.projects.first)
        await secondModel.loadProjectsIfNeeded()
        try await Task.sleep(for: .milliseconds(800))

        let restartCommands = (try? String(
            contentsOf: commandLogURL,
            encoding: .utf8
        )) ?? ""
        let restartCommandLines = restartCommands
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertTrue(restartCommandLines.isEmpty)
        XCTAssertFalse(restartCommands.contains("status --porcelain=v2"))
        XCTAssertFalse(restartCommands.contains("diff --no-ext-diff"))
        XCTAssertEqual(secondModel.projects.first?.snapshot, writtenPayload.projects.first)

        let nextLinked = container.appendingPathComponent(
            "feature-next",
            isDirectory: true
        )
        _ = try await systemRunner.run(
            arguments: [
                "worktree", "add", "-b", "feature-next", nextLinked.path
            ],
            workingDirectory: repository
        )
        await secondModel.refreshAll()
        for _ in 0..<100 {
            if secondModel.projects.first?.snapshot?.worktrees.contains(where: {
                $0.id == nextLinked.standardizedFileURL.path
            }) == true {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(
            secondModel.projects.first?.snapshot?.worktrees.contains(where: {
                $0.id == nextLinked.standardizedFileURL.path
            }) == true
        )
        let changedCommands = try String(
            contentsOf: commandLogURL,
            encoding: .utf8
        )
        XCTAssertTrue(changedCommands.contains("worktree list --porcelain -z"))
    }

    func testReviewCacheWriteFailureIsVisibleAndClearsAfterRecovery() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/review-cache-error-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        let cacheDirectory = container.appendingPathComponent("cache", isDirectory: true)
        try await initializeRepository(at: repository, using: GitCommandRunner())
        defer { try? FileManager.default.removeItem(at: container) }
        try Data("base\nchanged\n".utf8).write(
            to: repository.appendingPathComponent("README.md")
        )
        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let snapshot = try XCTUnwrap(project.worktrees.first)
        let options = GitDiffOptions(context: .lines(3), ignoresWhitespace: false)
        let diffs = try await service.loadDiffs(
            worktree: snapshot.worktree,
            changes: snapshot.status.changes.filter(\.isUnstaged),
            scope: .working,
            options: options
        )
        try Data("blocking file\n".utf8).write(to: cacheDirectory)
        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            defaults: defaults,
            reviewContentStore: ReviewContentStore(
                directoryURL: cacheDirectory
            )
        )

        await model.cachePendingDiffs(
            diffs,
            snapshot: snapshot,
            options: options
        )
        XCTAssertNotNil(model.reviewContentCacheError)
        XCTAssertTrue(
            model.cacheErrorMessage?.contains("Review content:") == true
        )

        try FileManager.default.removeItem(at: cacheDirectory)
        await model.cachePendingDiffs(
            diffs,
            snapshot: snapshot,
            options: options
        )
        XCTAssertNil(model.reviewContentCacheError)
        XCTAssertNil(model.cacheErrorMessage)
    }

    func testSuccessfulMutationReportsRefreshFailureAndRecoversWithoutRepeatingWrite() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/mutation-refresh-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        let cacheURL = container.appendingPathComponent("project-snapshots.json")
        let wrapperURL = container.appendingPathComponent("git-wrapper.sh")
        let failureMarkerURL = container.appendingPathComponent("fail-status")
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        let systemRunner = GitCommandRunner()
        try await initializeRepository(at: repository, using: systemRunner)
        try Data("base\nchanged\n".utf8).write(
            to: repository.appendingPathComponent("README.md")
        )
        let initialProject = try await GitRepositoryService().loadProject(at: repository)
        let initialSnapshot = try XCTUnwrap(initialProject.worktrees.first)
        let change = try XCTUnwrap(
            initialSnapshot.status.changes.first(where: { $0.path == "README.md" })
        )
        let cacheStore = ProjectSnapshotStore(fileURL: cacheURL)
        try await cacheStore.save(
            projectIDs: [initialProject.id],
            snapshots: [initialProject],
            eventID: FSEventsGetCurrentEventId(),
            completeProjectIDs: [initialProject.id]
        )
        let quotedMarkerPath = failureMarkerURL.path.replacingOccurrences(
            of: "'",
            with: "'\\''"
        )
        let wrapper = """
        #!/bin/sh
        for argument in "$@"; do
            if [ "$argument" = "status" ] && [ -f '\(quotedMarkerPath)' ]; then
                printf '%s\n' 'forced status failure' >&2
                exit 23
            fi
        done
        exec /usr/bin/git "$@"
        """
        try Data(wrapper.utf8).write(to: wrapperURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: wrapperURL.path
        )
        try Data("fail".utf8).write(to: failureMarkerURL)
        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([repository.path], forKey: "agentgit.project-paths")
        defaults.set(1, forKey: "agentgit.project-identity-version")
        defaults.set(repository.path, forKey: "agentgit.selected-worktree-id")
        defaults.set(repository.path, forKey: "agentgit.selected-worktree-project-id")
        let model = AppModel(
            defaults: defaults,
            repositoryService: GitRepositoryService(
                runner: GitCommandRunner(executableURL: wrapperURL)
            ),
            snapshotStore: ProjectSnapshotStore(fileURL: cacheURL)
        )
        defer { model.setApplicationActive(false) }

        do {
            try await model.applyFileAction(
                .stage,
                worktree: initialSnapshot.worktree,
                change: change
            )
            XCTFail("Expected the post-mutation refresh to fail")
        } catch let error as GitMutationRefreshError {
            XCTAssertTrue(error.description.contains("forced status failure"))
        }

        let stagedPaths = String(
            decoding: try await systemRunner.run(
                arguments: ["diff", "--cached", "--name-only"],
                workingDirectory: repository
            ),
            as: UTF8.self
        )
        XCTAssertEqual(stagedPaths.trimmingCharacters(in: .whitespacesAndNewlines), "README.md")
        XCTAssertEqual(model.selectedWorktree?.status.unstagedFileCount, 1)
        XCTAssertTrue(
            model.selectedWorktree?.errorMessage?.contains("forced status failure") == true
        )

        try FileManager.default.removeItem(at: failureMarkerURL)
        let recoveryOutcome = await model.refreshWorktree(id: initialSnapshot.id)
        XCTAssertEqual(recoveryOutcome, .updated)
        XCTAssertEqual(model.selectedWorktree?.status.unstagedFileCount, 0)
        XCTAssertEqual(model.selectedWorktree?.status.stagedFileCount, 1)
        XCTAssertNil(model.selectedWorktree?.errorMessage)
    }

    func testCachedSnapshotWithoutFreshnessMarkerValidatesSelectedWorktree() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/cached-freshness-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        let cacheURL = container.appendingPathComponent("project-snapshots.json")
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        let runner = GitCommandRunner()
        try await initializeRepository(at: repository, using: runner)
        let service = GitRepositoryService()
        let loadedProject = try await service.loadProject(at: repository)
        let loadedWorktree = try XCTUnwrap(loadedProject.worktrees.first)
        let cachedWorktree = GitWorktreeSnapshot(
            worktree: loadedWorktree.worktree,
            status: loadedWorktree.status,
            diffStat: loadedWorktree.diffStat,
            lastActivityAt: loadedWorktree.lastActivityAt,
            refreshedAt: nil,
            errorMessage: nil,
            eventWatchURLs: loadedWorktree.eventWatchURLs
        )
        try Data("base\nchanged after cached status\n".utf8).write(
            to: repository.appendingPathComponent("README.md")
        )
        try await Task.sleep(for: .milliseconds(500))
        let cachedProject = GitProjectSnapshot(
            project: loadedProject.project,
            worktrees: [cachedWorktree],
            refreshedAt: loadedProject.refreshedAt
        )
        let store = ProjectSnapshotStore(fileURL: cacheURL)
        try await store.save(
            projectIDs: [cachedProject.id],
            snapshots: [cachedProject],
            eventID: FSEventsGetCurrentEventId(),
            completeProjectIDs: [cachedProject.id]
        )

        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([repository.path], forKey: "agentgit.project-paths")
        defaults.set(1, forKey: "agentgit.project-identity-version")
        defaults.set(repository.path, forKey: "agentgit.selected-worktree-id")
        defaults.set(repository.path, forKey: "agentgit.selected-worktree-project-id")
        let model = AppModel(
            defaults: defaults,
            repositoryService: service,
            snapshotStore: ProjectSnapshotStore(fileURL: cacheURL)
        )
        defer { model.setApplicationActive(false) }

        XCTAssertNil(model.selectedWorktree?.refreshedAt)
        await model.loadProjectsIfNeeded()

        XCTAssertNotNil(model.selectedWorktree?.refreshedAt)
        XCTAssertTrue(
            model.selectedWorktree?.status.changes.contains(where: {
                $0.path == "README.md"
            }) == true
        )
    }



    func testCachedStartupOnlyLoadsMissingProjectsAndWorktrees() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/cached-startup-incremental-\(UUID().uuidString)",
            isDirectory: true
        )
        let cachedRepository = container.appendingPathComponent(
            "cached-repository",
            isDirectory: true
        )
        let linkedWorktree = container.appendingPathComponent(
            "cached-feature",
            isDirectory: true
        )
        let uncachedRepository = container.appendingPathComponent(
            "uncached-repository",
            isDirectory: true
        )
        let cacheURL = container.appendingPathComponent("project-snapshots.json")
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: container) }

        let runner = GitCommandRunner()
        try await initializeRepository(at: cachedRepository, using: runner)
        try await initializeRepository(at: uncachedRepository, using: runner)
        _ = try await runner.run(
            arguments: ["worktree", "add", "-b", "feature", linkedWorktree.path],
            workingDirectory: cachedRepository
        )

        let service = GitRepositoryService()
        let completeCachedSnapshot = try await service.loadProject(at: cachedRepository)
        let cachedPrimary = try XCTUnwrap(
            completeCachedSnapshot.worktrees.first(where: {
                $0.id == cachedRepository.standardizedFileURL.path
            })
        )
        let partialCachedSnapshot = GitProjectSnapshot(
            project: completeCachedSnapshot.project,
            worktrees: [cachedPrimary],
            refreshedAt: completeCachedSnapshot.refreshedAt
        )
        try Data("base\nchanged after snapshot\n".utf8).write(
            to: cachedRepository.appendingPathComponent("README.md")
        )
        try await Task.sleep(for: .milliseconds(500))
        let cacheStore = ProjectSnapshotStore(fileURL: cacheURL)
        try await cacheStore.save(
            projectIDs: [cachedRepository.path, uncachedRepository.path],
            snapshots: [partialCachedSnapshot],
            eventID: FSEventsGetCurrentEventId(),
            completeProjectIDs: []
        )

        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            [cachedRepository.path, uncachedRepository.path],
            forKey: "agentgit.project-paths"
        )
        defaults.set(1, forKey: "agentgit.project-identity-version")
        defaults.set(cachedRepository.path, forKey: "agentgit.selected-worktree-id")
        defaults.set(cachedRepository.path, forKey: "agentgit.selected-worktree-project-id")

        let model = AppModel(
            defaults: defaults,
            repositoryService: service,
            snapshotStore: ProjectSnapshotStore(fileURL: cacheURL)
        )
        defer { model.setApplicationActive(false) }
        await model.loadProjectsIfNeeded()

        let cachedAfterStartup = try XCTUnwrap(
            model.projects.first(where: { $0.id == cachedRepository.path })?.snapshot
        )
        XCTAssertTrue(
            cachedAfterStartup.worktrees.contains(where: {
                $0.id == linkedWorktree.standardizedFileURL.path
            })
        )
        XCTAssertTrue(
            cachedAfterStartup.worktrees.first(where: {
                $0.id == cachedRepository.standardizedFileURL.path
            })?.status.changes.isEmpty == true
        )
        XCTAssertNotNil(
            model.projects.first(where: { $0.id == uncachedRepository.path })?.snapshot
        )

        try await Task.sleep(for: .milliseconds(500))
        let savedPayload = try XCTUnwrap(ProjectSnapshotStore.load(from: cacheURL))
        XCTAssertEqual(Set(savedPayload.projects.map(\.id)), Set([
            cachedRepository.path,
            uncachedRepository.path
        ]))
        XCTAssertEqual(
            savedPayload.projects.first(where: { $0.id == cachedRepository.path })?
                .worktrees.count,
            2
        )
    }

    func testUnavailableProjectExposesRetryableDismissibleError() async throws {
        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let missingURL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/missing-\(UUID().uuidString)",
            isDirectory: true
        )
        defaults.set([missingURL.path], forKey: "agentgit.project-paths")
        let model = AppModel(defaults: defaults)

        await model.refreshProject(id: missingURL.standardizedFileURL.path)

        XCTAssertNotNil(model.projects.first?.errorMessage)
        model.clearProjectError(id: missingURL.standardizedFileURL.path)
        XCTAssertNil(model.projects.first?.errorMessage)
    }

    func testProjectKeepsAllChangedWorktreesWhenFolded() {
        let now = Date(timeIntervalSince1970: 200_000)
        let project = GitProject(rootURL: URL(fileURLWithPath: "/projects/sample"))
        let worktrees = (0..<5).map { index in
            makeWorktreeSnapshot(
                name: "active-\(index)",
                activityAt: now.addingTimeInterval(TimeInterval(-index * 60)),
                isDirty: true
            )
        } + [
            makeWorktreeSnapshot(
                name: "older-dirty",
                activityAt: now.addingTimeInterval(-72 * 60 * 60),
                isDirty: true
            ),
            makeWorktreeSnapshot(
                name: "inactive",
                activityAt: now.addingTimeInterval(-48 * 60 * 60),
                isDirty: false
            )
        ]
        let snapshot = GitProjectSnapshot(
            project: project,
            worktrees: worktrees,
            refreshedAt: now
        )

        let collapsed = projectWorktreePresentation(
            snapshot: snapshot,
            selectedWorktreeID: nil,
            showsAll: false,
            now: now
        )
        XCTAssertEqual(Set(collapsed.visibleWorktrees.map(\.id)), Set(worktrees.dropLast().map(\.id)))
        XCTAssertEqual(collapsed.hiddenWorktreeCount, 1)
        XCTAssertFalse(collapsed.visibleWorktrees.contains { $0.worktree.displayName == "inactive" })

        let selectedInactive = projectWorktreePresentation(
            snapshot: snapshot,
            selectedWorktreeID: worktrees.last?.id,
            showsAll: false,
            now: now
        )
        XCTAssertEqual(selectedInactive.visibleWorktrees.count, 7)
        XCTAssertTrue(selectedInactive.visibleWorktrees.contains { $0.id == worktrees.last?.id })

        let expanded = projectWorktreePresentation(
            snapshot: snapshot,
            selectedWorktreeID: nil,
            showsAll: true,
            now: now
        )
        XCTAssertEqual(expanded.visibleWorktrees.count, 7)
    }

    func testPinnedWorktreesStayFirstAndVisibleWhenCollapsed() {
        let now = Date(timeIntervalSince1970: 200_000)
        let project = GitProject(rootURL: URL(fileURLWithPath: "/projects/pinned"))
        let recent = (0..<5).map { index in
            makeWorktreeSnapshot(
                name: "recent-\(index)",
                activityAt: now.addingTimeInterval(TimeInterval(-index * 60)),
                isDirty: false
            )
        }
        // 两天没动过，折叠视图本来看不到它。
        let stale = makeWorktreeSnapshot(
            name: "stale",
            activityAt: now.addingTimeInterval(-48 * 60 * 60),
            isDirty: false
        )
        let snapshot = GitProjectSnapshot(
            project: project,
            worktrees: recent + [stale],
            refreshedAt: now
        )

        let collapsed = projectWorktreePresentation(
            snapshot: snapshot,
            selectedWorktreeID: nil,
            pinnedWorktreeIDs: [stale.id],
            showsAll: false,
            now: now
        )
        XCTAssertEqual(collapsed.visibleWorktrees.first?.id, stale.id)
        // 置顶不占“最近四个”的名额，所以一共露出五条。
        XCTAssertEqual(collapsed.visibleWorktrees.count, 5)
        XCTAssertEqual(collapsed.hiddenWorktreeCount, 1)

        let expanded = projectWorktreePresentation(
            snapshot: snapshot,
            selectedWorktreeID: nil,
            pinnedWorktreeIDs: [stale.id],
            showsAll: true,
            now: now
        )
        XCTAssertEqual(expanded.visibleWorktrees.first?.id, stale.id)
        XCTAssertEqual(expanded.visibleWorktrees.count, 6)

        // 选中另一个折叠外的 worktree 时，不能把置顶那条挤掉。
        let selectedElsewhere = projectWorktreePresentation(
            snapshot: snapshot,
            selectedWorktreeID: recent.last?.id,
            pinnedWorktreeIDs: [stale.id],
            showsAll: false,
            now: now
        )
        XCTAssertEqual(selectedElsewhere.visibleWorktrees.first?.id, stale.id)
        XCTAssertTrue(
            selectedElsewhere.visibleWorktrees.contains { $0.id == recent.last?.id }
        )
    }

    func testSelectingAChangedWorktreeKeepsOtherRowsVisible() {
        let now = Date(timeIntervalSince1970: 200_000)
        let recent = (0..<4).map { index in
            makeWorktreeSnapshot(
                name: "recent-\(index)",
                activityAt: now.addingTimeInterval(TimeInterval(-index * 60)),
                isDirty: false
            )
        }
        // 有改动但活动时间排在最近四个之后，折叠时靠“有改动”显示。
        let olderDirty = makeWorktreeSnapshot(
            name: "older-dirty",
            activityAt: now.addingTimeInterval(-3 * 60 * 60),
            isDirty: true
        )
        let snapshot = GitProjectSnapshot(
            project: GitProject(rootURL: URL(fileURLWithPath: "/projects/selection")),
            worktrees: recent + [olderDirty],
            refreshedAt: now
        )
        func visibleIDs(selecting id: GitWorktreeSnapshot.ID?) -> Set<GitWorktreeSnapshot.ID> {
            Set(projectWorktreePresentation(
                snapshot: snapshot,
                selectedWorktreeID: id,
                showsAll: false,
                now: now
            ).visibleWorktrees.map(\.id))
        }

        let unselected = visibleIDs(selecting: nil)
        XCTAssertEqual(unselected, Set((recent + [olderDirty]).map(\.id)))
        XCTAssertEqual(visibleIDs(selecting: olderDirty.id), unselected)
        XCTAssertEqual(visibleIDs(selecting: recent[0].id), unselected)
    }

    func testDuplicateWorktreeDirectoryNamesShowParentDirectory() {
        func worktree(_ path: String) -> GitWorktree {
            GitWorktree(
                rootURL: URL(fileURLWithPath: path, isDirectory: true),
                headOID: nil,
                branchRef: nil,
                isBare: false,
                isDetached: false,
                lockedReason: nil,
                prunableReason: nil
            )
        }
        let worktrees = [
            worktree("/Users/developer/projects/github/agentgit"),
            worktree("/Users/developer/.codex/worktrees/worktree-test/agentgit"),
            worktree("/Users/developer/projects/github/agentgit-feature")
        ]

        XCTAssertEqual(
            worktreeLocationLabels(worktrees).values.sorted(),
            ["agentgit-feature", "github/agentgit", "worktree-test/agentgit"]
        )
    }

    func testWorktreesSortByDisplayedActivityTime() {
        let now = Date(timeIntervalSince1970: 200_000)
        let recentClean = makeWorktreeSnapshot(
            name: "recent-clean",
            activityAt: now,
            isDirty: false
        )
        let olderDirty = makeWorktreeSnapshot(
            name: "older-dirty",
            activityAt: now.addingTimeInterval(-30 * 60),
            isDirty: true
        )

        let sorted = [olderDirty, recentClean].sorted(by: compareWorktreeSnapshots)

        XCTAssertEqual(sorted.map(\.id), [recentClean.id, olderDirty.id])

        let project = GitProject(rootURL: URL(fileURLWithPath: "/projects/sorted"))
        let presentation = projectWorktreePresentation(
            snapshot: GitProjectSnapshot(
                project: project,
                worktrees: [olderDirty, recentClean],
                refreshedAt: now
            ),
            selectedWorktreeID: nil,
            showsAll: true,
            now: now
        )
        XCTAssertEqual(
            presentation.visibleWorktrees.map(\.id),
            [recentClean.id, olderDirty.id]
        )
    }

    func testDuplicateStoredProjectPathsAreRepairedDuringInitialization() throws {
        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let projectURL = URL(fileURLWithPath: "/projects/repeated")
        defaults.set(
            [projectURL.path, projectURL.path, projectURL.path + "/"],
            forKey: "agentgit.project-paths"
        )
        defaults.set(1, forKey: "agentgit.project-identity-version")

        let model = AppModel(defaults: defaults)

        XCTAssertEqual(model.projects.map(\.id), [projectURL.path])
        XCTAssertEqual(
            defaults.stringArray(forKey: "agentgit.project-paths"),
            [projectURL.path]
        )
    }

    func testSidebarFilterMatchesProjectAndWorktreeMetadata() {
        let project = GitProject(
            rootURL: URL(fileURLWithPath: "/projects/CaseDriven")
        )
        let worktree = makeWorktreeSnapshot(
            name: "feature-review",
            activityAt: Date(),
            isDirty: false
        )

        XCTAssertTrue(projectMatchesSidebarFilter(project, query: "case"))
        XCTAssertTrue(projectMatchesSidebarFilter(project, query: "/projects/CASEDRIVEN"))
        XCTAssertTrue(worktreeMatchesSidebarFilter(worktree, query: "FEATURE"))
        XCTAssertTrue(worktreeMatchesSidebarFilter(worktree, query: "bbbbbbb"))
        XCTAssertFalse(worktreeMatchesSidebarFilter(worktree, query: "missing"))
    }

    func testRepositoryWatchIndexNarrowsSharedGitRefsToMatchingWorktree() {
        let commonGitURL = URL(fileURLWithPath: "/repositories/sample/.git")
        let secondGitURL = commonGitURL.appendingPathComponent("worktrees/second")
        let firstRootURL = URL(fileURLWithPath: "/repositories/sample")
        let first = makeWorktreeSnapshot(
            name: "first",
            activityAt: Date(),
            isDirty: false,
            rootURL: firstRootURL,
            eventWatchURLs: [
                firstRootURL,
                commonGitURL
            ]
        )
        let second = makeWorktreeSnapshot(
            name: "second",
            activityAt: Date(),
            isDirty: false,
            eventWatchURLs: [
                URL(fileURLWithPath: "/worktrees/second"),
                secondGitURL,
                commonGitURL
            ]
        )
        let project = GitProject(rootURL: URL(fileURLWithPath: "/repositories/sample"))
        let index = RepositoryWatchIndex(
            projects: [
                ProjectState(
                    project: project,
                    snapshot: GitProjectSnapshot(
                        project: project,
                        worktrees: [first, second],
                        refreshedAt: Date()
                    )
                )
            ]
        )

        XCTAssertEqual(
            index.affectedWorktreeIDs(
                for: [commonGitURL.appendingPathComponent("refs/heads/first").path]
            ),
            [first.id]
        )
        XCTAssertEqual(
            index.affectedWorktreeIDs(
                for: [
                    commonGitURL
                        .appendingPathComponent("refs/heads/second.lock")
                        .path
                ]
            ),
            [second.id]
        )
        XCTAssertEqual(
            index.affectedWorktreeIDs(
                for: [commonGitURL.appendingPathComponent("packed-refs").path]
            ),
            [first.id, second.id]
        )
        let contentImpact = index.impact(
            for: [firstRootURL.appendingPathComponent("Sources/App.swift").path]
        )
        XCTAssertEqual(contentImpact.worktreeIDs, [first.id])
        XCTAssertEqual(
            contentImpact.contentPathsByWorktreeID[first.id],
            [firstRootURL.appendingPathComponent("Sources/App.swift").path]
        )
        XCTAssertEqual(
            index.affectedWorktreeIDs(
                for: [secondGitURL.appendingPathComponent("index").path]
            ),
            [second.id]
        )
        XCTAssertEqual(
            index.affectedWorktreeIDs(
                for: [commonGitURL.appendingPathComponent("index").path]
            ),
            [first.id]
        )
        XCTAssertTrue(
            index.affectedWorktreeIDs(
                for: [commonGitURL.appendingPathComponent("objects/ab/cdef").path]
            ).isEmpty
        )
        XCTAssertTrue(
            index.affectedWorktreeIDs(
                for: [commonGitURL.appendingPathComponent("FETCH_HEAD").path]
            ).isEmpty
        )
        let addedWorktreeImpact = index.impact(
            for: [
                commonGitURL
                    .appendingPathComponent("worktrees/new-worktree/HEAD")
                    .path
            ]
        )
        XCTAssertEqual(addedWorktreeImpact.projectIDs, [project.id])
        XCTAssertTrue(addedWorktreeImpact.worktreeIDs.isEmpty)

        let movedWorktreeImpact = index.impact(
            for: [secondGitURL.appendingPathComponent("gitdir").path]
        )
        XCTAssertEqual(movedWorktreeImpact.projectIDs, [project.id])
        XCTAssertTrue(movedWorktreeImpact.worktreeIDs.isEmpty)

        let removedWorktreeImpact = index.impact(for: [secondGitURL.path])
        XCTAssertEqual(removedWorktreeImpact.projectIDs, [project.id])
        XCTAssertTrue(removedWorktreeImpact.worktreeIDs.isEmpty)
        XCTAssertTrue(
            index.affectedWorktreeIDs(
                for: [
                    commonGitURL
                        .appendingPathComponent("fsmonitor--daemon/cookies/123")
                        .path
                ]
            ).isEmpty
        )
    }

    func testRepositoryWatchIndexFullRefreshIncludesEveryWorktreeStatus() {
        let project = GitProject(
            rootURL: URL(fileURLWithPath: "/repositories/sample")
        )
        let first = makeWorktreeSnapshot(
            name: "first",
            activityAt: Date(),
            isDirty: false,
            rootURL: URL(fileURLWithPath: "/worktrees/first")
        )
        let second = makeWorktreeSnapshot(
            name: "second",
            activityAt: Date(),
            isDirty: true,
            rootURL: URL(fileURLWithPath: "/worktrees/second")
        )
        let index = RepositoryWatchIndex(
            projects: [
                ProjectState(
                    project: project,
                    snapshot: GitProjectSnapshot(
                        project: project,
                        worktrees: [first, second],
                        refreshedAt: Date()
                    )
                )
            ]
        )

        XCTAssertEqual(index.fullRefreshImpact.projectIDs, [project.id])
        XCTAssertEqual(index.fullRefreshImpact.worktreeIDs, [first.id, second.id])
        XCTAssertEqual(
            index.fullRefreshImpact.metadataWorktreeIDs,
            [first.id, second.id]
        )
    }


    func testRepositoryFileMonitorReceivesRealFileEvent() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/fsevents-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        let worktree = makeWorktreeSnapshot(
            name: "watched",
            activityAt: Date(),
            isDirty: false,
            eventWatchURLs: [container]
        )
        let project = GitProject(rootURL: container)
        let index = RepositoryWatchIndex(
            projects: [
                ProjectState(
                    project: project,
                    snapshot: GitProjectSnapshot(
                        project: project,
                        worktrees: [worktree],
                        refreshedAt: Date()
                    )
                )
            ]
        )
        let receivedEvent = expectation(description: "FSEvents callback")
        let monitor = RepositoryFileMonitor { impact, _ in
            if impact.worktreeIDs.contains(worktree.id) {
                receivedEvent.fulfill()
            }
        }
        try monitor.update(index: index)
        try Data("changed\n".utf8).write(to: container.appendingPathComponent("change.txt"))

        await fulfillment(of: [receivedEvent], timeout: 5)
        monitor.stop()
    }

    func testRepositoryEventBatchIgnoresHistoryCompletionMarker() {
        let rootURL = URL(fileURLWithPath: "/projects/history-marker")
        let worktree = makeWorktreeSnapshot(
            name: "history-marker",
            activityAt: Date(),
            isDirty: false,
            rootURL: rootURL,
            eventWatchURLs: [rootURL]
        )
        let project = GitProject(rootURL: rootURL)
        let index = RepositoryWatchIndex(
            projects: [
                ProjectState(
                    project: project,
                    snapshot: GitProjectSnapshot(
                        project: project,
                        worktrees: [worktree],
                        refreshedAt: Date()
                    )
                )
            ]
        )
        let batch = RepositoryEventBatch(
            paths: [rootURL.path],
            flags: [
                FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)
            ]
        )

        XCTAssertTrue(batch.impact(using: index).isEmpty)
    }

    func testRepositoryEventBatchKeepsChangesAlongsideHistoryMarker() {
        let rootURL = URL(fileURLWithPath: "/projects/history-and-change")
        let worktree = makeWorktreeSnapshot(
            name: "history-and-change",
            activityAt: Date(),
            isDirty: false,
            rootURL: rootURL,
            eventWatchURLs: [rootURL]
        )
        let project = GitProject(rootURL: rootURL)
        let index = RepositoryWatchIndex(
            projects: [
                ProjectState(
                    project: project,
                    snapshot: GitProjectSnapshot(
                        project: project,
                        worktrees: [worktree],
                        refreshedAt: Date()
                    )
                )
            ]
        )
        let changedPath = rootURL.appendingPathComponent("Sources/App.swift").path
        let batch = RepositoryEventBatch(
            paths: [rootURL.path, changedPath],
            flags: [
                FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone),
                FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
            ]
        )

        XCTAssertEqual(batch.impact(using: index).worktreeIDs, [worktree.id])
    }

    func testRepositoryWatchIndexSkipsContentEventCoveredBySnapshot() throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/covered-event-\(UUID().uuidString)",
            isDirectory: true
        )
        let changedFile = container.appendingPathComponent("Sources/Changed.swift")
        try FileManager.default.createDirectory(
            at: changedFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        try Data("cached\n".utf8).write(to: changedFile)
        let cachedModificationDate = Date(timeIntervalSince1970: 1_000)
        let refreshedAt = Date(timeIntervalSince1970: 2_000)
        try FileManager.default.setAttributes(
            [.modificationDate: cachedModificationDate],
            ofItemAtPath: changedFile.path
        )
        let worktree = makeWorktreeSnapshot(
            name: "covered-event",
            activityAt: cachedModificationDate,
            isDirty: true,
            refreshedAt: refreshedAt,
            rootURL: container,
            eventWatchURLs: [container]
        )
        let project = GitProject(rootURL: container)
        let index = RepositoryWatchIndex(
            projects: [
                ProjectState(
                    project: project,
                    snapshot: GitProjectSnapshot(
                        project: project,
                        worktrees: [worktree],
                        refreshedAt: refreshedAt
                    )
                )
            ]
        )

        XCTAssertTrue(index.impact(for: [changedFile.path]).isEmpty)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 3_000)],
            ofItemAtPath: changedFile.path
        )
        XCTAssertEqual(
            index.impact(for: [changedFile.path]).worktreeIDs,
            [worktree.id]
        )
    }

    func testRepositoryFileMonitorReplaysEventsAfterRestart() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/fsevents-replay-\(UUID().uuidString)",
            isDirectory: true
        )
        let firstURL = container.appendingPathComponent("first", isDirectory: true)
        let secondURL = container.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        let first = makeWorktreeSnapshot(
            name: "first-replay",
            activityAt: Date(),
            isDirty: false,
            eventWatchURLs: [firstURL]
        )
        let second = makeWorktreeSnapshot(
            name: "second-replay",
            activityAt: Date(),
            isDirty: false,
            eventWatchURLs: [secondURL]
        )
        let firstEvent = expectation(description: "Foreground FSEvent")
        let replayedEvent = expectation(description: "Replayed FSEvent")
        let monitor = RepositoryFileMonitor { impact, _ in
            if impact.worktreeIDs.contains(first.id) {
                firstEvent.fulfill()
            }
            if impact.worktreeIDs.contains(second.id) {
                replayedEvent.fulfill()
            }
        }

        try monitor.update(index: makeWatchIndex(worktree: first))
        try Data("foreground\n".utf8).write(
            to: firstURL.appendingPathComponent("change.txt")
        )
        await fulfillment(of: [firstEvent], timeout: 5)
        monitor.stop()

        try Data("background\n".utf8).write(
            to: secondURL.appendingPathComponent("change.txt")
        )
        try monitor.update(index: makeWatchIndex(worktree: second))
        await fulfillment(of: [replayedEvent], timeout: 5)
        monitor.stop()
    }

    func testRepositoryWatchIndexIgnoresGitIndexStateCoveredBySnapshot() throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/index-fingerprint-\(UUID().uuidString)",
            isDirectory: true
        )
        let worktreeURL = container.appendingPathComponent("worktree", isDirectory: true)
        let gitURL = worktreeURL.appendingPathComponent(".git", isDirectory: true)
        let indexURL = gitURL.appendingPathComponent("index")
        try FileManager.default.createDirectory(
            at: gitURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        try Data("cached index".utf8).write(to: indexURL)
        let worktree = makeWorktreeSnapshot(
            name: "cached-index",
            activityAt: Date(),
            isDirty: false,
            refreshedAt: Date().addingTimeInterval(1),
            rootURL: worktreeURL,
            eventWatchURLs: [worktreeURL, gitURL]
        )
        let project = GitProject(rootURL: worktreeURL)
        let index = RepositoryWatchIndex(
            projects: [
                ProjectState(
                    project: project,
                    snapshot: GitProjectSnapshot(
                        project: project,
                        worktrees: [worktree],
                        refreshedAt: Date().addingTimeInterval(1)
                    )
                )
            ]
        )

        XCTAssertTrue(index.impact(for: [indexURL.path]).isEmpty)
        XCTAssertTrue(
            index.impact(for: [indexURL.path + ".lock"]).isEmpty
        )

        try Data("externally changed index".utf8).write(to: indexURL)
        XCTAssertEqual(
            index.affectedWorktreeIDs(for: [indexURL.path]),
            [worktree.id]
        )
    }

    func testRepositoryEventRefreshPrioritizesSelectedWorktreeProject() throws {
        let firstProject = GitProject(rootURL: URL(fileURLWithPath: "/projects/first"))
        let secondProject = GitProject(rootURL: URL(fileURLWithPath: "/projects/second"))
        let thirdProject = GitProject(rootURL: URL(fileURLWithPath: "/projects/third"))
        let states = [firstProject, secondProject, thirdProject].map { project in
            let worktree = makeWorktreeSnapshot(
                name: project.rootURL.lastPathComponent,
                activityAt: Date(),
                isDirty: false,
                rootURL: project.rootURL
            )
            return ProjectState(
                project: project,
                snapshot: GitProjectSnapshot(
                    project: project,
                    worktrees: [worktree],
                    refreshedAt: Date()
                )
            )
        }
        let selectedWorktreeID = try XCTUnwrap(
            states[1].snapshot?.worktrees.first?.id
        )

        let ordered = orderedRepositoryEventProjectIDs(
            Set(states.map(\.id)),
            projects: states,
            selectedWorktreeID: selectedWorktreeID
        )

        XCTAssertEqual(
            ordered,
            [secondProject.id, firstProject.id, thirdProject.id]
        )
    }

    func testRefreshCoordinatorRejectsOlderProjectResultAndTracksAllActiveLoads() {
        var coordinator = RepositoryRefreshCoordinator()
        let projectID = "/repositories/sample"
        let older = coordinator.beginProject(projectID)
        let newer = coordinator.beginProject(projectID)

        XCTAssertFalse(coordinator.acceptsProject(older))
        XCTAssertTrue(coordinator.acceptsProject(newer))
        XCTAssertTrue(coordinator.isLoading(projectID))

        coordinator.finish(newer)
        XCTAssertTrue(coordinator.isLoading(projectID))
        coordinator.finish(older)
        XCTAssertFalse(coordinator.isLoading(projectID))
    }

    func testRefreshCoordinatorPreservesNewerWorktreeDuringProjectRefresh() {
        var coordinator = RepositoryRefreshCoordinator()
        let projectID = "/repositories/sample"
        let worktreeID = "/worktrees/feature"
        let project = coordinator.beginProject(projectID)
        let worktree = coordinator.beginWorktree(worktreeID, projectID: projectID)

        XCTAssertTrue(coordinator.acceptsProject(project))
        XCTAssertTrue(coordinator.shouldPreserveWorktree(worktreeID, fromProject: project))
        XCTAssertTrue(coordinator.acceptsWorktree(worktree))

        let newerProject = coordinator.beginProject(projectID)
        XCTAssertFalse(coordinator.acceptsWorktree(worktree))
        XCTAssertTrue(coordinator.acceptsProject(newerProject))
    }

    func testRefreshCoordinatorRejectsOlderWorktreeResult() {
        var coordinator = RepositoryRefreshCoordinator()
        let projectID = "/repositories/sample"
        let worktreeID = "/worktrees/feature"
        let older = coordinator.beginWorktree(worktreeID, projectID: projectID)
        let newer = coordinator.beginWorktree(worktreeID, projectID: projectID)

        XCTAssertFalse(coordinator.acceptsWorktree(older))
        XCTAssertTrue(coordinator.acceptsWorktree(newer))
    }

    func testFailedRefreshPreservesLastSuccessfulWorktreeState() {
        let activityAt = Date(timeIntervalSince1970: 200_000)
        let current = makeWorktreeSnapshot(
            name: "feature",
            activityAt: activityAt,
            isDirty: true,
            eventWatchURLs: [URL(fileURLWithPath: "/worktrees/feature")]
        )
        let failed = GitWorktreeSnapshot(
            worktree: current.worktree,
            status: .clean,
            diffStat: .zero,
            lastActivityAt: .distantPast,
            errorMessage: "status command failed",
            hasUsableState: false,
            eventWatchURLs: [URL(fileURLWithPath: "/repositories/sample.git")]
        )

        let merged = worktreeSnapshotByApplyingRefresh(
            failed,
            preserving: current
        )

        XCTAssertEqual(merged.status, current.status)
        XCTAssertEqual(merged.diffStat, current.diffStat)
        XCTAssertEqual(merged.lastActivityAt, activityAt)
        XCTAssertTrue(merged.hasUsableState)
        XCTAssertEqual(merged.errorMessage, "status command failed")
        XCTAssertEqual(
            Set(merged.eventWatchURLs),
            Set([
                URL(fileURLWithPath: "/worktrees/feature"),
                URL(fileURLWithPath: "/repositories/sample.git")
            ])
        )

        let recovered = makeWorktreeSnapshot(
            name: "feature",
            activityAt: activityAt.addingTimeInterval(60),
            isDirty: false
        )
        XCTAssertEqual(
            worktreeSnapshotByApplyingRefresh(recovered, preserving: merged),
            recovered
        )

        let usableWithSupplementalError = GitWorktreeSnapshot(
            worktree: current.worktree,
            status: .clean,
            diffStat: .zero,
            lastActivityAt: activityAt.addingTimeInterval(120),
            errorMessage: "Diff statistics: timed out",
            hasUsableState: true,
            eventWatchURLs: current.eventWatchURLs
        )
        XCTAssertEqual(
            worktreeSnapshotByApplyingRefresh(
                usableWithSupplementalError,
                preserving: current
            ),
            usableWithSupplementalError
        )
    }

    func testWorktreeWarningHelpKeepsDetailOutsideCompactRow() {
        let current = makeWorktreeSnapshot(
            name: "feature",
            activityAt: Date(),
            isDirty: false
        )
        let warning = GitWorktreeSnapshot(
            worktree: current.worktree,
            status: current.status,
            diffStat: current.diffStat,
            lastActivityAt: current.lastActivityAt,
            refreshedAt: current.refreshedAt,
            errorMessage: "Ahead/behind: Upstream origin/feature is unavailable.",
            hasUsableState: true,
            eventWatchURLs: current.eventWatchURLs
        )

        XCTAssertEqual(
            worktreeRowHelpText(warning),
            "/worktrees/feature\n\nRefresh warning: "
                + "Ahead/behind: Upstream origin/feature is unavailable."
        )
    }

    func testBranchTrackingDescriptionExplainsCompactArrows() {
        XCTAssertEqual(
            branchTrackingDescription(
                GitBranchStatus(
                    upstreamRef: "origin/main",
                    aheadCount: 0,
                    behindCount: 0
                )
            ),
            "Up to date with origin/main."
        )
        XCTAssertEqual(
            branchTrackingDescription(
                GitBranchStatus(
                    upstreamRef: "origin/main",
                    aheadCount: 1,
                    behindCount: 185
                )
            ),
            "1 commit ahead of origin/main · 185 commits behind origin/main."
        )
        XCTAssertEqual(
            branchTrackingDescription(
                GitBranchStatus(
                    upstreamRef: "origin/main",
                    aheadCount: 0,
                    behindCount: 0,
                    upstreamError: "Upstream origin/main is unavailable."
                )
            ),
            "Upstream origin/main is unavailable."
        )
        XCTAssertNil(
            branchTrackingDescription(
                GitBranchStatus(
                    upstreamRef: nil,
                    aheadCount: 0,
                    behindCount: 0
                )
            )
        )
    }

    func testWorktreeHelpIncludesBranchTrackingState() {
        let current = makeWorktreeSnapshot(
            name: "feature",
            activityAt: Date(),
            isDirty: false
        )
        let tracked = GitWorktreeSnapshot(
            worktree: current.worktree,
            status: GitStatusSnapshot(
                changes: current.status.changes,
                branch: GitBranchStatus(
                    upstreamRef: "origin/feature",
                    aheadCount: 0,
                    behindCount: 4
                ),
                headOID: current.status.headOID,
                branchHead: current.status.branchHead
            ),
            diffStat: current.diffStat,
            lastActivityAt: current.lastActivityAt,
            refreshedAt: current.refreshedAt,
            errorMessage: nil,
            hasUsableState: true,
            eventWatchURLs: current.eventWatchURLs
        )

        XCTAssertEqual(
            worktreeRowHelpText(tracked),
            "/worktrees/feature\n\n4 commits behind origin/feature."
        )
    }

    func testProjectHeaderHelpKeepsCollapsedErrorDiscoverable() {
        let project = GitProject(rootURL: URL(fileURLWithPath: "/projects/sample"))
        let state = ProjectState(
            project: project,
            snapshot: nil,
            errorMessage: "The project directory is unavailable."
        )

        XCTAssertEqual(
            projectHeaderHelpText(state),
            "/projects/sample\n\nProject unavailable: "
                + "The project directory is unavailable."
        )
    }

    func testMembershipDiscoveryUpdatesGitMetadataAndPreservesLoadedState() {
        let current = makeWorktreeSnapshot(
            name: "feature",
            activityAt: Date(timeIntervalSince1970: 200_000),
            isDirty: true,
            eventWatchURLs: [URL(fileURLWithPath: "/repositories/sample/.git")]
        )
        let discovered = GitWorktree(
            rootURL: current.worktree.rootURL,
            headOID: String(repeating: "c", count: 40),
            branchRef: "refs/heads/renamed-feature",
            isBare: false,
            isDetached: false,
            lockedReason: "in use",
            prunableReason: nil
        )

        let merged = worktreeSnapshotByApplyingDiscovery(
            discovered,
            preserving: current
        )

        XCTAssertEqual(merged.worktree, discovered)
        XCTAssertEqual(merged.status, current.status)
        XCTAssertEqual(merged.diffStat, current.diffStat)
        XCTAssertEqual(merged.lastActivityAt, current.lastActivityAt)
        XCTAssertEqual(merged.eventWatchURLs, current.eventWatchURLs)
    }

    private func makeWorktreeSnapshot(
        name: String,
        activityAt: Date,
        isDirty: Bool,
        refreshedAt: Date? = nil,
        rootURL: URL? = nil,
        eventWatchURLs: [URL] = []
    ) -> GitWorktreeSnapshot {
        let worktree = GitWorktree(
            rootURL: rootURL ?? URL(fileURLWithPath: "/worktrees/\(name)"),
            headOID: String(repeating: "b", count: 40),
            branchRef: "refs/heads/\(name)",
            isBare: false,
            isDetached: false,
            lockedReason: nil,
            prunableReason: nil
        )
        let change = GitFileChange(
            path: "Sources/Changed.swift",
            originalPath: nil,
            indexStatus: ".",
            worktreeStatus: "M",
            kind: .ordinary
        )
        return GitWorktreeSnapshot(
            worktree: worktree,
            status: isDirty ? GitStatusSnapshot(changes: [change]) : .clean,
            diffStat: isDirty
                ? GitDiffStat(addedLineCount: 1, deletedLineCount: 0)
                : .zero,
            lastActivityAt: activityAt,
            refreshedAt: refreshedAt,
            errorMessage: nil,
            eventWatchURLs: eventWatchURLs
        )
    }

    private func initializeRepository(
        at repository: URL,
        using runner: GitCommandRunner
    ) async throws {
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        _ = try await runner.run(
            arguments: ["init", "-b", "main"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["config", "user.name", "AgentGit Tests"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["config", "user.email", "agentgit-tests@example.invalid"],
            workingDirectory: repository
        )
        try Data("base\n".utf8).write(
            to: repository.appendingPathComponent("README.md")
        )
        _ = try await runner.run(
            arguments: ["add", "README.md"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["commit", "-m", "Initial commit"],
            workingDirectory: repository
        )
    }

    private func makeWatchIndex(worktree: GitWorktreeSnapshot) -> RepositoryWatchIndex {
        let project = GitProject(rootURL: worktree.worktree.rootURL)
        return RepositoryWatchIndex(
            projects: [
                ProjectState(
                    project: project,
                    snapshot: GitProjectSnapshot(
                        project: project,
                        worktrees: [worktree],
                        refreshedAt: Date()
                    )
                )
            ]
        )
    }
}
