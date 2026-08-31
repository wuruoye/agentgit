import Foundation
import XCTest
@testable import AgentGitIntegrationShared

final class AgentAssociationStoreTests: XCTestCase {

    func testStoresMultipleSessionsAndMovesOneSessionBetweenWorktrees() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-associations-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        let storeURL = container.appendingPathComponent("associations.json")
        let store = AgentAssociationStore(storeURL: storeURL)
        let codex = AgentAssociation(
            provider: .codex,
            sessionID: "11111111-1111-4111-8111-111111111111",
            worktreePath: "/worktrees/first",
            title: "Codex task",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let claude = AgentAssociation(
            provider: .claude,
            sessionID: "22222222-2222-4222-8222-222222222222",
            worktreePath: "/worktrees/first",
            title: "Claude task",
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        _ = try store.upsert(codex)
        _ = try store.upsert(claude)
        XCTAssertEqual(try store.list().map(\.id), [claude.id, codex.id])

        let moved = AgentAssociation(
            provider: codex.provider,
            sessionID: codex.sessionID,
            worktreePath: "/worktrees/second",
            title: codex.title,
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        _ = try store.upsert(moved)
        let restored = try AgentAssociationStore(storeURL: storeURL).list()
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.first { $0.id == codex.id }?.worktreePath, "/worktrees/second")

        let attributes = try FileManager.default.attributesOfItem(atPath: storeURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testConcurrentStoreInstancesPreserveThreeMostRecentSessions() throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/associations-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: container)
        }
        let storeURL = container.appendingPathComponent("associations.json")
        let errors = AssociationStoreErrorCollector()

        DispatchQueue.concurrentPerform(iterations: 48) { index in
            do {
                let association = AgentAssociation(
                    provider: index.isMultiple(of: 2) ? .codex : .claude,
                    sessionID: "session-\(index)",
                    worktreePath: "/worktrees/concurrent",
                    title: "Concurrent task \(index)",
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
                )
                _ = try AgentAssociationStore(storeURL: storeURL).upsert(association)
            } catch {
                errors.append(error)
            }
        }

        XCTAssertTrue(errors.values.isEmpty, errors.values.joined(separator: "\n"))
        let associations = try AgentAssociationStore(storeURL: storeURL).list()
        XCTAssertEqual(associations.count, 3)
        XCTAssertEqual(
            associations.map(\.sessionID),
            ["session-47", "session-46", "session-45"]
        )
        let lockAttributes = try FileManager.default.attributesOfItem(
            atPath: storeURL.appendingPathExtension("lock").path
        )
        XCTAssertEqual((lockAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testFourthSessionEvictsLeastRecentlyUsedAssociation() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-lru-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let store = AgentAssociationStore(
            storeURL: container.appendingPathComponent("associations.json")
        )
        let worktreePath = "/worktrees/lru"
        for index in 1...3 {
            _ = try store.upsert(
                AgentAssociation(
                    provider: index.isMultiple(of: 2) ? .claude : .codex,
                    sessionID: "session-\(index)",
                    worktreePath: worktreePath,
                    title: "Task \(index)",
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
                )
            )
        }
        _ = try store.upsert(
            AgentAssociation(
                provider: .codex,
                sessionID: "session-1",
                worktreePath: worktreePath,
                title: "",
                updatedAt: Date(timeIntervalSince1970: 4)
            )
        )
        _ = try store.upsert(
            AgentAssociation(
                provider: .claude,
                sessionID: "session-4",
                worktreePath: worktreePath,
                title: "Task 4",
                updatedAt: Date(timeIntervalSince1970: 5)
            )
        )

        let associations = try store.list()
        XCTAssertEqual(
            associations.map(\.sessionID),
            ["session-4", "session-1", "session-3"]
        )
        XCTAssertEqual(
            associations.first { $0.sessionID == "session-1" }?.title,
            "Task 1"
        )
        XCTAssertFalse(associations.contains { $0.sessionID == "session-2" })
    }

    func testCrossProcessLRUKeepsFractionalTimestampOrder() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-fractional-lru-\(UUID().uuidString)")
        let storeURL = container.appendingPathComponent("associations.json")
        defer { try? FileManager.default.removeItem(at: container) }
        let associations = [
            ("a-oldest", 100.1),
            ("z-second", 100.2),
            ("y-third", 100.3),
            ("x-newest", 100.4),
        ]

        for (sessionID, timestamp) in associations {
            _ = try AgentAssociationStore(storeURL: storeURL).upsert(
                AgentAssociation(
                    provider: .claude,
                    sessionID: sessionID,
                    worktreePath: "/worktrees/fractional-lru",
                    title: sessionID,
                    updatedAt: Date(timeIntervalSince1970: timestamp)
                )
            )
        }

        XCTAssertEqual(
            try AgentAssociationStore(storeURL: storeURL).list().map(\.sessionID),
            ["x-newest", "y-third", "z-second"]
        )
    }

    func testListMigratesExistingStoreToThreeSessionsPerWorktree() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-limit-migration-\(UUID().uuidString)")
        let storeURL = container.appendingPathComponent("associations.json")
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        let associations = (1...4).map { index in
            AgentAssociation(
                provider: index.isMultiple(of: 2) ? .claude : .codex,
                sessionID: "session-\(index)",
                worktreePath: "/worktrees/migration",
                title: "Task \(index)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(associations).write(to: storeURL)
        let store = AgentAssociationStore(storeURL: storeURL)

        XCTAssertEqual(
            try store.list().map(\.sessionID),
            ["session-4", "session-3", "session-2"]
        )
        XCTAssertEqual(
            try store.list().map(\.sessionID),
            ["session-4", "session-3", "session-2"]
        )
    }

    func testRegistrationAuditStoresRecentEventsWithPrivatePermissions() throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/registration-audit-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        let storeURL = container.appendingPathComponent("registration-events.json")
        let store = AgentRegistrationAuditStore(storeURL: storeURL)

        for index in 0..<205 {
            _ = try store.record(
                AgentRegistrationEvent(
                    provider: index.isMultiple(of: 2) ? .codex : .claude,
                    action: .register,
                    outcome: index == 204 ? .rejected : .succeeded,
                    sessionID: "session-\(index)",
                    worktreePath: "/worktrees/feature-\(index)",
                    message: "Registration event \(index)",
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index))
                )
            )
        }

        let events = try AgentRegistrationAuditStore(storeURL: storeURL).list()
        XCTAssertEqual(events.count, 200)
        XCTAssertEqual(events.first?.sessionID, "session-204")
        XCTAssertEqual(events.last?.sessionID, "session-5")
        XCTAssertEqual(events.first?.outcome, .rejected)
        let attributes = try FileManager.default.attributesOfItem(atPath: storeURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRegistrationAuditKeepsFractionalTimestampOrderAcrossStoreInstances() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-fractional-audit-\(UUID().uuidString)")
        let storeURL = container.appendingPathComponent("registration-events.json")
        defer { try? FileManager.default.removeItem(at: container) }
        let events = [
            ("00000000-0000-4000-8000-000000000001", "oldest", 100.1),
            ("ffffffff-ffff-4fff-8fff-fffffffffff2", "second", 100.2),
            ("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee3", "third", 100.3),
            ("dddddddd-dddd-4ddd-8ddd-ddddddddddd4", "newest", 100.4),
        ]

        for (id, sessionID, timestamp) in events {
            _ = try AgentRegistrationAuditStore(storeURL: storeURL).record(
                AgentRegistrationEvent(
                    id: try XCTUnwrap(UUID(uuidString: id)),
                    provider: .claude,
                    action: .register,
                    outcome: .succeeded,
                    sessionID: sessionID,
                    worktreePath: "/worktrees/fractional-audit",
                    message: sessionID,
                    createdAt: Date(timeIntervalSince1970: timestamp)
                )
            )
        }

        XCTAssertEqual(
            try AgentRegistrationAuditStore(storeURL: storeURL).list()
                .compactMap(\.sessionID),
            ["newest", "third", "second", "oldest"]
        )
    }

    func testRegistrationAuditDropsUnsupportedLegacyEventsOnRead() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-audit-migration-\(UUID().uuidString)")
        let storeURL = container.appendingPathComponent("registration-events.json")
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        let validEvent = AgentRegistrationEvent(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            provider: .codex,
            action: .register,
            outcome: .succeeded,
            sessionID: "current-session",
            worktreePath: "/worktrees/current",
            message: "Current registration",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let validObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: encoder.encode(validEvent)
            ) as? [String: Any]
        )
        let unsupportedObject: [String: Any] = [
            "id": "22222222-2222-4222-8222-222222222222",
            "provider": "codex",
            "action": "unsupported",
            "outcome": "unsupported",
            "sessionID": "old-session",
            "worktreePath": "/worktrees/old",
            "message": "Unsupported event",
            "createdAt": "1970-01-01T00:00:50Z"
        ]
        try JSONSerialization.data(
            withJSONObject: [unsupportedObject, validObject]
        ).write(to: storeURL)
        let store = AgentRegistrationAuditStore(storeURL: storeURL)

        let events = try store.list()

        XCTAssertEqual(events, [validEvent])
        let decoder = makeAgentPersistenceJSONDecoder()
        let migrated = try decoder.decode(
            [AgentRegistrationEvent].self,
            from: Data(contentsOf: storeURL)
        )
        XCTAssertEqual(migrated, [validEvent])
    }

    func testRecoversCorruptAssociationStoreWithPrivateBackup() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-corrupt-associations-\(UUID().uuidString)")
        let storeURL = container.appendingPathComponent("associations.json")
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        let corruptData = Data("{invalid associations".utf8)
        try corruptData.write(to: storeURL)
        let store = AgentAssociationStore(storeURL: storeURL)
        XCTAssertThrowsError(try store.list()) { error in
            XCTAssertEqual(
                error as? AgentPersistenceStoreError,
                .invalidAssociations
            )
        }

        let backupURL = try XCTUnwrap(store.recoverCorruptFile())

        XCTAssertEqual(try Data(contentsOf: backupURL), corruptData)
        XCTAssertTrue(try store.list().isEmpty)
        let association = AgentAssociation(
            provider: .codex,
            sessionID: "recovered-session",
            worktreePath: "/worktrees/recovered",
            title: "Recovered task",
            updatedAt: Date()
        )
        XCTAssertEqual(try store.upsert(association), [association])
        let backupAttributes = try FileManager.default.attributesOfItem(
            atPath: backupURL.path
        )
        XCTAssertEqual(
            (backupAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
    }

    func testRecoversCorruptRegistrationAuditWithPrivateBackup() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-corrupt-audit-\(UUID().uuidString)")
        let storeURL = container.appendingPathComponent("registration-events.json")
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        let corruptData = Data("[invalid audit".utf8)
        try corruptData.write(to: storeURL)
        let store = AgentRegistrationAuditStore(storeURL: storeURL)
        XCTAssertThrowsError(try store.list()) { error in
            XCTAssertEqual(
                error as? AgentPersistenceStoreError,
                .invalidRegistrationEvents
            )
        }

        let backupURL = try XCTUnwrap(store.recoverCorruptFile())

        XCTAssertEqual(try Data(contentsOf: backupURL), corruptData)
        XCTAssertTrue(try store.list().isEmpty)
        let backupAttributes = try FileManager.default.attributesOfItem(
            atPath: backupURL.path
        )
        XCTAssertEqual(
            (backupAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw NSError(
                domain: "AgentGitIntegrationSharedTests.Git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}

private final class AssociationStoreErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return errors
    }

    func append(_ error: any Error) {
        lock.lock()
        errors.append(String(describing: error))
        lock.unlock()
    }
}
