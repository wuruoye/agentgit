@testable import AgentGitApp
@testable import AgentGitCore
import AgentGitIntegrationShared
import Foundation
import SQLite3
import Testing

private let agyRootID = "1a447d9f-f295-420c-8f56-c0a0292d0508"
private let agySubagentID = "c3be0417-7b78-49bf-9e17-6688276ad80d"
private let agyMissingID = "99999999-8888-4777-8666-555555555555"

private struct AntigravityTestIndex {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "AgentGitTests.Antigravity.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func createDatabase() throws {
        let dbURL = root.appending(path: "conversation_summaries.db")
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(db) }
        let schema = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE conversation_summaries (
            conversation_id TEXT PRIMARY KEY,
            title TEXT NOT NULL DEFAULT "",
            last_modified_time datetime NOT NULL,
            last_user_input_time datetime NOT NULL,
            workspace_uris TEXT NOT NULL,
            project_id TEXT NOT NULL DEFAULT "",
            parent_conversation_id TEXT NOT NULL DEFAULT "",
            nesting_depth INTEGER NOT NULL DEFAULT 0,
            killed numeric NOT NULL DEFAULT 0
        );
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func insertSummary(
        id: String,
        title: String,
        workspacePaths: [String] = [],
        parentID: String = "",
        nestingDepth: Int = 0,
        timestamp: String = "2026-11-05 11:30:43.332367+00:00"
    ) throws {
        let dbURL = root.appending(path: "conversation_summaries.db")
        if !FileManager.default.fileExists(atPath: dbURL.path) {
            try createDatabase()
        }
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, """
            INSERT OR REPLACE INTO conversation_summaries (
                conversation_id, title, last_modified_time, last_user_input_time,
                workspace_uris, parent_conversation_id, nesting_depth
            ) VALUES (?1, ?2, ?3, ?3, ?4, ?5, ?6)
            """, -1, &stmt, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        let uris = workspacePaths.map { URL(fileURLWithPath: $0).absoluteString }
        let urisJSON = String(decoding: try JSONEncoder().encode(uris), as: UTF8.self)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, id, -1, transient)
        sqlite3_bind_text(stmt, 2, title, -1, transient)
        sqlite3_bind_text(stmt, 3, timestamp, -1, transient)
        sqlite3_bind_text(stmt, 4, urisJSON, -1, transient)
        sqlite3_bind_text(stmt, 5, parentID, -1, transient)
        sqlite3_bind_int(stmt, 6, Int32(nestingDepth))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    @discardableResult
    func createBrainDirectory(_ id: String, transcriptLines: [String] = []) throws -> URL {
        let dir = root.appending(path: "brain/\(id)")
        let logs = dir.appending(path: ".system_generated/logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        if !transcriptLines.isEmpty {
            let content = transcriptLines.joined(separator: "\n") + "\n"
            try Data(content.utf8).write(to: logs.appending(path: "transcript.jsonl"))
        }
        return dir
    }

    var resolver: AgentSessionNavigationResolver {
        AgentSessionNavigationResolver(
            claudeSessionsRoot: root.appending(path: "claude"),
            codexHome: root.appending(path: "codex"),
            antigravityAppDataRoot: root
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func antigravityAssociation(_ sessionID: String, path: String = "/tmp/agentgit-agy/wt") -> AgentAssociation {
    AgentAssociation(
        provider: .antigravity,
        sessionID: sessionID,
        worktreePath: path,
        title: "",
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

private func runGit(_ arguments: [String], in cwd: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    process.environment = [
        "HOME": cwd.path,
        "PATH": "/usr/bin:/bin",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "Test",
        "GIT_AUTHOR_EMAIL": "test@example.com",
        "GIT_COMMITTER_NAME": "Test",
        "GIT_COMMITTER_EMAIL": "test@example.com"
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

@Test func antigravityProviderDecodesCanonicalAndAgyAlias() throws {
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    #expect(try decoder.decode(AgentProvider.self, from: Data(#""antigravity""#.utf8)) == .antigravity)
    #expect(try decoder.decode(AgentProvider.self, from: Data(#""agy""#.utf8)) == .antigravity)
    #expect(try decoder.decode(AgentProvider.self, from: Data(#""AGY""#.utf8)) == .antigravity)
    let encoded = try String(decoding: encoder.encode(AgentProvider.antigravity), as: UTF8.self)
    #expect(encoded == #""antigravity""#)
    #expect(AgentProvider.antigravity.displayName == "Antigravity")
    #expect(AgentProvider.antigravity.systemImageName == "atom")
}

@Test func antigravitySessionResolvesTitleAndCoalescesSubagentToRoot() throws {
    let index = try AntigravityTestIndex()
    defer { index.remove() }
    try index.insertSummary(id: agyRootID, title: "  AgentGit 适配 Antigravity  ")
    try index.insertSummary(
        id: agySubagentID,
        title: "Subagent task",
        parentID: agyRootID,
        nestingDepth: 1
    )

    let rootAssoc = antigravityAssociation(agyRootID)
    let subAssoc = antigravityAssociation(agySubagentID.uppercased())
    let resolutions = index.resolver.resolve([rootAssoc, subAssoc])

    let expectedURL = try #require(URL(string: "antigravity://conversation/\(agyRootID)"))
    #expect(resolutions[rootAssoc.id] == .available(expectedURL, title: "AgentGit 适配 Antigravity"))
    #expect(resolutions[subAssoc.id] == .available(expectedURL, title: "AgentGit 适配 Antigravity"))

    let merged = uniqueAgentSessions(
        [rootAssoc, subAssoc],
        targetURLs: resolutions.compactMapValues(\.target?.url)
    )
    #expect(merged.map(\.id) == [rootAssoc.id])
}

@Test func antigravityBrainOnlyAndMissingConversationsResolveAccurately() throws {
    let index = try AntigravityTestIndex()
    defer { index.remove() }

    // 数据目录尚未生成任何会话文件时提示打开 Antigravity。
    let beforeData = try #require(index.resolver.resolve([antigravityAssociation(agyRootID)]).values.first)
    #expect(beforeData.target == nil)
    #expect(beforeData.errorDescription == "Antigravity session data is unavailable. Open Antigravity and try again.")

    // 只有 brain/<uuid> 目录的新会话也能正常打开。
    try index.createBrainDirectory(agyRootID)
    let fromBrain = try #require(index.resolver.resolve([antigravityAssociation(agyRootID)]).values.first)
    #expect(fromBrain.target?.url == URL(string: "antigravity://conversation/\(agyRootID)"))

    // 已删除的会话标记为不可用。
    let deleted = try #require(index.resolver.resolve([antigravityAssociation(agyMissingID)]).values.first)
    #expect(deleted.target == nil)
    #expect(deleted.errorDescription == "Antigravity no longer has this conversation.")
}

@Test func discoverCreatorsFindsAntigravityWorkspaceAndSandboxedWorktreeAdd() throws {
    let index = try AntigravityTestIndex()
    defer { index.remove() }

    let repoParent = index.root.appending(path: "repos")
    let mainRepo = repoParent.appending(path: "main")
    let branchWT = repoParent.appending(path: "branch-wt")
    let sandboxWT = repoParent.appending(path: "sandbox-wt")
    let prefixTrapWT = repoParent.appending(path: "sandbox-wt-extra")
    try FileManager.default.createDirectory(at: mainRepo, withIntermediateDirectories: true)

    try runGit(["init"], in: mainRepo)
    try Data("hello\n".utf8).write(to: mainRepo.appending(path: "README.md"))
    try runGit(["add", "README.md"], in: mainRepo)
    try runGit(["commit", "-m", "init"], in: mainRepo)
    try runGit(["worktree", "add", "-b", "feat/branch", branchWT.path], in: mainRepo)
    try runGit(["worktree", "add", "-b", "feat/sandbox", sandboxWT.path], in: mainRepo)
    try runGit(["worktree", "add", "-b", "feat/extra", prefixTrapWT.path], in: mainRepo)

    // 1. 子代理的分支工作区记在 workspace_uris 中，归并到根会话。
    try index.createBrainDirectory(agyRootID)
    try index.createBrainDirectory(agySubagentID)
    try index.insertSummary(id: agyRootID, title: "主任务会话", workspacePaths: [mainRepo.path])
    try index.insertSummary(
        id: agySubagentID,
        title: "分支子任务",
        workspacePaths: [branchWT.path],
        parentID: agyRootID,
        nestingDepth: 1
    )

    // 2. 沙盒内执行 `git worktree add` 记在 transcript.jsonl 中，且不会误匹配同前缀目录。
    let sandboxSessionID = "0bf96993-a25a-4ed1-91d3-8d1bb4c17be0"
    try index.insertSummary(id: sandboxSessionID, title: "沙盒建分支", workspacePaths: [mainRepo.path])
    let escapedPath = sandboxWT.standardizedFileURL.path
    try index.createBrainDirectory(sandboxSessionID, transcriptLines: [
        #"{"type":"PLANNER_RESPONSE","tool_calls":[{"name":"run_command","args":{"CommandLine":"git worktree add -b feat/sandbox \"\#(escapedPath)\""}}]}"#
    ])

    let paths: Set<String> = [
        branchWT.standardizedFileURL.path,
        sandboxWT.standardizedFileURL.path,
        prefixTrapWT.standardizedFileURL.path
    ]
    let discovered = index.resolver.discoverCreators(worktreePaths: paths)

    let branchCreator = try #require(discovered[branchWT.standardizedFileURL.path])
    #expect(branchCreator.provider == .antigravity)
    #expect(branchCreator.sessionID == agyRootID)
    #expect(branchCreator.title == "主任务会话")
    #expect(branchCreator.source == "antigravity")

    let sandboxCreator = try #require(discovered[sandboxWT.standardizedFileURL.path])
    #expect(sandboxCreator.provider == .antigravity)
    #expect(sandboxCreator.sessionID == sandboxSessionID)
    #expect(sandboxCreator.title == "沙盒建分支")

    #expect(discovered[prefixTrapWT.standardizedFileURL.path] == nil)
}

@Test func worktreeCreatorHookRecordsAntigravityRootSession() throws {
    let index = try AntigravityTestIndex()
    defer { index.remove() }

    try index.insertSummary(id: agyRootID, title: "Hook 根会话\n第二行")
    try index.insertSummary(
        id: agySubagentID,
        title: "Hook 子代理",
        parentID: agyRootID,
        nestingDepth: 1
    )

    let fakeHome = index.root.appending(path: "home with spaces")
    let repo = index.root.appending(path: "repo")
    let wt = index.root.appending(path: "wt")
    try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

    try runGit(["init"], in: repo)
    try Data("a\n".utf8).write(to: repo.appending(path: "a.txt"))
    try runGit(["add", "a.txt"], in: repo)
    try runGit(["commit", "-m", "init"], in: repo)
    try runGit(["worktree", "add", "-b", "agy-test", wt.path], in: repo)

    let hookURL = index.root.appending(path: "post-checkout")
    try Data(WorktreeCreatorHook.script.utf8).write(to: hookURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [hookURL.path, String(repeating: "0", count: 40), String(repeating: "1", count: 40), "1"]
    process.currentDirectoryURL = wt
    process.environment = [
        "HOME": fakeHome.path,
        "PATH": "/usr/bin:/bin",
        "ANTIGRAVITY_CONVERSATION_ID": agySubagentID,
        "ANTIGRAVITY_APP_DATA_DIR": index.root.path,
        // 外层 Claude Desktop 继承变量不应抢占内层 Antigravity 会话。
        "CLAUDE_CODE_HOST_SESSION_ID": "local_outer"
    ]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    let storeURL = fakeHome.appending(path: "Library/Application Support/AgentGit/worktree-creators")
    let creators = AgentWorktreeCreatorStore(directoryURL: storeURL).load()
    let creator = try #require(creators[wt.standardizedFileURL.path])
    #expect(creator.provider == .antigravity)
    #expect(creator.sessionID == agyRootID)
    #expect(creator.title == "Hook 根会话 第二行")
    #expect(creator.source == "git-hook")
}

@Test func antigravityContextHandoffAndURLMatching() throws {
    let deepLink = try #require(URL(string: "antigravity://conversation/\(agyRootID)"))
    let handoff = AgentSessionContextHandoff(
        provider: .antigravity,
        sessionURL: deepLink,
        context: "\n文件：Sources/Main.swift\n行号：new 1-3"
    )
    #expect(handoff.copiesContextToPasteboard)
    #expect(handoff.url == deepLink)
    #expect(AntigravityComposerHandoff.sessionID(from: deepLink) == agyRootID)

    let single = try #require(URL(string: "https://127.0.0.1:53603/c/\(agyRootID)?project=abc"))
    let splitFocused = try #require(URL(string: "https://127.0.0.1:53603/c/\(agySubagentID)+\(agyRootID)?focused=\(agyRootID)"))
    let splitOther = try #require(URL(string: "https://127.0.0.1:53603/c/\(agySubagentID)+\(agyRootID)?focused=\(agySubagentID)"))
    let home = try #require(URL(string: "https://127.0.0.1:53603/"))
    let sidebarLink = try #require(URL(string: "https://127.0.0.1:53603/c/\(agyRootID)"))

    #expect(AntigravityComposerHandoff.matchesSession(single, sessionID: agyRootID))
    #expect(AntigravityComposerHandoff.matchesSession(splitFocused, sessionID: agyRootID))
    #expect(!AntigravityComposerHandoff.matchesSession(splitOther, sessionID: agyRootID))
    #expect(!AntigravityComposerHandoff.matchesSession(home, sessionID: agyRootID))
    #expect(AntigravityComposerHandoff.matchesConversationLink(sidebarLink, sessionID: agyRootID))
}

@Test func gitCommandRunnerStripsInheritedAgentEnvironmentVariables() {
    let env = GitCommandRunner.baseEnvironment
    #expect(env["CLAUDE_CODE_SESSION_ID"] == nil)
    #expect(env["CLAUDE_CODE_HOST_SESSION_ID"] == nil)
    #expect(env["CODEX_THREAD_ID"] == nil)
    #expect(env["ANTIGRAVITY_CONVERSATION_ID"] == nil)
    #expect(env["ANTIGRAVITY_PROJECT_ID"] == nil)
    #expect(env["ANTIGRAVITY_TRAJECTORY_ID"] == nil)
    #expect(env["ANTIGRAVITY_AGENT"] == nil)
}
