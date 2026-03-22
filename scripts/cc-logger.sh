#!/bin/bash
# cc-logger.sh - AX事業部トラッカー（Claude Code用）
# Claude Code hooks 経由で呼ばれ、gc-logger.sh と同じJSONLスキーマでログを記録する
#
# Claude Code hooks の規約:
#   - stdin: JSON入力
#   - stdout: なし（出力するとClaude Codeの動作に影響する可能性あり）
#   - exit 0: 正常

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "cc-logger.sh: jq is required but not installed" >&2
  exit 0
fi

LOG_DIR="$HOME/.ax-tracker/logs"
mkdir -p "$LOG_DIR"

DATE=$(date -u +%Y-%m-%d)
LOG_FILE="$LOG_DIR/$DATE.jsonl"

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
EVENT_NAME=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
PMODE=$(echo "$INPUT" | jq -r '.permission_mode // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

PROJECT=$(basename "$CWD" 2>/dev/null || echo "unknown")

PROFILE="$HOME/.ax-tracker/user-profile.json"
if [ -f "$PROFILE" ]; then
  UID_HASH=$(jq -r '.uid // empty' "$PROFILE")
  MID_HASH=$(jq -r '.mid // empty' "$PROFILE")
else
  GIT_EMAIL=$(git config user.email 2>/dev/null || echo "unknown")
  UID_HASH=$(echo -n "$GIT_EMAIL" | shasum -a 256 | cut -c1-8)
  MID_HASH=$(echo -n "$(hostname)" | shasum -a 256 | cut -c1-8)
fi

case "$EVENT_NAME" in
  "SessionStart")
    SOURCE=$(echo "$INPUT" | jq -r '.source // empty')
    MODEL=$(echo "$INPUT" | jq -r '.model // empty')
    RECORD=$(jq -nc \
      --arg event "session_start" \
      --arg ts "$TIMESTAMP" \
      --arg sid "$SESSION_ID" \
      --arg uid "$UID_HASH" \
      --arg mid "$MID_HASH" \
      --arg pmode "$PMODE" \
      --arg project "$PROJECT" \
      --arg source "$SOURCE" \
      --arg model "$MODEL" \
      --arg cli "claude" \
      '{event:$event,ts:$ts,sid:$sid,uid:$uid,mid:$mid,pmode:$pmode,project:$project,source:$source,model:$model,cli:$cli}')
    ;;

  "SessionEnd")
    REASON=$(echo "$INPUT" | jq -r '.reason // empty')
    RECORD=$(jq -nc \
      --arg event "session_end" \
      --arg ts "$TIMESTAMP" \
      --arg sid "$SESSION_ID" \
      --arg uid "$UID_HASH" \
      --arg mid "$MID_HASH" \
      --arg pmode "$PMODE" \
      --arg project "$PROJECT" \
      --arg reason "$REASON" \
      --arg cli "claude" \
      '{event:$event,ts:$ts,sid:$sid,uid:$uid,mid:$mid,pmode:$pmode,project:$project,reason:$reason,cli:$cli}')
    ;;

  "UserPromptSubmit")
    PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty')
    PROMPT_LEN=${#PROMPT}
    RECORD=$(jq -nc \
      --arg event "user_prompt" \
      --arg ts "$TIMESTAMP" \
      --arg sid "$SESSION_ID" \
      --arg uid "$UID_HASH" \
      --arg mid "$MID_HASH" \
      --arg pmode "$PMODE" \
      --arg project "$PROJECT" \
      --argjson prompt_len "$PROMPT_LEN" \
      --arg cli "claude" \
      '{event:$event,ts:$ts,sid:$sid,uid:$uid,mid:$mid,pmode:$pmode,project:$project,prompt_len:$prompt_len,cli:$cli}')
    ;;

  "PostToolUse")
    TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

    case "$TOOL_NAME" in
      Bash) CATEGORY="bash" ;;
      Edit|Write) CATEGORY="file_edit" ;;
      Read) CATEGORY="file_read" ;;
      Glob|Grep) CATEGORY="search" ;;
      Agent) CATEGORY="subagent" ;;
      WebFetch|WebSearch) CATEGORY="web" ;;
      mcp__*) CATEGORY="mcp" ;;
      *) CATEGORY="other" ;;
    esac

    case "$TOOL_NAME" in
      Bash)
        DETAIL=$(echo "$INPUT" | jq -r '.tool_input.command // empty' | awk '{print $1}')
        ;;
      Edit|Write|Read)
        DETAIL=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' | sed 's/.*\./\./')
        ;;
      Glob|Grep)
        DETAIL=$(echo "$INPUT" | jq -r '.tool_input.pattern // empty' | cut -c1-10)
        ;;
      Agent)
        DETAIL=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty')
        ;;
      mcp__*)
        DETAIL=$(echo "$TOOL_NAME" | sed 's/mcp__\([^_]*\)__.*/\1/')
        ;;
      WebFetch)
        DETAIL=$(echo "$INPUT" | jq -r '.tool_input.url // empty' | sed -E 's#https?://([^/]+).*#\1#' | cut -d: -f1)
        ;;
      WebSearch)
        DETAIL=$(echo "$INPUT" | jq -r '.tool_input.query // empty' | awk '{print $1}')
        ;;
      *)
        DETAIL=""
        ;;
    esac

    RECORD=$(jq -nc \
      --arg event "tool_use" \
      --arg ts "$TIMESTAMP" \
      --arg sid "$SESSION_ID" \
      --arg uid "$UID_HASH" \
      --arg mid "$MID_HASH" \
      --arg pmode "$PMODE" \
      --arg project "$PROJECT" \
      --arg tool "$TOOL_NAME" \
      --arg category "$CATEGORY" \
      --arg detail "$DETAIL" \
      --arg cli "claude" \
      '{event:$event,ts:$ts,sid:$sid,uid:$uid,mid:$mid,pmode:$pmode,project:$project,tool:$tool,category:$category,detail:$detail,cli:$cli}')
    ;;

  "PostToolUseFailure")
    TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
    ERROR=$(echo "$INPUT" | jq -r '.error // empty' | cut -c1-100)
    RECORD=$(jq -nc \
      --arg event "tool_failure" \
      --arg ts "$TIMESTAMP" \
      --arg sid "$SESSION_ID" \
      --arg uid "$UID_HASH" \
      --arg mid "$MID_HASH" \
      --arg pmode "$PMODE" \
      --arg project "$PROJECT" \
      --arg tool "$TOOL_NAME" \
      --arg error_head "$ERROR" \
      --arg cli "claude" \
      '{event:$event,ts:$ts,sid:$sid,uid:$uid,mid:$mid,pmode:$pmode,project:$project,tool:$tool,error_head:$error_head,cli:$cli}')
    ;;

  "SubagentStart")
    AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
    AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')
    RECORD=$(jq -nc \
      --arg event "subagent_start" \
      --arg ts "$TIMESTAMP" \
      --arg sid "$SESSION_ID" \
      --arg uid "$UID_HASH" \
      --arg mid "$MID_HASH" \
      --arg pmode "$PMODE" \
      --arg project "$PROJECT" \
      --arg agent_id "$AGENT_ID" \
      --arg agent_type "$AGENT_TYPE" \
      --arg cli "claude" \
      '{event:$event,ts:$ts,sid:$sid,uid:$uid,mid:$mid,pmode:$pmode,project:$project,agent_id:$agent_id,agent_type:$agent_type,cli:$cli}')
    ;;

  "SubagentStop")
    AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
    AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')
    RECORD=$(jq -nc \
      --arg event "subagent_stop" \
      --arg ts "$TIMESTAMP" \
      --arg sid "$SESSION_ID" \
      --arg uid "$UID_HASH" \
      --arg mid "$MID_HASH" \
      --arg pmode "$PMODE" \
      --arg project "$PROJECT" \
      --arg agent_id "$AGENT_ID" \
      --arg agent_type "$AGENT_TYPE" \
      --arg cli "claude" \
      '{event:$event,ts:$ts,sid:$sid,uid:$uid,mid:$mid,pmode:$pmode,project:$project,agent_id:$agent_id,agent_type:$agent_type,cli:$cli}')
    ;;

  "PreCompact")
    TRIGGER=$(echo "$INPUT" | jq -r '.trigger // empty')
    RECORD=$(jq -nc \
      --arg event "compaction" \
      --arg ts "$TIMESTAMP" \
      --arg sid "$SESSION_ID" \
      --arg uid "$UID_HASH" \
      --arg mid "$MID_HASH" \
      --arg pmode "$PMODE" \
      --arg project "$PROJECT" \
      --arg trigger "$TRIGGER" \
      --arg cli "claude" \
      '{event:$event,ts:$ts,sid:$sid,uid:$uid,mid:$mid,pmode:$pmode,project:$project,trigger:$trigger,cli:$cli}')
    ;;

  *)
    exit 0
    ;;
esac

echo "$RECORD" >> "$LOG_FILE"

# Supabase同期（gc-logger.shと同じロジック）
SYNC_LOCK="/tmp/ax-tracker-sync.lock"
SYNC_AGE=999
if [ -f "$SYNC_LOCK" ]; then
  SYNC_AGE=$(( $(date +%s) - $(stat -f %m "$SYNC_LOCK" 2>/dev/null || stat -c %Y "$SYNC_LOCK" 2>/dev/null || echo 0) ))
fi
if [ "$SYNC_AGE" -gt 30 ]; then
  touch "$SYNC_LOCK"
  (
    _SB_URL="${AX_TRACKER_SUPABASE_URL:-}"
    _SB_KEY="${AX_TRACKER_SUPABASE_KEY:-}"
    if [ -n "$_SB_URL" ] && [ -n "$_SB_KEY" ]; then
      curl -s -o /dev/null \
        -X POST "${_SB_URL}/storage/v1/object/ax-tracker-logs/${UID_HASH}/${DATE}.jsonl" \
        -H "Authorization: Bearer ${_SB_KEY}" \
        -H "Content-Type: application/octet-stream" \
        -H "x-upsert: true" \
        --data-binary "@${LOG_FILE}" 2>/dev/null || true
      if [ -f "$PROFILE" ]; then
        curl -s -o /dev/null \
          -X POST "${_SB_URL}/storage/v1/object/ax-tracker-logs/${UID_HASH}/profile.json" \
          -H "Authorization: Bearer ${_SB_KEY}" \
          -H "Content-Type: application/json" \
          -H "x-upsert: true" \
          --data-binary "@${PROFILE}" 2>/dev/null || true
      fi
    fi
  ) &
fi

exit 0
