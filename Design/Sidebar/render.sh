#!/bin/bash
set -euo pipefail
TASK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${TASK_DIR}/../.." && pwd)"
OUTPUT_DIR="${1:-${TASK_DIR}/output}"
BUILD_DIR="${PROJECT_DIR}/.build/sidebar-sample"
mkdir -p "${BUILD_DIR}" "${OUTPUT_DIR}"
swiftc \
    "${PROJECT_DIR}/Sources/AgentGitApp/AgentGitPalette.swift" \
    "${TASK_DIR}/SidebarSample.swift" \
    -o "${BUILD_DIR}/render-sidebar"
"${BUILD_DIR}/render-sidebar" "${OUTPUT_DIR}"
