import Foundation
import XCTest
@testable import AgentGitIntegrationShared

final class AgentSkillRegistrationTests: XCTestCase {
    func testSkillChecksRegistersAndRefreshesExistingAssociation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.containerURL) }
        let sessionID = "11111111-1111-4111-8111-111111111111"

        let initial = try fixture.service.status(
            provider: .codex,
            sessionID: sessionID,
            candidateURL: fixture.nestedURL,
            now: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(initial.state, .registrationRequired)
        XCTAssertEqual(initial.worktreePath, fixture.repositoryURL.path)
        XCTAssertEqual(initial.title, "")

        let registered = try fixture.service.register(
            provider: .codex,
            sessionID: sessionID,
            candidateURL: fixture.nestedURL,
            title: "  Review AgentGit changes  ",
            summary: "  Link this session before editing the worktree.  ",
            now: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual(registered.state, .registered)
        XCTAssertEqual(registered.title, "Review AgentGit changes")
        XCTAssertEqual(
            try fixture.associations.list().first?.updatedAt,
            Date(timeIntervalSince1970: 20)
        )
        XCTAssertEqual(try fixture.audit.list().first?.action, .register)
        XCTAssertEqual(try fixture.audit.list().first?.outcome, .succeeded)

        let refreshed = try fixture.service.status(
            provider: .codex,
            sessionID: sessionID,
            candidateURL: fixture.repositoryURL,
            now: Date(timeIntervalSince1970: 30)
        )

        XCTAssertEqual(refreshed.state, .registered)
        XCTAssertEqual(refreshed.title, "Review AgentGit changes")
        XCTAssertEqual(
            try fixture.associations.list().first?.updatedAt,
            Date(timeIntervalSince1970: 30)
        )
    }

    func testRegisteringSameSessionKeepsBothWorktrees() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.containerURL) }
        let secondRepositoryURL = fixture.containerURL.appendingPathComponent(
            "second",
            isDirectory: true
        )
        try initializeRepository(at: secondRepositoryURL)
        let sessionID = "22222222-2222-4222-8222-222222222222"

        _ = try fixture.service.register(
            provider: .claude,
            sessionID: sessionID,
            candidateURL: fixture.repositoryURL,
            title: "First worktree",
            summary: "",
            now: Date(timeIntervalSince1970: 10)
        )
        _ = try fixture.service.register(
            provider: .claude,
            sessionID: sessionID,
            candidateURL: secondRepositoryURL,
            title: "Second worktree",
            summary: "Register a second worktree for the same session.",
            now: Date(timeIntervalSince1970: 20)
        )

        // 同一会话在第二个 worktree 上注册，第一个 worktree 的关联要留下。
        let associations = try fixture.associations.list()
        XCTAssertEqual(associations.count, 2)
        XCTAssertEqual(
            associations.first { $0.worktreePath == secondRepositoryURL.path }?.title,
            "Second worktree"
        )
        XCTAssertEqual(
            associations.first { $0.worktreePath == fixture.repositoryURL.path }?.title,
            "First worktree"
        )

        // 回到第一个 worktree 时 status 认得出它已注册，不会要求重新登记。
        let firstWorktreeStatus = try fixture.service.status(
            provider: .claude,
            sessionID: sessionID,
            candidateURL: fixture.repositoryURL,
            now: Date(timeIntervalSince1970: 30)
        )
        XCTAssertEqual(firstWorktreeStatus.state, .registered)
        XCTAssertEqual(firstWorktreeStatus.title, "First worktree")
    }

    func testSkillRegistrationRejectsInvalidIdentityRepositoryAndMetadata() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.containerURL) }
        let outsideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agentgit-outside-repository-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: outsideURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outsideURL) }

        XCTAssertThrowsError(
            try fixture.service.status(
                provider: .codex,
                sessionID: "",
                candidateURL: fixture.repositoryURL
            )
        ) { error in
            XCTAssertEqual(
                error as? AgentSkillRegistrationError,
                .invalidSessionID
            )
        }
        XCTAssertThrowsError(
            try fixture.service.status(
                provider: .codex,
                sessionID: "session",
                candidateURL: outsideURL
            )
        ) { error in
            XCTAssertEqual(
                error as? AgentSkillRegistrationError,
                .repositoryMissing
            )
        }
        XCTAssertThrowsError(
            try fixture.service.register(
                provider: .codex,
                sessionID: "session",
                candidateURL: fixture.repositoryURL,
                title: "   ",
                summary: ""
            )
        ) { error in
            XCTAssertEqual(error as? AgentSkillRegistrationError, .emptyTitle)
        }
        XCTAssertThrowsError(
            try fixture.service.register(
                provider: .codex,
                sessionID: "session",
                candidateURL: fixture.repositoryURL,
                title: String(repeating: "x", count: 81),
                summary: ""
            )
        ) { error in
            XCTAssertEqual(error as? AgentSkillRegistrationError, .titleTooLong)
        }
        XCTAssertThrowsError(
            try fixture.service.register(
                provider: .codex,
                sessionID: "session",
                candidateURL: fixture.repositoryURL,
                title: "Valid title",
                summary: String(repeating: "x", count: 201)
            )
        ) { error in
            XCTAssertEqual(error as? AgentSkillRegistrationError, .summaryTooLong)
        }
    }

    private func makeFixture() throws -> SkillRegistrationFixture {
        let containerURL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/skill-registration-\(UUID().uuidString)",
            isDirectory: true
        )
        let repositoryURL = containerURL.appendingPathComponent(
            "repository",
            isDirectory: true
        )
        try initializeRepository(at: repositoryURL)
        let nestedURL = repositoryURL.appendingPathComponent(
            "Sources/Feature",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: nestedURL,
            withIntermediateDirectories: true
        )
        let associations = AgentAssociationStore(
            storeURL: containerURL.appendingPathComponent("associations.json")
        )
        let audit = AgentRegistrationAuditStore(
            storeURL: containerURL.appendingPathComponent(
                "registration-events.json"
            )
        )
        return SkillRegistrationFixture(
            containerURL: containerURL,
            repositoryURL: repositoryURL,
            nestedURL: nestedURL,
            associations: associations,
            audit: audit,
            service: AgentSkillRegistrationService(
                associationStore: associations,
                auditStore: audit
            )
        )
    }

    private func initializeRepository(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", url.path, "init", "-b", "main"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

private struct SkillRegistrationFixture {
    let containerURL: URL
    let repositoryURL: URL
    let nestedURL: URL
    let associations: AgentAssociationStore
    let audit: AgentRegistrationAuditStore
    let service: AgentSkillRegistrationService
}
