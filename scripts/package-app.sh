#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="${PROJECT_DIR}/.build/release/AgentGit.app"
INFO_PLIST="${PROJECT_DIR}/Support/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")"
ARCHIVE="${PROJECT_DIR}/.build/release/AgentGit-${VERSION}-macOS.zip"
CHECKSUM="${ARCHIVE}.sha256"
VERIFY_DIR="$(mktemp -d "${PROJECT_DIR}/.build/release/verify.XXXXXX")"

trap 'rm -rf "${VERIFY_DIR}"' EXIT

"${SCRIPT_DIR}/build-app.sh" release
/usr/bin/codesign --verify --deep --strict "${APP_DIR}"
/bin/rm -f "${ARCHIVE}" "${CHECKSUM}"
/usr/bin/ditto \
    -c \
    -k \
    --keepParent \
    --sequesterRsrc \
    "${APP_DIR}" \
    "${ARCHIVE}"
/usr/bin/shasum -a 256 "${ARCHIVE}" > "${CHECKSUM}"
cd "${PROJECT_DIR}"
/usr/bin/shasum -a 256 -c "${CHECKSUM}"
/usr/bin/unzip -tq "${ARCHIVE}" >/dev/null
/usr/bin/ditto -x -k "${ARCHIVE}" "${VERIFY_DIR}"
/usr/bin/codesign --verify --deep --strict "${VERIFY_DIR}/AgentGit.app"

echo "${ARCHIVE}"
echo "${CHECKSUM}"
