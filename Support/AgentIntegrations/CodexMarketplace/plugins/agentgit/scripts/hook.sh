#!/bin/bash
# Advisory hook: never replace host output or block the user's repository operation.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/../bin/AgentGitSkillBridge" hook --provider codex >/dev/null 2>&1
exit 0
