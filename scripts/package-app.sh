#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="${PROJECT_DIR}/.build/release/AgentGit.app"
INFO_PLIST="${PROJECT_DIR}/Support/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")"
ARCHIVE="${PROJECT_DIR}/.build/release/AgentGit-${VERSION}-macOS.zip"
CHECKSUM="${ARCHIVE}.sha256"
NOTARY_ARCHIVE="${PROJECT_DIR}/.build/release/AgentGit-${VERSION}-notary-upload.zip"
NOTARIZE=false

case "${1:-}" in
    "") ;;
    --notarize) NOTARIZE=true ;;
    *)
        echo "usage: $0 [--notarize]" >&2
        exit 2
        ;;
esac

if [[ "${NOTARIZE}" == true ]]; then
    : "${AGENTGIT_SIGNING_IDENTITY:?Set AGENTGIT_SIGNING_IDENTITY to a Developer ID Application identity}"
    : "${AGENTGIT_NOTARY_PROFILE:?Set AGENTGIT_NOTARY_PROFILE to a notarytool Keychain profile}"
    if [[ "${AGENTGIT_SIGNING_IDENTITY}" != "Developer ID Application:"* ]]; then
        echo "--notarize requires a Developer ID Application signing identity" >&2
        exit 2
    fi
fi

mkdir -p "${PROJECT_DIR}/.build/release"
VERIFY_DIR="$(mktemp -d "${PROJECT_DIR}/.build/release/verify.XXXXXX")"

cleanup() {
    /bin/rm -rf "${VERIFY_DIR}"
    /bin/rm -f "${NOTARY_ARCHIVE}"
}

trap cleanup EXIT

"${SCRIPT_DIR}/build-app.sh" release
/usr/bin/codesign --verify --deep --strict "${APP_DIR}"

if [[ "${NOTARIZE}" == true ]]; then
    /bin/rm -f "${NOTARY_ARCHIVE}"
    /usr/bin/ditto \
        -c \
        -k \
        --keepParent \
        --sequesterRsrc \
        "${APP_DIR}" \
        "${NOTARY_ARCHIVE}"
    /usr/bin/xcrun notarytool submit \
        "${NOTARY_ARCHIVE}" \
        --keychain-profile "${AGENTGIT_NOTARY_PROFILE}" \
        --wait \
        --timeout "${AGENTGIT_NOTARY_TIMEOUT:-30m}"
    /usr/bin/xcrun stapler staple "${APP_DIR}"
    /usr/bin/xcrun stapler validate "${APP_DIR}"
fi

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
if [[ "${NOTARIZE}" == true ]]; then
    /usr/bin/xcrun stapler validate "${VERIFY_DIR}/AgentGit.app"
    /usr/sbin/spctl \
        --assess \
        --type execute \
        --verbose=4 \
        "${VERIFY_DIR}/AgentGit.app"
fi

echo "${ARCHIVE}"
echo "${CHECKSUM}"
