#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_PATH="${1:-${PROJECT_DIR}/.build/release/AgentGit.app}"
RESOURCE_ROOT="${APP_PATH}/Contents/Resources/AgentIntegrations"
INTEGRATION_ROOT="${HOME}/Library/Application Support/AgentGit/AgentIntegrations"
VERIFICATION_ROOT="${PROJECT_DIR}/.build/verification"
CODEX_PLUGIN_ID="agentgit@personal"
CLAUDE_PLUGIN_ID="agentgit@agentgit"
CODEX_SOURCE="${INTEGRATION_ROOT}/CodexMarketplace/plugins/agentgit"
CLAUDE_SOURCE="${INTEGRATION_ROOT}/ClaudeMarketplace/plugins/agentgit"

# Prefer the Desktop runtime; a PATH CLI can predate the current config schema.
CODEX_EXECUTABLE="${AGENTGIT_CODEX_CLI:-}"
if [[ -z "${CODEX_EXECUTABLE}" ]]; then
    for app in "${HOME}/Applications/ChatGPT.app" /Applications/ChatGPT.app \
        "${HOME}/Applications/Codex.app" /Applications/Codex.app; do
        if [[ -x "${app}/Contents/Resources/codex" ]]; then
            CODEX_EXECUTABLE="${app}/Contents/Resources/codex"
            break
        fi
    done
fi
if [[ -z "${CODEX_EXECUTABLE}" ]]; then
    CODEX_EXECUTABLE="$(command -v codex)"
fi
test -x "${CODEX_EXECUTABLE}"
command -v claude >/dev/null
command -v jq >/dev/null
test -d "${RESOURCE_ROOT}/CodexMarketplace"
test -d "${RESOURCE_ROOT}/ClaudeMarketplace"
mkdir -p "${INTEGRATION_ROOT}" "${VERIFICATION_ROOT}"

replace_marketplace() {
    local source="$1"
    local destination="$2"
    local staging_root
    local staged_directory
    local backup_directory
    staging_root="$(mktemp -d "${INTEGRATION_ROOT}/.replace.XXXXXX")"
    staged_directory="${staging_root}/payload"
    backup_directory="${destination}.backup.$(uuidgen)"
    /usr/bin/ditto "${source}" "${staged_directory}"
    if [[ -d "${destination}" ]]; then
        mv "${destination}" "${backup_directory}"
    fi
    mv "${staged_directory}" "${destination}"
    rmdir "${staging_root}"
    if [[ -d "${backup_directory}" ]]; then
        find "${backup_directory}" -depth -delete
    fi
}

replace_marketplace \
    "${RESOURCE_ROOT}/CodexMarketplace" \
    "${INTEGRATION_ROOT}/CodexMarketplace"
replace_marketplace \
    "${RESOURCE_ROOT}/ClaudeMarketplace" \
    "${INTEGRATION_ROOT}/ClaudeMarketplace"

PLUGIN_VERSION="$(/usr/bin/plutil -extract version raw "${CODEX_SOURCE}/.codex-plugin/plugin.json")"
CLAUDE_VERSION="$(/usr/bin/plutil -extract version raw "${CLAUDE_SOURCE}/.claude-plugin/plugin.json")"
test "${PLUGIN_VERSION}" = "${CLAUDE_VERSION}"

if ! "${CODEX_EXECUTABLE}" plugin marketplace list --json \
    | jq -e 'any(.marketplaces[]; .name == "personal")' >/dev/null; then
    "${CODEX_EXECUTABLE}" plugin marketplace add \
        "${INTEGRATION_ROOT}/CodexMarketplace" \
        --json
fi

if ! claude plugin marketplace list --json \
    | jq -e 'any(.[]; .name == "agentgit")' >/dev/null; then
    claude plugin marketplace add \
        --scope user \
        "${INTEGRATION_ROOT}/ClaudeMarketplace"
else
    claude plugin marketplace update agentgit
fi

if "${CODEX_EXECUTABLE}" plugin list --json \
    | jq -e --arg id "${CODEX_PLUGIN_ID}" \
        'any(.installed[]; .pluginId == $id)' >/dev/null; then
    "${CODEX_EXECUTABLE}" plugin remove "${CODEX_PLUGIN_ID}" --json
fi
"${CODEX_EXECUTABLE}" plugin add "${CODEX_PLUGIN_ID}" --json

if claude plugin list --json \
    | jq -e --arg id "${CLAUDE_PLUGIN_ID}" \
        'any(.[]; (.pluginId // .id) == $id)' >/dev/null; then
    claude plugin uninstall --scope user --yes "${CLAUDE_PLUGIN_ID}"
fi
claude plugin install --scope user --yes "${CLAUDE_PLUGIN_ID}"

"${CODEX_EXECUTABLE}" plugin list --json \
    | jq -e --arg id "${CODEX_PLUGIN_ID}" --arg version "${PLUGIN_VERSION}" \
        'any(.installed[]; .pluginId == $id and .version == $version and .enabled == true)'
claude plugin list --json \
    | jq -e --arg id "${CLAUDE_PLUGIN_ID}" --arg version "${PLUGIN_VERSION}" \
        'any(.[]; (.pluginId // .id) == $id and .version == $version and .enabled == true)'

"${CODEX_EXECUTABLE}" plugin remove "${CODEX_PLUGIN_ID}" --json
"${CODEX_EXECUTABLE}" plugin list --json \
    | jq -e --arg id "${CODEX_PLUGIN_ID}" \
        'all(.installed[]; .pluginId != $id)'
"${CODEX_EXECUTABLE}" plugin add "${CODEX_PLUGIN_ID}" --json

claude plugin disable --scope user "${CLAUDE_PLUGIN_ID}"
claude plugin list --json \
    | jq -e --arg id "${CLAUDE_PLUGIN_ID}" \
        'any(.[]; (.pluginId // .id) == $id and .enabled == false)'
claude plugin enable --scope user "${CLAUDE_PLUGIN_ID}"

CODEX_CACHE="${HOME}/.codex/plugins/cache/personal/agentgit/${PLUGIN_VERSION}"
CLAUDE_CACHE="$(claude plugin list --json \
    | jq -er --arg id "${CLAUDE_PLUGIN_ID}" \
        '.[] | select((.pluginId // .id) == $id) | .installPath')"

for plugin_root in "${CODEX_CACHE}" "${CLAUDE_CACHE}"; do
    test -x "${plugin_root}/bin/AgentGitSkillBridge"
    test -x "${plugin_root}/scripts/register.sh"
    test -x "${plugin_root}/scripts/status.sh"
    test -f "${plugin_root}/skills/agentgit-register/SKILL.md"
    test -x "${plugin_root}/scripts/hook.sh"
    jq -e '.hooks.PreToolUse[0].hooks[0].type == "command"
        and .hooks.PostToolUse[0].hooks[0].async == true' \
        "${plugin_root}/hooks/hooks.json"
    if [[ "${plugin_root}" == "${CODEX_CACHE}" ]]; then
        hook_provider=codex
    else
        hook_provider=claude
    fi
    python3 "${SCRIPT_DIR}/verify-agent-hooks.py" "${plugin_root}" --provider "${hook_provider}"

done

verify_skill_flow() {
    local provider="$1"
    local plugin_root="$2"
    local session_id="$3"
    local repository
    local data_directory

    repository="$(mktemp -d "${VERIFICATION_ROOT}/${provider}-skill-repository.XXXXXX")"
    data_directory="$(mktemp -d "${VERIFICATION_ROOT}/${provider}-skill-data.XXXXXX")"
    /usr/bin/git -C "${repository}" init -b main >/dev/null

    (
        cd "${repository}"
        AGENTGIT_DATA_DIRECTORY="${data_directory}" \
            "${plugin_root}/scripts/status.sh" "${session_id}"
    ) | jq -e \
        --arg provider "${provider}" \
        --arg session "${session_id}" \
        --arg worktree "${repository}" \
        '.provider == $provider
            and .sessionID == $session
            and .worktreePath == $worktree
            and .state == "registrationRequired"'

    (
        cd "${repository}"
        AGENTGIT_DATA_DIRECTORY="${data_directory}" \
            "${plugin_root}/scripts/register.sh" \
            "${session_id}" \
            "Skill Verification" \
            "Link the current session to the worktree."
    ) | jq -e \
        --arg provider "${provider}" \
        --arg session "${session_id}" \
        --arg worktree "${repository}" \
        '.provider == $provider
            and .sessionID == $session
            and .worktreePath == $worktree
            and .state == "registered"'

    (
        cd "${repository}"
        AGENTGIT_DATA_DIRECTORY="${data_directory}" \
            "${plugin_root}/scripts/status.sh" "${session_id}"
    ) | jq -e '.state == "registered" and .title == "Skill Verification"'

    jq -e --arg provider "${provider}" --arg session "${session_id}" \
        'any(.[]; .provider == $provider and .sessionID == $session)' \
        "${data_directory}/associations.json"
    jq -e --arg provider "${provider}" --arg session "${session_id}" \
        'any(.[];
            .provider == $provider
            and .sessionID == $session
            and .action == "register"
            and .outcome == "succeeded")' \
        "${data_directory}/registration-events.json"
    test ! -e "${data_directory}/pending-write-intents"
}

verify_skill_flow \
    codex \
    "${CODEX_CACHE}" \
    "00000000-0000-4000-8000-000000000001"
verify_skill_flow \
    claude \
    "${CLAUDE_CACHE}" \
    "00000000-0000-4000-8000-000000000002"

"${CODEX_EXECUTABLE}" plugin list --json \
    | jq -e --arg id "${CODEX_PLUGIN_ID}" --arg version "${PLUGIN_VERSION}" \
        '.installed[] | select(.pluginId == $id and .version == $version and .enabled == true)'
claude plugin list --json \
    | jq -e --arg id "${CLAUDE_PLUGIN_ID}" --arg version "${PLUGIN_VERSION}" \
        '.[] | select((.pluginId // .id) == $id and .version == $version and .enabled == true)'
