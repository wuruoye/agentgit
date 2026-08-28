import Foundation
import XCTest
@testable import AgentGitIntegrationShared

final class AgentWriteIntentTests: XCTestCase {
    func testHookBlocksFirstRepositoryWriteThenAllowsRegisteredRetry() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let event = try hookEvent(
            sessionID: "11111111-1111-4111-8111-111111111111",
            cwd: fixture.repository.path,
            toolName: "Bash",
            command: "git add README.md"
        )
        let guardService = AgentWriteRegistrationGuard(
            associationStore: fixture.associations,
            intentStore: fixture.intents,
            responseStore: fixture.responses,
            auditStore: fixture.audit
        )

        let decision = guardService.evaluate(
            provider: .claude,
            event: event,
            now: Date(timeIntervalSince1970: 100)
        )
        guard case let .registrationRequired(intent) = decision else {
            XCTFail("Expected a registration request; received \(decision)")
            return
        }
        XCTAssertEqual(intent.worktreePath, fixture.repository.path)
        XCTAssertEqual(intent.toolName, "Bash")
        XCTAssertEqual(
            try fixture.intents.load(
                token: intent.id.uuidString,
                now: Date(timeIntervalSince1970: 101)
            ),
            intent
        )
        let requestedEvent = try XCTUnwrap(fixture.audit.list().first)
        XCTAssertEqual(requestedEvent.action, .hookRequested)
        XCTAssertEqual(requestedEvent.outcome, .requested)

        let handoff = AgentWriteRegistrationHandoffService(
            intentStore: fixture.intents,
            responseStore: fixture.responses
        )
        let response = try handoff.prepare(
            token: intent.id.uuidString,
            title: "Prepare staged review",
            summary: "Stage README changes for review.",
            now: Date(timeIntervalSince1970: 102)
        )

        XCTAssertEqual(response.provider, .claude)
        XCTAssertEqual(response.worktreePath, fixture.repository.path)
        XCTAssertEqual(response.title, "Prepare staged review")
        XCTAssertTrue(try fixture.associations.list().isEmpty)
        XCTAssertEqual(
            guardService.evaluate(
                provider: .claude,
                event: event,
                now: Date(timeIntervalSince1970: 103)
            ),
            .allow
        )
        let association = try XCTUnwrap(fixture.associations.list().first)
        XCTAssertEqual(association.provider, .claude)
        XCTAssertEqual(association.worktreePath, fixture.repository.path)
        XCTAssertEqual(association.title, "Prepare staged review")
        XCTAssertThrowsError(
            try fixture.intents.load(
                token: intent.id.uuidString,
                now: Date(timeIntervalSince1970: 103)
            )
        ) { error in
            XCTAssertEqual(error as? AgentWriteIntentStoreError, .intentMissing)
        }
    }

    func testFileWriteUsesAbsoluteTargetToFindWorktree() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let target = fixture.repository.appendingPathComponent("Sources/New.swift")
        let data = try JSONSerialization.data(withJSONObject: [
            "session_id": "22222222-2222-4222-8222-222222222222",
            "cwd": "/tmp",
            "tool_name": "Write",
            "tool_input": ["file_path": target.path]
        ])
        let event = try JSONDecoder().decode(AgentHookEvent.self, from: data)
        let guardService = AgentWriteRegistrationGuard(
            associationStore: fixture.associations,
            intentStore: fixture.intents,
            responseStore: fixture.responses,
            auditStore: fixture.audit
        )

        guard case let .registrationRequired(intent) = guardService.evaluate(
            provider: .codex,
            event: event
        ) else {
            XCTFail("Expected file write registration")
            return
        }
        XCTAssertEqual(intent.worktreePath, fixture.repository.path)
        XCTAssertEqual(intent.targetPath, target.path)
    }

    func testReadOnlyToolAndDirectoryOutsideRepositoryAreAllowed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let outsideDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agentgit-hook-outside-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: outsideDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }
        let guardService = AgentWriteRegistrationGuard(
            associationStore: fixture.associations,
            intentStore: fixture.intents,
            responseStore: fixture.responses,
            auditStore: fixture.audit
        )
        let readEvent = try hookEvent(
            sessionID: "33333333-3333-4333-8333-333333333333",
            cwd: fixture.repository.path,
            toolName: "Read",
            command: nil
        )
        let outsideEvent = try hookEvent(
            sessionID: "33333333-3333-4333-8333-333333333333",
            cwd: outsideDirectory.path,
            toolName: "Bash",
            command: "touch outside.txt"
        )

        XCTAssertEqual(
            guardService.evaluate(provider: .codex, event: readEvent),
            .allow
        )
        XCTAssertEqual(
            guardService.evaluate(provider: .codex, event: outsideEvent),
            .allow
        )
    }

    func testReadOnlyShellCommandsStaySilentInsideRepository() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let guardService = AgentWriteRegistrationGuard(
            associationStore: fixture.associations,
            intentStore: fixture.intents,
            responseStore: fixture.responses,
            auditStore: fixture.audit
        )
        let commands = [
            "git status --short",
            "git diff -- README.md",
            "git log -5 --oneline",
            "git show HEAD:README.md",
            "git worktree list --porcelain",
            "swift test",
            "scripts/build-app.sh release",
            "rg --files",
            "python3 scripts/check.py",
            "git status --short > /tmp/agentgit-status.txt",
            "printf status > /tmp/agentgit-status.txt"
        ]

        for command in commands {
            let event = try hookEvent(
                sessionID: "88888888-8888-4888-8888-888888888888",
                cwd: fixture.repository.path,
                toolName: "Bash",
                command: command
            )
            XCTAssertEqual(
                guardService.evaluate(provider: .codex, event: event),
                .allow,
                command
            )
        }
        XCTAssertTrue(try fixture.associations.list().isEmpty)
        XCTAssertTrue(try fixture.audit.list().isEmpty)
        XCTAssertTrue(
            fixture.intents.activeIntents(
                provider: .codex,
                sessionID: "88888888-8888-4888-8888-888888888888",
                worktreePath: fixture.repository.path
            ).isEmpty
        )
    }

    func testExplicitShellMutationsRequireRegistration() throws {
        let commands = [
            "git add README.md",
            "printf changed > README.md",
            "touch Sources/New.swift",
            "sed -i '' 's/old/new/' README.md",
            "git stash push -m checkpoint",
            "git worktree add ../feature -b feature",
            "gofmt -w main.go"
        ]

        for command in commands {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            let guardService = AgentWriteRegistrationGuard(
                associationStore: fixture.associations,
                intentStore: fixture.intents,
                responseStore: fixture.responses,
                auditStore: fixture.audit
            )
            let event = try hookEvent(
                sessionID: "99999999-9999-4999-8999-999999999999",
                cwd: fixture.repository.path,
                toolName: "Bash",
                command: command
            )

            guard case .registrationRequired = guardService.evaluate(
                provider: .claude,
                event: event
            ) else {
                XCTFail("Expected repository mutation registration for \(command)")
                continue
            }
        }
    }

    func testSkillRegistrationCommandsBypassRecursiveHook() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let event = try hookEvent(
            sessionID: "44444444-4444-4444-8444-444444444444",
            cwd: fixture.repository.path,
            toolName: "Bash",
            command: "AGENTGIT_SKILL_CALL=1 ${PLUGIN_ROOT}/bin/AgentGitHookBridge inspect --token 11111111-1111-4111-8111-111111111111"
        )
        let guardService = AgentWriteRegistrationGuard(
            associationStore: fixture.associations,
            intentStore: fixture.intents,
            responseStore: fixture.responses,
            auditStore: fixture.audit
        )

        XCTAssertEqual(
            guardService.evaluate(provider: .codex, event: event),
            .allow
        )
    }

    func testUnknownCommandToolUsesCommandIntent() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let event = try hookEvent(
            sessionID: "66666666-6666-4666-8666-666666666666",
            cwd: fixture.repository.path,
            toolName: "native_shell_v2",
            command: "printf changed > README.md"
        )
        let guardService = AgentWriteRegistrationGuard(
            associationStore: fixture.associations,
            intentStore: fixture.intents,
            responseStore: fixture.responses,
            auditStore: fixture.audit
        )

        guard case .registrationRequired = guardService.evaluate(
            provider: .codex,
            event: event
        ) else {
            XCTFail("Expected unknown command tool registration")
            return
        }

        let readEvent = try hookEvent(
            sessionID: "66666666-6666-4666-8666-666666666666",
            cwd: fixture.repository.path,
            toolName: "native_shell_v2",
            command: "git status --short"
        )
        XCTAssertEqual(
            guardService.evaluate(provider: .codex, event: readEvent),
            .allow
        )
    }

    func testCodexCmdInputIsClassifiedAsRepositoryWrite() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let data = try JSONSerialization.data(withJSONObject: [
            "session_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "cwd": fixture.repository.path,
            "tool_name": "exec_command",
            "tool_input": ["cmd": "git add README.md"]
        ])
        let event = try JSONDecoder().decode(AgentHookEvent.self, from: data)
        let guardService = AgentWriteRegistrationGuard(
            associationStore: fixture.associations,
            intentStore: fixture.intents,
            responseStore: fixture.responses,
            auditStore: fixture.audit
        )

        guard case .registrationRequired = guardService.evaluate(
            provider: .codex,
            event: event
        ) else {
            XCTFail("Expected cmd input registration")
            return
        }
    }

    func testGitDashCUsesTheModifiedRepository() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let event = try hookEvent(
            sessionID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            cwd: fixture.container.path,
            toolName: "Bash",
            command: "git -C \"\(fixture.repository.path)\" add README.md"
        )
        let guardService = AgentWriteRegistrationGuard(
            associationStore: fixture.associations,
            intentStore: fixture.intents,
            responseStore: fixture.responses,
            auditStore: fixture.audit
        )

        guard case let .registrationRequired(intent) = guardService.evaluate(
            provider: .claude,
            event: event
        ) else {
            XCTFail("Expected git -C registration")
            return
        }
        XCTAssertEqual(intent.worktreePath, fixture.repository.path)
        XCTAssertEqual(intent.targetPath, fixture.repository.path)
    }

    func testSkillDefinitionReadCommandBypassesRecursiveHook() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let event = try hookEvent(
            sessionID: "77777777-7777-4777-8777-777777777777",
            cwd: fixture.repository.path,
            toolName: "native_shell_v2",
            command: "wc -l SKILL.md && sed -n '1,240p' SKILL.md"
        )
        let guardService = AgentWriteRegistrationGuard(
            associationStore: fixture.associations,
            intentStore: fixture.intents,
            responseStore: fixture.responses,
            auditStore: fixture.audit
        )

        XCTAssertEqual(
            guardService.evaluate(provider: .codex, event: event),
            .allow
        )
    }

    func testExpiredIntentCannotRegister() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let intent = AgentWriteIntent(
            provider: .codex,
            sessionID: "55555555-5555-4555-8555-555555555555",
            worktreePath: fixture.repository.path,
            toolName: "apply_patch",
            targetPath: nil,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        try fixture.intents.save(intent)

        XCTAssertThrowsError(
            try AgentWriteRegistrationHandoffService(
                intentStore: fixture.intents,
                responseStore: fixture.responses
            ).prepare(
                token: intent.id.uuidString,
                title: "Expired task",
                summary: "Expired intent",
                now: Date(timeIntervalSince1970: 1_001)
            )
        ) { error in
            XCTAssertEqual(error as? AgentWriteIntentStoreError, .intentExpired)
        }
        XCTAssertTrue(try fixture.associations.list().isEmpty)
    }

    func testLegacyAuditValuesDecodeAsHookRequest() throws {
        let data = Data(
            """
            {
              "id": "11111111-1111-4111-8111-111111111111",
              "provider": "codex",
              "action": "serverStarted",
              "outcome": "ready",
              "sessionID": null,
              "worktreePath": null,
              "message": "Legacy event",
              "createdAt": "2026-08-28T00:00:00Z"
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let event = try decoder.decode(AgentRegistrationEvent.self, from: data)

        XCTAssertEqual(event.action, .hookRequested)
        XCTAssertEqual(event.outcome, .requested)
    }

    private func makeFixture() throws -> HookFixture {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/hook-registration-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        try runGit(["init", "-b", "main"], in: repository)
        return HookFixture(
            container: container,
            repository: repository.standardizedFileURL,
            associations: AgentAssociationStore(
                storeURL: container.appendingPathComponent("associations.json")
            ),
            intents: AgentWriteIntentStore(
                directoryURL: container.appendingPathComponent("pending")
            ),
            responses: AgentWriteRegistrationResponseStore(
                directoryURL: container.appendingPathComponent("responses")
            ),
            audit: AgentRegistrationAuditStore(
                storeURL: container.appendingPathComponent("events.json")
            )
        )
    }

    private func hookEvent(
        sessionID: String,
        cwd: String,
        toolName: String,
        command: String?
    ) throws -> AgentHookEvent {
        var toolInput: [String: Any] = [:]
        if let command {
            toolInput["command"] = command
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "session_id": sessionID,
            "cwd": cwd,
            "tool_name": toolName,
            "tool_input": toolInput
        ])
        return try JSONDecoder().decode(AgentHookEvent.self, from: data)
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

private struct HookFixture {
    let container: URL
    let repository: URL
    let associations: AgentAssociationStore
    let intents: AgentWriteIntentStore
    let responses: AgentWriteRegistrationResponseStore
    let audit: AgentRegistrationAuditStore
}
