#!/bin/bash

set -euo pipefail

if [[ "$#" -ne 1 ]]; then
    echo "usage: status.sh <session-id>" >&2
    exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/../bin/AgentGitSkillBridge" \
    status \
    --provider claude \
    --session "$1" \
    --worktree "$(pwd -P)"
