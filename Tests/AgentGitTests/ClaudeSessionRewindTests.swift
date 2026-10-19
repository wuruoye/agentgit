@testable import AgentGitApp
import AgentGitIntegrationShared
import Foundation
import Testing

private let oldID = "4f772728-a12e-4950-a0a4-635060b9a167"
private let newID = "bf3731a9-314b-4026-a112-1b4c37020ce5"
private let otherID = "0f1e2d3c-4b5a-4968-8776-655443322110"

/// 临时的 Claude Desktop 会话索引：`<root>/<org>/<account>/<sessionId>.json`。
private struct ClaudeSessionIndex {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "AgentGitTests.ClaudeSessions.\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appending(path: "org/account"),
            withIntermediateDirectories: true
        )
    }

    func write(_ sessionID: String, _ fields: [String: Any]) throws {
        var record = fields
        record["sessionId"] = sessionID
        try JSONSerialization.data(withJSONObject: record)
            .write(to: root.appending(path: "org/account/\(sessionID).json"))
    }

    func resolve(_ association: AgentAssociation) -> AgentSessionNavigationResolution? {
        AgentSessionNavigationResolver(
            claudeSessionsRoot: root,
            codexHome: root.appending(path: "codex")
        ).resolve([association])[association.id]
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func claudeAssociation(_ sessionID: String, host: String? = nil) -> AgentAssociation {
    AgentAssociation(
        provider: .claude,
        sessionID: sessionID,
        worktreePath: "/tmp/agentgit-tests/ting_duo",
        title: "",
        updatedAt: Date(timeIntervalSince1970: 0),
        hostSessionID: host
    )
}

private func target(_ localID: String) -> URL? {
    URL(string: "claude://claude.ai/claude-code-desktop/\(localID)")
}

@Test func rewoundClaudeSessionResolvesByHostSessionID() throws {
    let index = try ClaudeSessionIndex()
    defer { index.remove() }
    try index.write("local_duo", [
        "cliSessionId": newID,
        "priorCliSessionIds": [oldID],
        "title": "iPhone Duo"
    ])
    // 记录里只剩 Desktop 会话 ID 对得上（例如回退过不止一次、旧 ID 也被清掉），照样能打开。
    try index.write("local_other", ["cliSessionId": otherID])
    let resolution = try #require(index.resolve(
        claudeAssociation("0a0a0a0a-0000-4000-8000-000000000000", host: "local_duo")
    ))
    #expect(resolution.target?.url == target("local_duo"))
    #expect(resolution.title == "iPhone Duo")
}

@Test func rewoundClaudeSessionResolvesByPriorCLISessionID() throws {
    let index = try ClaudeSessionIndex()
    defer { index.remove() }
    try index.write("local_duo", [
        "cliSessionId": newID,
        "priorCliSessionIds": [oldID.uppercased()]
    ])
    let resolution = try #require(index.resolve(claudeAssociation(oldID)))
    #expect(resolution.target?.url == target("local_duo"))
}

@Test func clearedAndUnarchivedClaudeSessionIDsStillResolve() throws {
    let index = try ClaudeSessionIndex()
    defer { index.remove() }
    try index.write("local_cleared", ["cliSessionId": newID, "preClearCliSessionId": oldID])
    try index.write("local_unarchived", ["cliSessionId": newID, "unarchivedCliSessionId": otherID])
    #expect(index.resolve(claudeAssociation(oldID))?.target?.url == target("local_cleared"))
    #expect(index.resolve(claudeAssociation(otherID))?.target?.url == target("local_unarchived"))
}

@Test func currentCLISessionIDWinsOverHistoricalClaim() throws {
    let index = try ClaudeSessionIndex()
    defer { index.remove() }
    try index.write("local_current", ["cliSessionId": oldID, "completedTurns": 1])
    // 旧 ID 只出现在历史里的会话即使更活跃，也排在当前 ID 命中的会话后面。
    try index.write("local_historical", [
        "cliSessionId": newID,
        "priorCliSessionIds": [oldID],
        "completedTurns": 500,
        "lastActivityAt": 1_792_413_300_759
    ])
    #expect(index.resolve(claudeAssociation(oldID))?.target?.url == target("local_current"))
}

@Test func archivedHostSessionFallsBackToCLISessionID() throws {
    let index = try ClaudeSessionIndex()
    defer { index.remove() }
    try index.write("local_archived", ["cliSessionId": otherID, "isArchived": true])
    try index.write("local_live", ["cliSessionId": newID, "priorCliSessionIds": [oldID]])
    let resolution = index.resolve(claudeAssociation(oldID, host: "local_archived"))
    #expect(resolution?.target?.url == target("local_live"))
}

@Test func unclaimedClaudeSessionStaysUnavailable() throws {
    let index = try ClaudeSessionIndex()
    defer { index.remove() }
    try index.write("local_other", ["cliSessionId": otherID, "priorCliSessionIds": [newID]])
    let resolution = try #require(index.resolve(claudeAssociation(oldID, host: "local_missing")))
    #expect(resolution.target == nil)
    #expect(resolution.errorDescription == "Claude Desktop no longer has an exact mapping for this session.")
}

@Test func malformedHistoricalIDsDoNotHideTheSession() throws {
    let index = try ClaudeSessionIndex()
    defer { index.remove() }
    try index.write("local_duo", ["cliSessionId": newID, "priorCliSessionIds": 7, "preClearCliSessionId": 3])
    #expect(index.resolve(claudeAssociation(newID))?.target?.url == target("local_duo"))
}

@Test func legacyAssociationFileDecodesWithoutHostSessionID() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "AgentGitTests.Associations.\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let storeURL = directory.appending(path: "associations.json")
    try Data("""
    [{"provider":"claude","sessionID":"\(oldID)","title":"Duo",\
    "updatedAt":"2026-09-09T09:09:32.690Z","worktreePath":"/tmp/agentgit-tests/ting_duo"}]
    """.utf8).write(to: storeURL)

    let store = AgentAssociationStore(storeURL: storeURL)
    let legacy = try #require(try store.list().first)
    #expect(legacy.sessionID == oldID)
    #expect(legacy.hostSessionID == nil)

    // 再次登记同一会话时没带 Desktop 会话 ID，已经记下的不会被清掉。
    _ = try store.upsert(claudeAssociation(oldID, host: "local_duo"))
    _ = try store.upsert(claudeAssociation(oldID))
    #expect(try store.list().first?.hostSessionID == "local_duo")
}

@Test func associationsPointingToTheSameSessionAreMerged() throws {
    let creator = claudeAssociation(oldID, host: "local_duo")
    let rewound = claudeAssociation(newID)
    let unresolvedTwin = AgentAssociation(
        provider: .claude,
        sessionID: otherID,
        worktreePath: "/tmp/agentgit-tests/ting_duo",
        title: "",
        updatedAt: Date(timeIntervalSince1970: 0),
        hostSessionID: "local_duo"
    )
    let unrelated = claudeAssociation("11111111-2222-4333-8444-555555555555")
    let duo = try #require(target("local_duo"))

    #expect(
        uniqueAgentSessions(
            [creator, rewound, unrelated],
            targetURLs: [creator.id: duo, rewound.id: duo]
        ).map(\.id) == [creator.id, unrelated.id]
    )
    // 还没解析出跳转目标时按 Desktop 会话 ID 合并；两者都没有的照常保留。
    #expect(
        uniqueAgentSessions([creator, unresolvedTwin, unrelated], targetURLs: [:]).map(\.id)
            == [creator.id, unrelated.id]
    )
    #expect(uniqueAgentSessions([rewound, unrelated], targetURLs: [:]).count == 2)
}
