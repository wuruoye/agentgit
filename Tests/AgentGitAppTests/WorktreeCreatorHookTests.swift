import AgentGitCore
import AgentGitIntegrationShared
import Foundation
import notify
import XCTest
@testable import AgentGitApp

final class WorktreeCreatorHookTests: XCTestCase {
    func testInstallationRejectsGitWithoutConfiguredHooks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("git")
        try Data("#!/bin/sh\nprintf '%s\\n' 'core.hooksPath'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        do {
            try await WorktreeCreatorHook.install(using: GitCommandRunner(executableURL: executable))
            XCTFail("Expected unsupported Git to be rejected before installation")
        } catch WorktreeCreatorHook.InstallationError.unsupportedGit {
        }
    }

    /// 真实 `git worktree add` 触发安装的脚本，把创建者写进 AgentGit 的记录目录并发通知；
    /// 没有 agent 会话变量的新 worktree 和普通分支切换都不记录。
    func testWorktreeAddRecordsCreatingSession() async throws {
        let supportsConfiguredHooks = try await WorktreeCreatorHook.supportsConfiguredHooks()
        try XCTSkipUnless(supportsConfiguredHooks, "Requires configuration-based hooks")
        let fixture = try await Fixture.make()
        defer { fixture.dispose() }
        let home = fixture.container.appendingPathComponent("home", isDirectory: true)
        let claudeIndex = home.appendingPathComponent(
            "Library/Application Support/Claude/claude-code-sessions/acct/org/local_desktop.json"
        )
        let codexIndex = home.appendingPathComponent(".codex/session_index.jsonl")
        let scriptURL = fixture.container.appendingPathComponent("hook dir/post-checkout")
        for url in [claudeIndex, codexIndex, scriptURL] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        // 真实索引里出现过转义的空字符，plutil 会因此整体解析失败。
        try Data(#"{"sessionId":"local_desktop","cliSessionId":"22222222-2222-4222-8222-222222222222","title":"Fix \"login\" flow","draft":"a\u0000b"}"#.utf8).write(to: claudeIndex)
        try Data("""
        {"id":"019e8257-a9eb-7603-bdf3-c8fcebedbfb6","thread_name":"old name","updated_at":"2026-06-01T08:50:11Z"}
        {"id":"019e8257-a9eb-7603-bdf3-c8fcebedbfb6","thread_name":"重构缓存","updated_at":"2026-06-02T08:50:11Z"}

        """.utf8).write(to: codexIndex)
        try Data(WorktreeCreatorHook.script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        var notificationToken = NOTIFY_TOKEN_INVALID
        XCTAssertEqual(
            notify_register_check(AgentWorktreeCreatorStore.changedNotificationName, &notificationToken),
            UInt32(NOTIFY_STATUS_OK)
        )
        defer { notify_cancel(notificationToken) }
        var changed: Int32 = 0
        notify_check(notificationToken, &changed)

        func git(_ arguments: [String], session: [String: String] = [:]) async throws {
            let environment = [
                "HOME": home.path,
                "CLAUDE_CODE_SESSION_ID": "",
                "CLAUDE_CODE_HOST_SESSION_ID": "",
                "CODEX_THREAD_ID": ""
            ].merging(session) { $1 }
            try await fixture.git(
                [
                    "-c", "hook.agentgit.event=post-checkout",
                    "-c", "hook.agentgit.command=\(WorktreeCreatorHook.command(for: scriptURL))"
                ] + arguments,
                environment: environment
            )
        }
        try await git(["checkout", "-q", "-b", "other"], session: ["CODEX_THREAD_ID": "ignored"])
        try await git(
            ["worktree", "add", "-q", "-b", "claude", fixture.path("claude")],
            session: [
                "CLAUDE_CODE_SESSION_ID": "22222222-2222-4222-8222-222222222222",
                "CLAUDE_CODE_HOST_SESSION_ID": "local_desktop"
            ]
        )
        // EnterWorktree：claude 进程直接调 git，只有 Desktop 会话 ID。
        try await git(
            ["worktree", "add", "-q", "-b", "enter", fixture.path("enter")],
            session: ["CLAUDE_CODE_HOST_SESSION_ID": "local_desktop"]
        )
        // Claude 会话里启动的 Codex：继承的 Desktop 会话 ID 不能盖过 Codex 线程。
        try await git(
            ["worktree", "add", "-q", "-b", "codex", fixture.path("codex")],
            session: [
                "CODEX_THREAD_ID": "019e8257-a9eb-7603-bdf3-c8fcebedbfb6",
                "CLAUDE_CODE_HOST_SESSION_ID": "local_desktop"
            ]
        )
        try await git(["worktree", "add", "-q", "-b", "plain", fixture.path("plain")])

        notify_check(notificationToken, &changed)
        XCTAssertEqual(changed, 1)

        let store = AgentWorktreeCreatorStore(
            directoryURL: home.appendingPathComponent(
                "Library/Application Support/AgentGit/worktree-creators"
            )
        )
        let worktreePaths = try await fixture.worktreePaths()
        let creators = store.load()
        XCTAssertEqual(Set(creators.keys), [worktreePaths["claude"], worktreePaths["enter"], worktreePaths["codex"]])

        let claude = try XCTUnwrap(creators[worktreePaths["claude"]!])
        XCTAssertEqual(claude.provider, .claude)
        XCTAssertEqual(claude.sessionID, "22222222-2222-4222-8222-222222222222")
        XCTAssertEqual(claude.hostSessionID, "local_desktop")
        XCTAssertEqual(claude.title, #"Fix "login" flow"#)
        XCTAssertEqual(claude.source, "git-hook")
        XCTAssertLessThan(abs(claude.createdAt.timeIntervalSinceNow), 60)

        let enter = try XCTUnwrap(creators[worktreePaths["enter"]!])
        XCTAssertEqual(enter.sessionID, "22222222-2222-4222-8222-222222222222")
        XCTAssertEqual(enter.hostSessionID, "local_desktop")

        let codex = try XCTUnwrap(creators[worktreePaths["codex"]!])
        XCTAssertEqual(codex.provider, .codex)
        XCTAssertEqual(codex.sessionID, "019e8257-a9eb-7603-bdf3-c8fcebedbfb6")
        XCTAssertNil(codex.hostSessionID)
        XCTAssertEqual(codex.title, "重构缓存")

        // 认不出会话的新 worktree 留待查标记，交给 AgentGit 按宿主元数据补查。
        XCTAssertEqual(store.pendingWorktrees().map(\.worktreePath), [worktreePaths["plain"]])
    }

    /// hook 留下待查标记后，宿主的会话记录晚一点才写入：AgentGit 在重试期内查到并记下，删掉标记。
    @MainActor
    func testPendingWorktreeIsRetriedUntilHostMetadataAppears() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.dispose() }
        let worktree = fixture.path("repo/.claude/worktrees/late-index")
        try await fixture.git(["worktree", "add", "-q", "-b", "late-index", worktree])
        let claudeRoot = fixture.container.appendingPathComponent("claude-code-sessions", isDirectory: true)
        let store = AgentWorktreeCreatorStore(
            directoryURL: fixture.container.appendingPathComponent("store", isDirectory: true)
        )
        let pending = store.directoryURL.appendingPathComponent("pending", isDirectory: true)
        try FileManager.default.createDirectory(
            at: claudeRoot.appendingPathComponent("acct/org"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        try Data((worktree + "\n").utf8).write(to: pending.appendingPathComponent("marker"))

        let controller = AgentAssociationController(
            store: AgentAssociationStore(storeURL: fixture.container.appendingPathComponent("associations.json")),
            auditStore: AgentRegistrationAuditStore(storeURL: fixture.container.appendingPathComponent("audit.json")),
            navigationResolver: AgentSessionNavigationResolver(
                claudeSessionsRoot: claudeRoot,
                codexHome: fixture.container.appendingPathComponent("codex", isDirectory: true)
            ),
            creatorStore: store,
            creatorRetryInterval: .milliseconds(50),
            creatorRetryDuration: 10
        )
        controller.start()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(controller.worktreeCreators[worktree])

        try Data("""
        {"sessionId":"local_desktop","cliSessionId":"bd9756e7-393c-4de2-b785-fdb86703f8a6",\
        "worktreePath":"\(worktree)","createdAt":\(Int64(Date().timeIntervalSince1970 * 1000))}
        """.utf8).write(to: claudeRoot.appendingPathComponent("acct/org/local_desktop.json"))
        for _ in 0..<60 where controller.worktreeCreators[worktree] == nil || !store.pendingWorktrees().isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(controller.worktreeCreators[worktree]?.sessionID, "bd9756e7-393c-4de2-b785-fdb86703f8a6")
        XCTAssertEqual(controller.worktreeCreators[worktree]?.source, "claude-desktop")
        XCTAssertTrue(store.pendingWorktrees().isEmpty)
    }

    /// 宿主自己建的 worktree：按 Claude Desktop 的 worktreePath 和 Codex threads.cwd 找回会话，
    /// 会话创建时间要贴近 worktree 创建时间；同一路径删掉重建过或 worktree 删除后记录失效，定期清理时删掉文件。
    func testHostCreatedWorktreesAreDiscoveredFromSessionMetadata() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.dispose() }
        let claudeRoot = fixture.container.appendingPathComponent("claude-code-sessions", isDirectory: true)
        let codexHome = fixture.container.appendingPathComponent("codex", isDirectory: true)
        let claudeWorktree = fixture.path("repo/.claude/worktrees/cool-fermi")
        let codexWorktree = codexHome.appendingPathComponent("worktrees/8cff/repo").path
        let lateCodexWorktree = codexHome.appendingPathComponent("worktrees/9abc/repo").path
        let toolCodexWorktree = codexHome.appendingPathComponent("worktrees/tool/repo").path
        try FileManager.default.createDirectory(
            at: claudeRoot.appendingPathComponent("acct/org"),
            withIntermediateDirectories: true
        )
        for (branch, path) in [
            ("claude", claudeWorktree), ("codex", codexWorktree), ("late", lateCodexWorktree), ("tool", toolCodexWorktree)
        ] {
            try await fixture.git(["worktree", "add", "-q", "-b", branch, path])
        }
        let nowMilliseconds = Int64(Date().timeIntervalSince1970 * 1000)
        try Data("""
        {"sessionId":"local_desktop","cliSessionId":"BD9756E7-393C-4DE2-B785-FDB86703F8A6",\
        "worktreePath":"\(claudeWorktree)","title":"删除 preflight","createdAt":\(nowMilliseconds)}
        """.utf8).write(to: claudeRoot.appendingPathComponent("acct/org/local_desktop.json"))
        let twoHours: Int64 = 7_200_000
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [codexHome.appendingPathComponent("state_5.sqlite").path, """
            CREATE TABLE threads (id TEXT, cwd TEXT, name TEXT, created_at INTEGER, created_at_ms INTEGER);
            INSERT INTO threads VALUES ('01a0af15-db11-7b93-ad57-e8363e5cab54', '\(codexWorktree)', NULL, 0, \(nowMilliseconds));
            INSERT INTO threads VALUES ('01a0af14-925e-75f2-8dfc-f0fc23f2748c', '\(codexWorktree)', 'fork', 0, \(nowMilliseconds + 1000));
            INSERT INTO threads VALUES ('01a0ae7b-5e33-7783-bfa4-3e3c731e92e7', '\(lateCodexWorktree)', NULL, 0, \(nowMilliseconds + twoHours));
            """]
        try sqlite.run()
        sqlite.waitUntilExit()
        XCTAssertEqual(sqlite.terminationStatus, 0)

        // create_worktree 工具建的：线程 cwd 还是原仓库，只有会话日志里的返回值记着这个路径；
        // 另一个线程只是在命令里用到这个路径，不算创建者。
        let sessions = codexHome.appendingPathComponent("sessions/2026/09/29", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data((#"{"type":"custom_tool_call_output","output":[{"type":"input_text","text":"{\"type\":\"created\",\"worktreeGitRoot\":\""#
            + toolCodexWorktree + #"\"}"}]}"# + "\n").utf8)
            .write(to: sessions.appendingPathComponent("rollout-2026-09-29T21-08-47-01a0ed48-33e7-7cf3-9d9d-a634f9ec96e3.jsonl"))
        try Data((#"{"type":"function_call","arguments":"{\"workdir\":\""# + toolCodexWorktree + #"\"}"}"# + "\n").utf8)
            .write(to: sessions.appendingPathComponent("rollout-2026-09-29T20-00-00-01a0ed00-0000-7000-8000-000000000000.jsonl"))

        let found = AgentSessionNavigationResolver(claudeSessionsRoot: claudeRoot, codexHome: codexHome)
            .discoverCreators(worktreePaths: [
                fixture.repository.path, claudeWorktree, codexWorktree, lateCodexWorktree, toolCodexWorktree
            ])
        XCTAssertEqual(Set(found.keys), [claudeWorktree, codexWorktree, toolCodexWorktree])
        XCTAssertEqual(found[toolCodexWorktree]?.sessionID, "01a0ed48-33e7-7cf3-9d9d-a634f9ec96e3")
        XCTAssertEqual(found[claudeWorktree], AgentWorktreeCreator(
            worktreePath: claudeWorktree,
            provider: .claude,
            sessionID: "bd9756e7-393c-4de2-b785-fdb86703f8a6",
            hostSessionID: "local_desktop",
            title: "删除 preflight",
            createdAt: Date(timeIntervalSince1970: Double(nowMilliseconds) / 1000),
            source: "claude-desktop"
        ))
        XCTAssertEqual(found[codexWorktree]?.sessionID, "01a0af15-db11-7b93-ad57-e8363e5cab54")
        XCTAssertEqual(found[codexWorktree]?.source, "codex-app")

        let store = AgentWorktreeCreatorStore(
            directoryURL: fixture.container.appendingPathComponent("store", isDirectory: true)
        )
        for creator in found.values {
            try store.save(creator)
        }
        let loaded = store.load()
        XCTAssertEqual(Set(loaded.keys), Set(found.keys))
        for (path, creator) in found {
            let saved = try XCTUnwrap(loaded[path])
            XCTAssertEqual(
                [saved.sessionID, saved.hostSessionID, saved.title, saved.source],
                [creator.sessionID, creator.hostSessionID, creator.title, creator.source]
            )
            XCTAssertEqual(saved.createdAt.timeIntervalSince1970, creator.createdAt.timeIntervalSince1970, accuracy: 0.001)
        }

        let stale = found[claudeWorktree]!
        try store.save(AgentWorktreeCreator(
            worktreePath: stale.worktreePath,
            provider: stale.provider,
            sessionID: stale.sessionID,
            createdAt: Date(timeIntervalSinceNow: -2 * 86_400),
            source: stale.source
        ))
        XCTAssertEqual(Set(store.load().keys), [codexWorktree, toolCodexWorktree])

        try await fixture.git(["worktree", "remove", codexWorktree])
        try await fixture.git(["worktree", "remove", toolCodexWorktree])
        XCTAssertEqual(store.load(), [:])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path).count, 3)
        store.removeStale()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path), [])
    }
}

private struct Fixture {
    let container: URL
    let repository: URL
    let runner = GitCommandRunner()

    static func make() async throws -> Fixture {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("creator hook \(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let fixture = Fixture(container: container, repository: container.appendingPathComponent("main"))
        try FileManager.default.createDirectory(at: fixture.repository, withIntermediateDirectories: true)
        try await fixture.git(["init", "-q", "-b", "main"])
        try await fixture.git(["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "init"])
        return fixture
    }

    func path(_ name: String) -> String {
        container.appendingPathComponent(name).path
    }

    func git(_ arguments: [String], environment: [String: String] = [:]) async throws {
        _ = try await runner.run(arguments: arguments, workingDirectory: repository, environment: environment)
    }

    /// 按目录名索引 `git worktree list` 给出的路径。
    func worktreePaths() async throws -> [String: String] {
        let worktrees = try await GitRepositoryService(runner: runner).listWorktrees(at: repository)
        return Dictionary(uniqueKeysWithValues: worktrees.map { ($0.rootURL.lastPathComponent, $0.id) })
    }

    func dispose() {
        try? FileManager.default.removeItem(at: container)
    }
}
