#!/bin/bash
set -euo pipefail
SAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SAMPLE_DIR}/../.." && pwd)"
OUTPUT_DIR="${1:-${SAMPLE_DIR}/output}"
BUILD_DIR="${PROJECT_DIR}/.build/review-sample"
mkdir -p "${BUILD_DIR}" "${OUTPUT_DIR}"
swiftc \
    "${PROJECT_DIR}/Sources/AgentGitApp/AgentGitPalette.swift" \
    "${PROJECT_DIR}/Sources/AgentGitCore/DiffSyntaxHighlighter.swift" \
    "${SAMPLE_DIR}/ReviewSample.swift" \
    -o "${BUILD_DIR}/render-review"
"${BUILD_DIR}/render-review" "${OUTPUT_DIR}/fixture.json" "${OUTPUT_DIR}"
