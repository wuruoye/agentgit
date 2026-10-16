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

SIGNING_IDENTITY_FILE="${AGENTGIT_SIGNING_IDENTITY_FILE:-${HOME}/Library/Application Support/AgentGit/signing-identity}"
SIGNING_IDENTITY="${AGENTGIT_SIGNING_IDENTITY:-}"
if [[ -z "${SIGNING_IDENTITY}" && -r "${SIGNING_IDENTITY_FILE}" ]]; then
    SIGNING_IDENTITY="$(/bin/cat "${SIGNING_IDENTITY_FILE}")"
fi
if [[ -z "${SIGNING_IDENTITY}" || "${SIGNING_IDENTITY}" == "-" ]]; then
    echo "AgentGit requires a certificate signing identity. Save it to ${SIGNING_IDENTITY_FILE} or set AGENTGIT_SIGNING_IDENTITY." >&2
    exit 1
fi
if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/awk -v identity="${SIGNING_IDENTITY}" '
    $2 == identity { found = 1 }
    {
        split($0, fields, "\"")
        if (fields[2] == identity) found = 1
    }
    END { exit !found }
'; then
    echo "Signing identity is unavailable in the Keychain: ${SIGNING_IDENTITY}" >&2
    exit 1
fi

cd "${PROJECT_DIR}"
swift build -c "${CONFIGURATION}"

BIN_DIR="$(swift build -c "${CONFIGURATION}" --show-bin-path)"
APP_DIR="${PROJECT_DIR}/.build/${CONFIGURATION}/AgentGit.app"
CONTENTS_DIR="${APP_DIR}/Contents"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
ICON_PATH="${PROJECT_DIR}/.build/${CONFIGURATION}/AgentGit.icns"

"${PROJECT_DIR}/scripts/build-icon.sh" \
    "${PROJECT_DIR}/Support/Assets/AgentGitAppIcon.png" \
    "${ICON_PATH}"

/bin/rm -rf "${APP_DIR}"
mkdir -p "${CONTENTS_DIR}/MacOS" "${RESOURCES_DIR}"
install -m 755 "${BIN_DIR}/AgentGitApp" "${CONTENTS_DIR}/MacOS/AgentGitApp"
install -m 644 "${PROJECT_DIR}/Support/Info.plist" "${CONTENTS_DIR}/Info.plist"
install -m 644 "${ICON_PATH}" "${RESOURCES_DIR}/AgentGit.icns"
/usr/bin/ditto "${BIN_DIR}/AgentGit_AgentGitApp.bundle" "${RESOURCES_DIR}/AgentGit_AgentGitApp.bundle"
sign_target() {
    local target="$1"
    if [[ "${CONFIGURATION}" == "release" ]]; then
        local -a signing_options=(--force --options runtime)
        if [[ "${SIGNING_IDENTITY}" == "Developer ID Application:"* ]]; then
            signing_options+=(--timestamp)
        fi
        /usr/bin/codesign \
            "${signing_options[@]}" \
            --sign "${SIGNING_IDENTITY}" \
            "${target}"
    else
        /usr/bin/codesign \
            --force \
            --sign "${SIGNING_IDENTITY}" \
            "${target}"
    fi
}

sign_target "${APP_DIR}"
/usr/bin/codesign --verify --deep --strict "${APP_DIR}"

echo "${APP_DIR}"
