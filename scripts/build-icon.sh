#!/bin/bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <source.png> <output.icns>" >&2
    exit 2
fi

SOURCE_IMAGE="$1"
OUTPUT_ICNS="$2"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentgit-icon.XXXXXX")"
ICONSET_DIR="${TEMP_DIR}/AgentGit.iconset"

trap 'rm -rf "${TEMP_DIR}"' EXIT
mkdir -p "${ICONSET_DIR}"

resize_icon() {
    local size="$1"
    local filename="$2"
    /usr/bin/sips -z "${size}" "${size}" "${SOURCE_IMAGE}" \
        --out "${ICONSET_DIR}/${filename}" >/dev/null
}

resize_icon 16 icon_16x16.png
resize_icon 32 icon_16x16@2x.png
resize_icon 32 icon_32x32.png
resize_icon 64 icon_32x32@2x.png
resize_icon 128 icon_128x128.png
resize_icon 256 icon_128x128@2x.png
resize_icon 256 icon_256x256.png
resize_icon 512 icon_256x256@2x.png
resize_icon 512 icon_512x512.png
resize_icon 1024 icon_512x512@2x.png

mkdir -p "$(dirname "${OUTPUT_ICNS}")"
/usr/bin/iconutil -c icns "${ICONSET_DIR}" -o "${OUTPUT_ICNS}"
