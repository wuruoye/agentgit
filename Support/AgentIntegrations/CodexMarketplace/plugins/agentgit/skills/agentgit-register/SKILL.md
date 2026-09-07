---
name: agentgit-register
description: Manually link a session to a Git worktree or diagnose missing AgentGit associations when the user requests it. Automatic registration is handled by plugin hooks; routine repository work does not require this skill.
---

# AgentGit Session Link

Automatic registration runs through host hooks, without agent tool calls or generated metadata.

For an explicit manual registration request:

1. Use the exact current session ID provided by the host or user. Never guess from
   directory names, titles, recent sessions, or transcript contents. If unavailable,
   explain that a stable ID is required for manual linking; continue the original task.
2. From the target worktree, run `"${PLUGIN_ROOT}/scripts/register.sh" "<session-id>"`.
   An optional second argument supplies a title. No title or summary is required.
3. Check that the response has the intended provider, session, worktree and
   `state: registered`. Errors do not block the original development task.

For missing automatic associations, check AgentGit Settings → Agents for the last
hook receipt or failure. Plugin installation alone does not establish that hooks
are running. Codex requires trust of the current plugin hook definition; after an
update, review that trust and start a new task. Do not alter trust settings yourself.

Automatic coverage includes file editing tools and bounded before/after Git-state
checks around shell tools. Commands that write outside the exposed execution
folders, unresolved dynamic directories, timeouts and missing host events may
require manual registration. Do not claim exhaustive shell-write attribution.
