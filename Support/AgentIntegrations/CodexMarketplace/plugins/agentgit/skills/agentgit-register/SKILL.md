---
name: agentgit-register
description: Link the current Codex session to AgentGit before the first operation that changes files or Git state in a worktree. Use for edits, generated files, deletes, moves, formatting, staging, commits, merges, rebases, and similar repository writes. Stay silent outside Git repositories or when the session is already linked.
---

# AgentGit Session Link

Run this workflow once before the first repository-changing operation in the current worktree.

1. Resolve the current Codex session ID from explicit task or session metadata supplied by the host. Never infer it from the working directory, title, process environment, transcript files, or recent-session ordering. If the host does not expose a stable session ID, stop silently.

2. Run the status script from the worktree that will be modified:

   ```bash
   "${PLUGIN_ROOT}/scripts/status.sh" "<current-session-id>"
   ```

3. Read the returned `provider`, `sessionID`, `worktreePath`, and `state`.

   - For `registered`, continue the requested repository operation without mentioning AgentGit.
   - For `registrationRequired`, combine the current user request with the intended repository change to create:

   - a concise session title of at most 80 characters;
   - an operation summary of at most 200 characters describing the intended repository change.

   Keep both values free of secrets. Pass them as separate quoted arguments without evaluating their contents.

4. Register the current session:

   ```bash
   "${PLUGIN_ROOT}/scripts/register.sh" \
     "<current-session-id>" \
     "<session title>" \
     "<operation summary>"
   ```

5. Confirm that the result contains the same provider, session, and worktree with `state` equal to `registered`. Continue the requested repository operation.

Surface a registration script error once, then continue only when the user explicitly chooses to proceed without the AgentGit session link.
