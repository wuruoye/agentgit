import AgentGitIntegrationShared
import Foundation
import XCTest
@testable import AgentGitApp

final class AgentSessionNavigationResolverTests: XCTestCase {
    func testRefreshRetainsExistingNavigationUntilReplacementIsReady() throws {
        let retained = AgentAssociation(
            provider: .codex,
            sessionID: "01a03c04-ee8f-7c00-9731-978fcf7a8768",
            worktreePath: "/worktrees/retained",
            title: "Retained",
            updatedAt: Date()
        )
        let removed = AgentAssociation(
            provider: .claude,
            sessionID: "0fe6c4d3-e676-4425-add9-02cb861b2476",
            worktreePath: "/worktrees/removed",
            title: "Removed",
            updatedAt: Date()
        )
        let retainedResolution = AgentSessionNavigationResolution.available(
            try XCTUnwrap(
                URL(string: "codex://threads/01a03c04-ee8f-7c00-9731-978fcf7a8768")
            )
        )
        let removedResolution = AgentSessionNavigationResolution.unavailable(
            "Removed session"
        )

        let result = retainedAgentNavigationResolutions(
            current: [
                retained.id: retainedResolution,
                removed.id: removedResolution
            ],
            associations: [retained]
        )

        XCTAssertEqual(result, [retained.id: retainedResolution])
    }

    func testNavigationResolutionSkipsDuplicateRefreshButRevalidatesOnDemand() {
        let associationID = "codex:01a03c04-ee8f-7c00-9731-978fcf7a8768"
        let IDs: Set<AgentAssociation.ID> = [associationID]

        XCTAssertFalse(
            shouldRefreshAgentNavigationResolutions(
                currentIDs: IDs,
                associationIDs: IDs,
                inFlightIDs: nil,
                force: false
            )
        )
        XCTAssertFalse(
            shouldRefreshAgentNavigationResolutions(
                currentIDs: [],
                associationIDs: IDs,
                inFlightIDs: IDs,
                force: false
            )
        )
        XCTAssertTrue(
            shouldRefreshAgentNavigationResolutions(
                currentIDs: [],
                associationIDs: IDs,
                inFlightIDs: nil,
                force: false
            )
        )
        XCTAssertTrue(
            shouldRefreshAgentNavigationResolutions(
                currentIDs: IDs,
                associationIDs: IDs,
                inFlightIDs: nil,
                force: true
            )
        )
    }

    func testCodexNavigationUsesCanonicalThreadUUID() throws {
        let association = AgentAssociation(
            provider: .codex,
            sessionID: "01A03C04-EE8F-7C00-9731-978FCF7A8768",
            worktreePath: "/worktrees/sample",
            title: "Codex task",
            updatedAt: Date()
        )

        let resolution = try XCTUnwrap(
            AgentSessionNavigationResolver().resolve([association])[association.id]
        )

        XCTAssertEqual(
            resolution.target?.url.absoluteString,
            "codex://threads/01a03c04-ee8f-7c00-9731-978fcf7a8768"
        )
        XCTAssertEqual(resolution.availability, .available)
    }

    func testClaudeNavigationUsesExactDesktopMappingAndPreferenceOrder() throws {
        let root = try makeClaudeSessionsRoot()
        let sessionID = "0fe6c4d3-e676-4425-add9-02cb861b2476"
        try writeClaudeRecord(
            to: root.appendingPathComponent("default.json"),
            sessionID: "local_\(sessionID)",
            cliSessionID: sessionID,
            title: "Fallback",
            isArchived: false,
            completedTurns: 30,
            lastActivityAt: 300,
            createdAt: 100
        )
        try writeClaudeRecord(
            to: root.appendingPathComponent("preferred.json"),
            sessionID: "local_8af789b1-7171-4437-84d1-40da91d30273",
            cliSessionID: sessionID,
            title: "AgentGit",
            isArchived: false,
            completedTurns: 2,
            lastActivityAt: 200,
            createdAt: 200
        )
        try writeClaudeRecord(
            to: root.appendingPathComponent("archived.json"),
            sessionID: "local_archived",
            cliSessionID: sessionID,
            title: "Archived",
            isArchived: true,
            completedTurns: 500,
            lastActivityAt: 500,
            createdAt: 50
        )
        let association = AgentAssociation(
            provider: .claude,
            sessionID: sessionID,
            worktreePath: "/worktrees/sample",
            title: "Claude task",
            updatedAt: Date()
        )

        let resolution = try XCTUnwrap(
            AgentSessionNavigationResolver(claudeSessionsRoot: root)
                .resolve([association])[association.id]
        )

        XCTAssertEqual(
            resolution.target?.url.absoluteString,
            "claude://claude.ai/claude-code-desktop/local_8af789b1-7171-4437-84d1-40da91d30273"
        )
        XCTAssertEqual(resolution.availability, .available)
    }

    func testClaudeNavigationReportsMissingDesktopMapping() throws {
        let root = try makeClaudeSessionsRoot()
        let association = AgentAssociation(
            provider: .claude,
            sessionID: "0fe6c4d3-e676-4425-add9-02cb861b2476",
            worktreePath: "/worktrees/sample",
            title: "Claude task",
            updatedAt: Date()
        )

        let resolution = try XCTUnwrap(
            AgentSessionNavigationResolver(claudeSessionsRoot: root)
                .resolve([association])[association.id]
        )

        XCTAssertNil(resolution.target)
        guard case let .unavailable(reason) = resolution.availability else {
            return XCTFail("Expected unavailable navigation")
        }
        XCTAssertTrue(reason.contains("exact mapping"))
    }

    func testCancelledResolutionStopsBeforeScanningSessionIndex() async throws {
        let root = try makeClaudeSessionsRoot()
        let association = AgentAssociation(
            provider: .claude,
            sessionID: "0fe6c4d3-e676-4425-add9-02cb861b2476",
            worktreePath: "/worktrees/sample",
            title: "Claude task",
            updatedAt: Date()
        )
        let resolver = AgentSessionNavigationResolver(claudeSessionsRoot: root)
        let task = Task.detached {
            while !Task.isCancelled {
                await Task.yield()
            }
            return resolver.resolve([association])
        }

        task.cancel()

        let resolutions = await task.value
        XCTAssertTrue(resolutions.isEmpty)
    }

    private func makeClaudeSessionsRoot() throws -> URL {
        let root = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/claude-navigation-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
        return root
    }

    private func writeClaudeRecord(
        to url: URL,
        sessionID: String,
        cliSessionID: String,
        title: String,
        isArchived: Bool,
        completedTurns: Int64,
        lastActivityAt: Int64,
        createdAt: Int64
    ) throws {
        let object: [String: Any] = [
            "sessionId": sessionID,
            "cliSessionId": cliSessionID,
            "title": title,
            "isArchived": isArchived,
            "completedTurns": completedTurns,
            "lastActivityAt": lastActivityAt,
            "createdAt": createdAt
        ]
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ).write(to: url, options: .atomic)
    }
}
