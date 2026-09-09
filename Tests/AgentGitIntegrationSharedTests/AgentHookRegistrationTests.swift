import Foundation
import XCTest
@testable import AgentGitIntegrationShared

final class AgentHookRegistrationTests: XCTestCase {
    func testFailureRequestsDiagnosisOnceAndRearmsAfterSuccessfulRegistration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let storage = fixture.data.appendingPathComponent("associations.json")
        let input: [String: Any] = ["file_path": fixture.repository.appendingPathComponent("tracked.txt").path]
        try Data("corrupt".utf8).write(to: storage)
        let feedback = try XCTUnwrap(fixture.event("PreToolUse", tool: "Write", input: input))
        XCTAssertEqual(feedback.hookSpecificOutput.hookEventName, "PreToolUse")
        XCTAssertLessThan(feedback.hookSpecificOutput.additionalContext.count, 2_000)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(feedback)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["hookSpecificOutput"])
        XCTAssertNil(try fixture.event("PostToolUse", tool: "Write", input: input))

        _ = try fixture.associations.recoverCorruptFile()
        XCTAssertNil(try fixture.event("PreToolUse", tool: "Write", input: input, call: "recovered"))
        try Data("repaired".utf8).write(to: fixture.repository.appendingPathComponent("tracked.txt"))
        XCTAssertNil(try fixture.event("PostToolUse", tool: "Write", input: input, call: "recovered"))
        XCTAssertEqual(try fixture.associations.list().count, 1)
        try Data("corrupt again".utf8).write(to: storage)
        XCTAssertNotNil(try fixture.event("PreToolUse", tool: "Write", input: input, call: "next-failure"))
    }

    func testDiagnosticStillReachesModelWhenPrimaryStorageCannotBeCreated() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let blocked = fixture.container.appendingPathComponent("file-instead-of-directory")
        try Data().write(to: blocked)
        let diagnostic = AgentHookDiagnostic(rootURL: blocked, provider: .codex, pluginVersion: "test")
        defer { diagnostic.resolved(session: fixture.sessionID) }
        XCTAssertNotNil(diagnostic.feedback(event: "PreToolUse", session: fixture.sessionID, message: "storage unavailable"))
        XCTAssertNil(diagnostic.feedback(event: "PostToolUse", session: fixture.sessionID, message: "storage unavailable"))
    }

    func testExistingAssociationNeverProbesAgainUntilRemoved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let registeredAt = Date(timeIntervalSince1970: 10)
        let old = AgentAssociation(
            provider: .codex, sessionID: fixture.sessionID,
            worktreePath: fixture.repository.standardizedFileURL.path,
            title: "Existing task", updatedAt: registeredAt
        )
        _ = try fixture.associations.upsert(old)
        let input: [String: Any] = ["command": "./generate.sh"]
        try fixture.event("PreToolUse", input: input)
        XCTAssertEqual(try fixture.pendingCount(), 0)
        try Data("changed".utf8).write(to: fixture.repository.appendingPathComponent("tracked.txt"))
        try fixture.event("PostToolUse", input: input)
        XCTAssertEqual(try fixture.associations.list(), [old])
        XCTAssertTrue(try fixture.audit.list().isEmpty)

        _ = try fixture.associations.remove(
            provider: .codex, sessionID: fixture.sessionID, worktreePath: old.worktreePath
        )
        try fixture.event("PreToolUse", input: input, call: "after-removal")
        XCTAssertEqual(try fixture.pendingCount(), 1)
        try Data("changed again".utf8).write(to: fixture.repository.appendingPathComponent("tracked.txt"))
        try fixture.event("PostToolUse", input: input, call: "after-removal")
        XCTAssertEqual(try fixture.associations.list().map(\.id), [old.id])
        XCTAssertEqual(try fixture.pendingCount(), 0)
    }

    func testPatchLinksActualTargetsAcrossWorktreesWithoutMovingOriginalAssociation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let linked = fixture.container.appendingPathComponent("linked worktree")
        try fixture.git(["worktree", "add", "--detach", linked.path])
        let old = fixture.repository.appendingPathComponent("tracked.txt")
        let added = linked.appendingPathComponent("new.txt")
        let input: [String: Any] = ["command": "*** Begin Patch\n*** Update File: \(old.path)\n@@\n-before\n+after\n*** Add File: \(added.path)\n+new\n*** End Patch"]
        try fixture.event("PreToolUse", tool: "apply_patch", input: input)
        try Data("after\n".utf8).write(to: old)
        try Data("new\n".utf8).write(to: added)
        try fixture.event("PostToolUse", tool: "apply_patch", input: input)
        let rows = try fixture.associations.list()
        XCTAssertEqual(Set(rows.map(\.worktreePath)), Set([fixture.repository.path, linked.path]))
        XCTAssertEqual(Set(rows.map(\.sessionID)), [fixture.sessionID])
        XCTAssertTrue(rows.allSatisfy { $0.title.isEmpty })
        XCTAssertEqual(try fixture.pendingCount(), 0)
    }

    func testDirtyReadOnlyShellDoesNotRegisterButPartialGeneratorFailureDoes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tracked = fixture.repository.appendingPathComponent("tracked.txt")
        try Data("dirty\n".utf8).write(to: tracked)
        let input: [String: Any] = ["command": "git status --short"]
        try fixture.event("PreToolUse", input: input)
        try fixture.git(["--no-optional-locks", "status", "--short"])
        try fixture.event("PostToolUse", input: input)
        XCTAssertTrue(try fixture.associations.list().isEmpty)

        let generator: [String: Any] = ["command": "python3 - <<'PY'\n# opaque generator body\nPY"]
        try fixture.event("PreToolUse", input: generator, call: "generator")
        // Same size and the same Git status entry; file metadata must still detect the change.
        try Data("other\n".utf8).write(to: tracked)
        try fixture.event("PostToolUse", input: generator, call: "generator", response: ["exit_code": 1])
        XCTAssertEqual(try fixture.associations.list().count, 1)
    }

    /// 超大仓库的探测会降到只看 .git 元数据这一档。降级后基线仍要能复算：
    /// 看不见的改动不能误登记，索引变化必须照常登记。
    func testDegradedProbeScopeKeepsBaselineComparable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.forceProbeScope("gitMetadata")

        let readOnly: [String: Any] = ["command": "./inspect.sh"]
        try fixture.event("PreToolUse", input: readOnly)
        try Data("dirty\n".utf8).write(to: fixture.repository.appendingPathComponent("tracked.txt"))
        try fixture.event("PostToolUse", input: readOnly)
        XCTAssertTrue(try fixture.associations.list().isEmpty)

        let staged: [String: Any] = ["command": "git add -A"]
        try fixture.event("PreToolUse", input: staged, call: "staged")
        try fixture.git(["add", "."])
        try fixture.event("PostToolUse", input: staged, call: "staged")
        XCTAssertEqual(try fixture.associations.list().map(\.worktreePath), [fixture.repository.path])
    }

    func testShellWithLiteralDirectoryTargetsLinkedWorktree() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let linked = fixture.container.appendingPathComponent("linked worktree")
        try fixture.git(["worktree", "add", "--detach", linked.path])
        let input: [String: Any] = ["command": "cd '\(linked.path)' && ./generate.sh"]
        try fixture.event("PreToolUse", input: input)
        try Data("generated".utf8).write(to: linked.appendingPathComponent("generated.txt"))
        try fixture.event("PostToolUse", input: input)
        XCTAssertEqual(try fixture.associations.list().map(\.worktreePath), [linked.path])
    }

    func testDynamicDirectoryAndMissingIdentityNeverGuessAnAssociation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let input: [String: Any] = ["command": "cd \"$OTHER_REPO\" && ./generate.sh"]
        try fixture.event("PreToolUse", input: input)
        try Data("new".utf8).write(to: fixture.repository.appendingPathComponent("tracked.txt"))
        try fixture.event("PostToolUse", input: input)
        fixture.handler.handle(Data("{\"hook_event_name\":\"SessionStart\"}".utf8))
        XCTAssertTrue(try fixture.associations.list().isEmpty)
        XCTAssertTrue(try fixture.audit.list().contains { $0.outcome == .failed })
        XCTAssertEqual(try fixture.pendingCount(), 0)
    }

    func testSessionStartAndUnchangedWriteAreReceiptsOnly() throws {
        let fixture = try Fixture(provider: .claude)
        defer { fixture.remove() }
        try fixture.event("SessionStart")
        XCTAssertEqual(try fixture.audit.list().first?.action, .hook)
        XCTAssertTrue(try fixture.associations.list().isEmpty)
        let input: [String: Any] = ["file_path": fixture.repository.appendingPathComponent("tracked.txt").path]
        try fixture.event("PreToolUse", tool: "Write", input: input)
        try fixture.event("PostToolUse", tool: "Write", input: input)
        XCTAssertTrue(try fixture.associations.list().isEmpty)
        XCTAssertEqual(try fixture.audit.list().first?.outcome, .skipped)
    }

    func testNextWriteRetriesAfterStorageFailureAndAutomaticRefreshPreservesTitle() throws {
        let fixture = try Fixture(provider: .claude)
        defer { fixture.remove() }
        let path = fixture.repository.appendingPathComponent("tracked.txt")
        let input: [String: Any] = ["file_path": path.path]
        try fixture.event("PreToolUse", tool: "Edit", input: input)
        try Data("changed".utf8).write(to: path)
        try Data("corrupt".utf8).write(to: fixture.data.appendingPathComponent("associations.json"))
        try fixture.event("PostToolUse", tool: "Edit", input: input)
        XCTAssertEqual(try fixture.audit.list().first?.outcome, .failed)
        XCTAssertEqual(try fixture.pendingCount(), 0)

        _ = try fixture.associations.recoverCorruptFile()
        try fixture.event("PreToolUse", tool: "Edit", input: input, call: "retry")
        try Data("retried".utf8).write(to: path)
        try fixture.event("PostToolUse", tool: "Edit", input: input, call: "retry")
        let row = try XCTUnwrap(fixture.associations.list().first)
        let registeredAt = Date(timeIntervalSince1970: row.updatedAt.timeIntervalSince1970.rounded(.up))
        _ = try fixture.associations.upsert(AgentAssociation(
            provider: .claude, sessionID: row.sessionID, worktreePath: row.worktreePath,
            title: "Named task", updatedAt: registeredAt
        ))
        let service = AgentSkillRegistrationService(associationStore: fixture.associations, auditStore: fixture.audit)
        _ = try service.register(provider: .claude, sessionID: row.sessionID, candidateURL: fixture.repository, now: registeredAt.addingTimeInterval(10))
        let unchanged = try XCTUnwrap(fixture.associations.list().first)
        XCTAssertEqual(unchanged.title, "Named task")
        XCTAssertEqual(unchanged.updatedAt, registeredAt)
        _ = try service.register(provider: .claude, sessionID: row.sessionID, candidateURL: fixture.repository, now: registeredAt.addingTimeInterval(61))
        XCTAssertEqual(try fixture.associations.list().first?.updatedAt, registeredAt.addingTimeInterval(61))
    }

    private final class Fixture {
        let container: URL
        let repository: URL
        let data: URL
        let provider: AgentProvider
        let sessionID = "11111111-1111-4111-8111-111111111111"
        var handler: AgentHookRegistration { AgentHookRegistration(rootURL: data, provider: provider) }
        var associations: AgentAssociationStore { AgentAssociationStore(storeURL: data.appendingPathComponent("associations.json")) }
        var audit: AgentRegistrationAuditStore { AgentRegistrationAuditStore(storeURL: data.appendingPathComponent("registration-events.json")) }

        init(provider: AgentProvider = .codex) throws {
            self.provider = provider
            container = FileManager.default.temporaryDirectory.appendingPathComponent("agentgit-hooks-\(UUID().uuidString)").resolvingSymlinksInPath()
            repository = container.appendingPathComponent("repository")
            data = container.appendingPathComponent("data")
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            try git(["init", "-b", "main"])
            try Data("before\n".utf8).write(to: repository.appendingPathComponent("tracked.txt"))
            try git(["add", "."])
            try git(["-c", "user.name=AgentGit Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-m", "Fixture"])
        }

        @discardableResult
        func event(_ name: String, tool: String = "Bash", input: [String: Any] = [:], call: String = "call", response: [String: Any] = [:]) throws -> AgentHookFeedback? {
            handler.handle(try JSONSerialization.data(withJSONObject: [
                "hook_event_name": name, "session_id": sessionID, "cwd": repository.path,
                "tool_name": tool, "tool_input": input, "tool_use_id": call, "tool_response": response
            ]))
        }

        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = repository
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }

        func forceProbeScope(_ scope: String) throws {
            let cache = [repository.path: [
                "scope": scope, "updatedAt": Date().timeIntervalSinceReferenceDate
            ] as [String: Any]]
            try JSONSerialization.data(withJSONObject: cache)
                .write(to: data.appendingPathComponent("probe-scopes.json"))
        }

        func pendingCount() throws -> Int {
            let path = data.appendingPathComponent("hook-pending")
            return FileManager.default.fileExists(atPath: path.path)
                ? try FileManager.default.contentsOfDirectory(atPath: path.path).count : 0
        }

        func remove() { try? FileManager.default.removeItem(at: container) }
    }
}
