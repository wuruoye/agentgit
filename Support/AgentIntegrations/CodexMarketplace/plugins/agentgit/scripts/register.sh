#!/bin/bash

set -euo pipefail

if [[ "$#" -ne 3 ]]; then
    echo "usage: register.sh <token> <session-title> <operation-summary>" >&2
    exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/../bin/AgentGitHookBridge" \
    register \
    --token "$1" \
    --title "$2" \
    --summary "$3"
