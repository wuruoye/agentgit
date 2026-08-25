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
# ad-hoc 签名没有稳定身份，每次重建都会让 TCC 重新弹“文稿”授权并挂起 git 子进程；
# 用固定开发证书签名让授权跨构建保留。
SIGNING_IDENTITY="${AGENTGIT_SIGNING_IDENTITY:-Apple Development: Example (TEAMID)}"
/usr/bin/codesign --force --sign "${SIGNING_IDENTITY}" "${APP_DIR}"

echo "${APP_DIR}"
