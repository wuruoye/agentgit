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
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
HELPERS_DIR="${CONTENTS_DIR}/Helpers"
ICON_PATH="${PROJECT_DIR}/.build/${CONFIGURATION}/AgentGit.icns"
INTEGRATIONS_DIR="${RESOURCES_DIR}/AgentIntegrations"

"${PROJECT_DIR}/scripts/build-icon.sh" \
    "${PROJECT_DIR}/Support/Assets/AgentGitAppIcon.png" \
    "${ICON_PATH}"

/bin/rm -rf "${APP_DIR}"
mkdir -p "${CONTENTS_DIR}/MacOS" "${RESOURCES_DIR}" "${HELPERS_DIR}"
install -m 755 "${BIN_DIR}/AgentGitApp" "${CONTENTS_DIR}/MacOS/AgentGitApp"
install -m 755 "${BIN_DIR}/AgentGitSkillBridge" "${HELPERS_DIR}/AgentGitSkillBridge"
install -m 644 "${PROJECT_DIR}/Support/Info.plist" "${CONTENTS_DIR}/Info.plist"
install -m 644 "${ICON_PATH}" "${RESOURCES_DIR}/AgentGit.icns"
/usr/bin/ditto "${PROJECT_DIR}/Support/AgentIntegrations" "${INTEGRATIONS_DIR}"
for marketplace in CodexMarketplace ClaudeMarketplace; do
    plugin_bin="${INTEGRATIONS_DIR}/${marketplace}/plugins/agentgit/bin"
    mkdir -p "${plugin_bin}"
    install -m 755 "${BIN_DIR}/AgentGitSkillBridge" "${plugin_bin}/AgentGitSkillBridge"
done
# ad-hoc 签名没有稳定身份，每次重建都会让 TCC 重新弹“文稿”授权并挂起 git 子进程；
# 用固定开发证书签名让授权跨构建保留。
SIGNING_IDENTITY="${AGENTGIT_SIGNING_IDENTITY:-Apple Development: Example (TEAMID)}"
sign_target() {
    local target="$1"
    if [[ "${CONFIGURATION}" == "release" ]]; then
        /usr/bin/codesign \
            --force \
            --options runtime \
            --sign "${SIGNING_IDENTITY}" \
            "${target}"
    else
        /usr/bin/codesign \
            --force \
            --sign "${SIGNING_IDENTITY}" \
            "${target}"
    fi
}

sign_target "${HELPERS_DIR}/AgentGitSkillBridge"
sign_target "${INTEGRATIONS_DIR}/CodexMarketplace/plugins/agentgit/bin/AgentGitSkillBridge"
sign_target "${INTEGRATIONS_DIR}/ClaudeMarketplace/plugins/agentgit/bin/AgentGitSkillBridge"
sign_target "${APP_DIR}"
/usr/bin/codesign --verify --deep --strict "${APP_DIR}"

echo "${APP_DIR}"
