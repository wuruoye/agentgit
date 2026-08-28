#!/bin/bash

set -euo pipefail

if [[ "$#" -ne 3 ]]; then
    echo "usage: register.sh <session-id> <session-title> <operation-summary>" >&2
    exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/../bin/AgentGitSkillBridge" \
    register \
    --provider claude \
    --session "$1" \
    --worktree "$(pwd -P)" \
    --title "$2" \
    --summary "$3"
