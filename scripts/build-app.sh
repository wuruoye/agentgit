#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIGURATION="${1:-debug}"

case "${CONFIGURATION}" in
    debug|release) ;;
    *)
        echo "usage: $0 [debug|release]" >&2
        exit 2
        ;;
esac

cd "${PROJECT_DIR}"
swift build -c "${CONFIGURATION}"

BIN_DIR="$(swift build -c "${CONFIGURATION}" --show-bin-path)"
APP_DIR="${PROJECT_DIR}/.build/${CONFIGURATION}/AgentGit.app"
CONTENTS_DIR="${APP_DIR}/Contents"

mkdir -p "${CONTENTS_DIR}/MacOS"
install -m 755 "${BIN_DIR}/AgentGitApp" "${CONTENTS_DIR}/MacOS/AgentGitApp"
install -m 644 "${PROJECT_DIR}/Support/Info.plist" "${CONTENTS_DIR}/Info.plist"
/usr/bin/codesign --force --sign - "${APP_DIR}"

echo "${APP_DIR}"
