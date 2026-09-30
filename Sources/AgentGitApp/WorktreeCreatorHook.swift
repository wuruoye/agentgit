import AgentGitCore
import AgentGitIntegrationShared
import Foundation

/// 全局 git 配置里的 `hook.agentgit.*`：`git worktree add` 触发 post-checkout 时，
/// 把运行这条命令的 agent 会话记到 AgentGit 的 worktree 创建者目录。配置式 hook 和仓库自带的
/// hook（如 git-lfs）同时运行，不占用 `.git/hooks` 或 `core.hooksPath`。
enum WorktreeCreatorHook {
    // post-checkout 参数：旧 HEAD、新 HEAD、是否切分支。新建 worktree 时旧 HEAD 全零；
    // 只有 linked worktree 的 git 目录里有 commondir，clone 出来的主 checkout 不记录。
    // Claude 的 Bash 子进程有 CLAUDE_CODE_SESSION_ID；EnterWorktree 由 claude 进程直接调 git，
    // 环境里只有 Desktop 会话 ID，这时从 Desktop 索引读出 cliSessionId。agent 互相嵌套时
    // 外层的 Desktop 会话 ID 会被继承，所以它排在最后，索引里的 cliSessionId 也必须和会话一致。
    // 认不出会话时（宿主自己建的 worktree）留一个待查标记，AgentGit 收到通知后按宿主元数据补查。
    // 文件名、字段和通知与 AgentWorktreeCreatorStore 一致；plutil 负责 JSON 转义，
    // 它把 `{}` 当成 OpenStep 格式，所以先建 xml1 再转换。Desktop 索引里可能有转义的空字符
    // `\u0000`，plutil 会整体解析失败，读之前先去掉。
    static let script = """
    #!/bin/sh
    # Installed by AgentGit. Records the agent session that ran `git worktree add`.
    case "$1" in ""|*[!0]*) exit 0 ;; esac
    [ -f "$(git rev-parse --absolute-git-dir 2>/dev/null)/commondir" ] || exit 0
    worktree=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
    if [ -n "$CLAUDE_CODE_SESSION_ID" ]; then
        provider=claude session=$CLAUDE_CODE_SESSION_ID
    elif [ -n "$CODEX_THREAD_ID" ]; then
        provider=codex session=$CODEX_THREAD_ID
        title=$(grep -F '"id":"'"$session"'"' "$HOME/.codex/session_index.jsonl" 2>/dev/null |
            tail -n 1 | /usr/bin/plutil -extract thread_name raw -o - - 2>/dev/null)
    elif [ -n "$CLAUDE_CODE_HOST_SESSION_ID" ]; then
        provider=claude session=
    else
        provider= session=
    fi
    host_session=
    if [ "$provider" = claude ] && [ -n "$CLAUDE_CODE_HOST_SESSION_ID" ]; then
        for index in "$HOME/Library/Application Support/Claude/claude-code-sessions"/*/*/"$CLAUDE_CODE_HOST_SESSION_ID.json"; do
            [ -f "$index" ] || continue
            json=$(sed 's/\\\\u0000//g' "$index")
            cli=$(printf '%s' "$json" | /usr/bin/plutil -extract cliSessionId raw -o - - 2>/dev/null)
            [ -n "$session" ] || session=$cli
            [ -n "$cli" ] && [ "$cli" = "$session" ] || continue
            host_session=$CLAUDE_CODE_HOST_SESSION_ID
            title=$(printf '%s' "$json" | /usr/bin/plutil -extract title raw -o - - 2>/dev/null)
        done
    fi
    store="$HOME/Library/Application Support/AgentGit/worktree-creators"
    mkdir -p "$store/pending" && chmod 700 "$store" || exit 0
    name=$(printf '%s' "$worktree" | /usr/bin/shasum -a 256 | cut -c 1-64)
    if [ -z "$session" ]; then
        printf '%s\n' "$worktree" > "$store/pending/$name" &&
            /usr/bin/notifyutil -p \(AgentWorktreeCreatorStore.changedNotificationName)
        exit 0
    fi
    tmp="$store/.$name.$$"
    put() { [ -z "$2" ] || /usr/bin/plutil -insert "$1" -string "$2" "$tmp.plist"; }
    /usr/bin/plutil -create xml1 "$tmp.plist" &&
        put worktree_path "$worktree" && put provider "$provider" && put session_id "$session" &&
        put host_session_id "$host_session" && put title "$title" &&
        put created_at "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" && put source git-hook &&
        /usr/bin/plutil -convert json -o "$tmp" "$tmp.plist" >/dev/null 2>&1 &&
        mv -f "$tmp" "$store/$name.json" &&
        /usr/bin/notifyutil -p \(AgentWorktreeCreatorStore.changedNotificationName)
    rm -f "$tmp.plist" "$tmp"
    exit 0

    """

    private static let runner = GitCommandRunner()
    private static let homeURL = FileManager.default.homeDirectoryForCurrentUser

    static var scriptURL: URL {
        get throws {
            try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("AgentGit/git-hooks/post-checkout", isDirectory: false)
        }
    }

    /// git 用 shell 执行 hook 命令，路径里有空格（Application Support），要整体加引号。
    static func command(for scriptURL: URL) -> String {
        "'" + scriptURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func isInstalled() async -> Bool {
        guard let scriptURL = try? scriptURL,
              FileManager.default.isExecutableFile(atPath: scriptURL.path),
              let data = try? await runner.run(
                  arguments: ["config", "--global", "--get", "hook.agentgit.command"],
                  workingDirectory: homeURL
              ) else {
            return false
        }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .newlines) == command(for: scriptURL)
    }

    static func install() async throws {
        let scriptURL = try scriptURL
        try writeScript(to: scriptURL)
        _ = try await runner.run(
            arguments: ["config", "--global", "hook.agentgit.event", "post-checkout"],
            workingDirectory: homeURL
        )
        _ = try await runner.run(
            arguments: ["config", "--global", "hook.agentgit.command", command(for: scriptURL)],
            workingDirectory: homeURL
        )
    }

    /// App 更新后脚本可能已经变了；hook 已安装时把脚本换成当前版本。
    static func updateInstalledScript() async {
        guard await isInstalled(),
              let scriptURL = try? scriptURL,
              (try? String(contentsOf: scriptURL, encoding: .utf8)) != script else {
            return
        }
        try? writeScript(to: scriptURL)
    }

    private static func writeScript(to scriptURL: URL) throws {
        try FileManager.default.createDirectory(
            at: scriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
    }

    static func uninstall() async throws {
        _ = try await runner.run(
            arguments: ["config", "--global", "--remove-section", "hook.agentgit"],
            workingDirectory: homeURL
        )
    }
}
