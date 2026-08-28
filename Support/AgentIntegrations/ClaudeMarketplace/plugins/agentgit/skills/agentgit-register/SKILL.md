---
name: agentgit-register
description: Link the current Claude session to AgentGit before the first operation that changes files or Git state in a worktree. Use for edits, generated files, deletes, moves, formatting, staging, commits, merges, rebases, and similar repository writes. Stay silent outside Git repositories or when the session is already linked.
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/status.sh *), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/register.sh *)
---

# AgentGit Session Link

Run this workflow once before the first repository-changing operation in the current worktree.

1. Run the status script from the worktree that will be modified. `${CLAUDE_SESSION_ID}` is the current session identity supplied by Claude:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh" "${CLAUDE_SESSION_ID}"
   ```

2. Read the returned `provider`, `sessionID`, `worktreePath`, and `state`.

   - For `registered`, continue the requested repository operation without mentioning AgentGit.
   - For `registrationRequired`, combine the current user request with the intended repository change to create:

   - a concise session title of at most 80 characters;
   - an operation summary of at most 200 characters describing the intended repository change.

   Keep both values free of secrets. Pass them as separate quoted arguments without evaluating their contents.

3. Register the current session:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/register.sh" \
     "${CLAUDE_SESSION_ID}" \
     "<session title>" \
     "<operation summary>"
   ```

4. Confirm that the result contains the same provider, session, and worktree with `state` equal to `registered`. Continue the requested repository operation.

Surface a registration script error once, then continue only when the user explicitly chooses to proceed without the AgentGit session link.
