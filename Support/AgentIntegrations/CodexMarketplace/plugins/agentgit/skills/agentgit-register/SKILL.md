---
name: agentgit-register
description: Complete a registration requested by the AgentGit pre-write hook. Use only when that hook blocks a repository write and provides a registration token.
---

# AgentGit Registration

Use the exact token from the blocking Hook message. Never invent or reuse a token.

1. Inspect the pending write intent:

   ```bash
   AGENTGIT_SKILL_CALL=1 "${PLUGIN_ROOT}/bin/AgentGitHookBridge" inspect --token "<token>"
   ```

2. Read the returned provider, worktree, tool, and target. Combine those facts with the current user request to create:

   - a concise session title of at most 80 characters;
   - an operation summary of at most 200 characters describing the intended repository change.

   Keep both values free of secrets and shell interpolation characters.

3. Prepare the organized registration handoff:

   ```bash
   AGENTGIT_SKILL_CALL=1 "${PLUGIN_ROOT}/scripts/register.sh" "<token>" "<session title>" "<operation summary>"
   ```

4. Confirm that the script returned the same provider, session, and worktree. Retry the blocked tool call with its original input so the Hook can finalize the association and allow the write.

Stop and surface the script error when inspection or registration fails. The Hook will issue a fresh token when the user retries the repository write.
