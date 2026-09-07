#!/bin/bash
# Normal calls are silent. Failures request diagnosis without blocking the original tool.
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$(/usr/bin/head -c 2000001)"
OUTPUT="$(printf '%s' "$PAYLOAD" | "${SCRIPT_DIR}/../bin/AgentGitSkillBridge" hook --provider codex 2>/dev/null)"
BRIDGE_STATUS=$?
if [[ "$BRIDGE_STATUS" -eq 0 ]]; then
    [[ -z "$OUTPUT" ]] || printf '%s\n' "$OUTPUT"
    exit 0
fi
# Even a missing/crashed bridge should reach the model. Never interpolate command text.
EVENT="$(printf '%s' "$PAYLOAD" | /usr/bin/plutil -extract hook_event_name raw -o - - 2>/dev/null)"
case "$EVENT" in SessionStart|PreToolUse|PostToolUse|PostToolUseFailure) ;; *) exit 0 ;; esac
SESSION="$(printf '%s' "$PAYLOAD" | /usr/bin/plutil -extract session_id raw -o - - 2>/dev/null)"
KEY="$(printf '%s\n' "$SCRIPT_DIR" "$SESSION" | /usr/bin/shasum -a 256)"
KEY="${KEY%% *}"
DIAGNOSTIC_DIR="${TMPDIR:-/tmp}/AgentGit-hook-bootstrap"
/bin/mkdir -p "$DIAGNOSTIC_DIR" 2>/dev/null || exit 0
/usr/bin/find "$DIAGNOSTIC_DIR" -mindepth 1 -maxdepth 1 -type d -name '*.pending' -mtime +7 -exec /bin/rmdir {} \; 2>/dev/null
/bin/mkdir "${DIAGNOSTIC_DIR}/${KEY}.pending" 2>/dev/null || exit 0
printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"AgentGit registration helper failed to start or crashed. Diagnose the installed agentgit plugin scripts and signed bridge, repair the verified cause within the authorized scope, and preserve the original task. Do not repeatedly retry the failing hook. This diagnostic is emitted once per session and plugin location."}}\n' "$EVENT"
exit 0
