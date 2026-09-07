#!/usr/bin/env python3
"""Exercise a packaged hook in isolated storage; never create live session links."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("plugin_root", type=Path)
    parser.add_argument("--provider", choices=["codex", "claude"], required=True)
    args = parser.parse_args()
    plugin = args.plugin_root.resolve()
    hook = plugin / "scripts/hook.sh"
    manifest = plugin / (".codex-plugin" if args.provider == "codex" else ".claude-plugin") / "plugin.json"
    version = json.loads(manifest.read_text())["version"]
    assert (plugin / "bin/AgentGitSkillBridge").is_file()
    hooks = json.loads((plugin / "hooks/hooks.json").read_text())["hooks"]
    assert hooks["PreToolUse"][0]["hooks"][0].get("async", False) is False
    assert hooks["PostToolUse"][0]["hooks"][0]["async"] is True
    with tempfile.TemporaryDirectory(prefix="agentgit-packaged-hook-") as temp:
        root = Path(temp).resolve()
        repo = root / "repository"
        data = root / "data"
        repo.mkdir()
        data.mkdir()
        env = dict(os.environ, AGENTGIT_DATA_DIRECTORY=str(data), GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null")
        subprocess.run(["/usr/bin/git", "init", "-q", str(repo)], env=env, check=True)
        session = "00000000-0000-4000-8000-000000000001"
        event = {"session_id": session, "cwd": str(repo), "tool_use_id": "file-write", "tool_name": "Write",
                 "tool_input": {"file_path": str(repo / "created.txt")}}
        durations = []

        def run(payload):
            started = time.monotonic()
            result = subprocess.run([str(hook)], cwd=repo, env=env, input=json.dumps(payload).encode(),
                                    capture_output=True, timeout=5)
            durations.append(time.monotonic() - started)
            assert (result.returncode, result.stdout, result.stderr) == (0, b"", b""), result

        # Large input spans multiple pipe reads. No model-visible text is permitted.
        run(dict(event, hook_event_name="SessionStart", unused_padding="x" * 100_000))
        receipts = json.loads((data / "registration-events.json").read_text())
        assert receipts[0]["pluginVersion"] == version
        assert not (data / "associations.json").exists()
        run(dict(event, hook_event_name="PreToolUse"))
        (repo / "created.txt").write_text("fixture\n")
        run(dict(event, hook_event_name="PostToolUse"))
        rows = json.loads((data / "associations.json").read_text())
        assert len(rows) == 1 and rows[0]["sessionID"] == session and Path(rows[0]["worktreePath"]).samefile(repo), rows
        assert not list((data / "hook-pending").iterdir())
        run(dict(event, hook_event_name="PreToolUse", tool_use_id="already-linked"))
        assert not list((data / "hook-pending").iterdir()), "A fresh association should skip another probe, including through path aliases"
        run(dict(event, hook_event_name="PostToolUse", tool_use_id="already-linked"))

        # Another process owns the association lock. The shim must return promptly,
        # preserve the original operation, and record a local failure when possible.
        with (data / "associations.json.lock").open("r+") as lock:
            fcntl.lockf(lock, fcntl.LOCK_EX)
            run(dict(event, hook_event_name="PreToolUse", tool_use_id="locked"))
            (repo / "created.txt").write_text("operation continued\n")
            assert durations[-1] < 2.0
        assert any(row["outcome"] == "failed" for row in json.loads((data / "registration-events.json").read_text()))
        assert (repo / "created.txt").read_text() == "operation continued\n"
        run({"hook_event_name": "SessionStart"})
        print(json.dumps({"provider": args.provider, "version": version, "result": "passed",
                          "hook_invocations": len(durations), "max_duration_ms": round(max(durations) * 1000, 1),
                          "storage": "isolated", "host_dispatch_verified": False}))


if __name__ == "__main__":
    main()
