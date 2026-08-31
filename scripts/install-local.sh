#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_APP="${PROJECT_DIR}/.build/release/AgentGit.app"
INSTALL_DIR="${AGENTGIT_INSTALL_DIR:-${HOME}/Applications}"
INSTALLED_APP="${INSTALL_DIR}/AgentGit.app"
LAUNCH_APP=true

case "${1:-}" in
    "") ;;
    --no-launch) LAUNCH_APP=false ;;
    *)
        echo "usage: $0 [--no-launch]" >&2
        exit 2
        ;;
esac

"${SCRIPT_DIR}/build-app.sh" release
mkdir -p "${INSTALL_DIR}"

STAGING_DIR="$(mktemp -d "${INSTALL_DIR}/.AgentGit-install.XXXXXX")"
STAGED_APP="${STAGING_DIR}/AgentGit.app"
PREVIOUS_APP="${STAGING_DIR}/AgentGit.previous.app"

cleanup() {
    /bin/rm -rf "${STAGING_DIR}"
}

trap cleanup EXIT

/usr/bin/ditto "${SOURCE_APP}" "${STAGED_APP}"
/usr/bin/codesign --verify --deep --strict "${STAGED_APP}"

while IFS= read -r process_id; do
    [[ -n "${process_id}" ]] || continue
    /bin/kill "${process_id}" 2>/dev/null || true
done < <(/usr/bin/pgrep -x AgentGitApp || true)

for attempt in {1..50}; do
    if ! /usr/bin/pgrep -x AgentGitApp >/dev/null 2>&1; then
        break
    fi
    /bin/sleep 0.1
done

if /usr/bin/pgrep -x AgentGitApp >/dev/null 2>&1; then
    echo "AgentGit is still running; close it and retry the installation." >&2
    exit 1
fi

if [[ -e "${INSTALLED_APP}" ]]; then
    /bin/mv "${INSTALLED_APP}" "${PREVIOUS_APP}"
fi

if ! /bin/mv "${STAGED_APP}" "${INSTALLED_APP}"; then
    if [[ -e "${PREVIOUS_APP}" ]]; then
        /bin/mv "${PREVIOUS_APP}" "${INSTALLED_APP}"
    fi
    exit 1
fi

if ! /usr/bin/codesign --verify --deep --strict "${INSTALLED_APP}"; then
    /bin/rm -rf "${INSTALLED_APP}"
    if [[ -e "${PREVIOUS_APP}" ]]; then
        /bin/mv "${PREVIOUS_APP}" "${INSTALLED_APP}"
    fi
    exit 1
fi

if [[ "${LAUNCH_APP}" == true ]]; then
    /usr/bin/open -g "${INSTALLED_APP}"
fi

echo "${INSTALLED_APP}"
