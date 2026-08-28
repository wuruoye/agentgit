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

command -v codex >/dev/null
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

if ! codex plugin marketplace list --json \
    | jq -e 'any(.marketplaces[]; .name == "personal")' >/dev/null; then
    codex plugin marketplace add \
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

if codex plugin list --json \
    | jq -e --arg id "${CODEX_PLUGIN_ID}" \
        'any(.installed[]; .pluginId == $id)' >/dev/null; then
    codex plugin remove "${CODEX_PLUGIN_ID}" --json
fi
codex plugin add "${CODEX_PLUGIN_ID}" --json

if claude plugin list --json \
    | jq -e --arg id "${CLAUDE_PLUGIN_ID}" \
        'any(.[]; (.pluginId // .id) == $id)' >/dev/null; then
    claude plugin uninstall --scope user --yes "${CLAUDE_PLUGIN_ID}"
fi
claude plugin install --scope user --yes "${CLAUDE_PLUGIN_ID}"

codex plugin list --json \
    | jq -e --arg id "${CODEX_PLUGIN_ID}" --arg version "${PLUGIN_VERSION}" \
        'any(.installed[]; .pluginId == $id and .version == $version and .enabled == true)'
claude plugin list --json \
    | jq -e --arg id "${CLAUDE_PLUGIN_ID}" --arg version "${PLUGIN_VERSION}" \
        'any(.[]; (.pluginId // .id) == $id and .version == $version and .enabled == true)'

codex plugin remove "${CODEX_PLUGIN_ID}" --json
codex plugin list --json \
    | jq -e --arg id "${CODEX_PLUGIN_ID}" \
        'all(.installed[]; .pluginId != $id)'
codex plugin add "${CODEX_PLUGIN_ID}" --json

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
    test -x "${plugin_root}/bin/AgentGitHookBridge"
    test -x "${plugin_root}/scripts/register.sh"
    test -f "${plugin_root}/hooks/hooks.json"
    test -f "${plugin_root}/skills/agentgit-register/SKILL.md"
    jq -e '
        .hooks.PreToolUse[0].matcher == "Bash|Edit|Write|NotebookEdit"
        and (.hooks.PreToolUse[0].hooks[0] | has("statusMessage") | not)
    ' "${plugin_root}/hooks/hooks.json" >/dev/null
done

verify_hook_skill_flow() {
    local provider="$1"
    local plugin_root="$2"
    local tool_name="$3"
    local session_id="$4"
    local repository
    local data_directory
    local handoff_directory
    local hook_input
    local read_hook_input
    local hook_error
    local token

    repository="$(mktemp -d "${VERIFICATION_ROOT}/${provider}-hook-repository.XXXXXX")"
    data_directory="$(mktemp -d "${VERIFICATION_ROOT}/${provider}-hook-data.XXXXXX")"
    handoff_directory="$(mktemp -d "${VERIFICATION_ROOT}/${provider}-hook-handoff.XXXXXX")"
    /usr/bin/git -C "${repository}" init -b main >/dev/null
    hook_input="$(jq -cn \
        --arg session "${session_id}" \
        --arg cwd "${repository}" \
        --arg tool "${tool_name}" \
        '{session_id:$session,cwd:$cwd,hook_event_name:"PreToolUse",tool_name:$tool,tool_input:{command:"git add README.md"}}')"
    read_hook_input="$(jq -cn \
        --arg session "${session_id}" \
        --arg cwd "${repository}" \
        --arg tool "${tool_name}" \
        '{session_id:$session,cwd:$cwd,hook_event_name:"PreToolUse",tool_name:$tool,tool_input:{command:"git status --short"}}')"
    hook_error="${VERIFICATION_ROOT}/${provider}-hook-block.txt"

    AGENTGIT_DATA_DIRECTORY="${data_directory}" \
        AGENTGIT_HANDOFF_DIRECTORY="${handoff_directory}" \
        "${plugin_root}/bin/AgentGitHookBridge" \
        guard --provider "${provider}" \
        <<< "${read_hook_input}"
    test -z "$(find "${data_directory}" -mindepth 1 -print -quit)"

    set +e
    AGENTGIT_DATA_DIRECTORY="${data_directory}" \
        AGENTGIT_HANDOFF_DIRECTORY="${handoff_directory}" \
        "${plugin_root}/bin/AgentGitHookBridge" \
        guard --provider "${provider}" \
        <<< "${hook_input}" \
        2> "${hook_error}"
    hook_status=$?
    set -e
    test "${hook_status}" -eq 2
    token="$(grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}' "${hook_error}" | tail -n 1)"
    test -n "${token}"

    AGENTGIT_DATA_DIRECTORY="${data_directory}" \
        AGENTGIT_HANDOFF_DIRECTORY="${handoff_directory}" \
        "${plugin_root}/bin/AgentGitHookBridge" \
        inspect --token "${token}" \
        | jq -e --arg provider "${provider}" --arg worktree "${repository}" \
            '.provider == $provider and .worktreePath == $worktree'

    AGENTGIT_DATA_DIRECTORY="${data_directory}" \
        AGENTGIT_HANDOFF_DIRECTORY="${handoff_directory}" \
        "${plugin_root}/scripts/register.sh" \
        "${token}" \
        "Hook Skill Verification" \
        "Register the session before the repository write." \
        | jq -e --arg provider "${provider}" --arg worktree "${repository}" \
            '.provider == $provider and .worktreePath == $worktree'

    AGENTGIT_DATA_DIRECTORY="${data_directory}" \
        AGENTGIT_HANDOFF_DIRECTORY="${handoff_directory}" \
        "${plugin_root}/bin/AgentGitHookBridge" \
        guard --provider "${provider}" \
        <<< "${hook_input}"
    jq -e --arg provider "${provider}" --arg session "${session_id}" \
        'any(.[]; .provider == $provider and .sessionID == $session)' \
        "${data_directory}/associations.json"
}

verify_hook_skill_flow \
    codex \
    "${CODEX_CACHE}" \
    exec_command \
    "00000000-0000-4000-8000-000000000001"
verify_hook_skill_flow \
    claude \
    "${CLAUDE_CACHE}" \
    Bash \
    "00000000-0000-4000-8000-000000000002"

codex plugin list --json \
    | jq -e --arg id "${CODEX_PLUGIN_ID}" --arg version "${PLUGIN_VERSION}" \
        '.installed[] | select(.pluginId == $id and .version == $version and .enabled == true)'
claude plugin list --json \
    | jq -e --arg id "${CLAUDE_PLUGIN_ID}" --arg version "${PLUGIN_VERSION}" \
        '.[] | select((.pluginId // .id) == $id and .version == $version and .enabled == true)'
