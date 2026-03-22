#!/bin/bash
# gc-logger.sh - デジタルゴリラ AX事業部トラッカー（Gemini CLI用）
# cc-logger.sh をベースにGemini CLI hooks向けに改修
#
# Gemini CLI hooks の規約:
#   - stdin: JSON入力
#   - stdout: JSON出力のみ（ログ等は stderr へ）
#   - exit 0: 正常

set -euo pipefail

# jq必須チェック
if ! command -v jq >/dev/null 2>&1; then
  echo '{"decision":"allow"}' # Gemini CLIにはallowを返して続行させる
  echo "gc-logger.sh: jq is required but not installed" >&2
  exit 0
fi

# ディレクトリ準備
LOG_DIR="$HOME/.ax-tracker/logs"
mkdir -p "$LOG_DIR"

DATE=$(date -u +%Y-%m-%d)
LOG_FILE="$LOG_DIR/$DATE.jsonl"

# stdinからJSON入力を読み込み
INPUT=$(cat)

# 共通フィールドの抽出
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
EVENT_NAME=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
TIMESTAMP=$(echo "$INPUT" | jq -r '.timestamp // empty')

# Gemini CLIはtimestampを渡してくれるが、なければ自前生成
if [ -z "$TIMESTAMP" ]; then
  TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
fi

# プロジェクト名（cwdの最後のコンポーネント）
PROJECT=$(basename "$CWD" 2>/dev/null || echo "unknown")

# ユーザーID（git emailのSHA256ハッシュ先頭8文字）
PROFILE="$HOME/.ax-tracker/user-profile.json"
if [ -f "$PROFILE" ]; then
  UID_HASH=$(jq -r '.uid // empty' "$PROFILE")
  MID_HASH=$(jq -r '.mid // empty' "$PROFILE")
else
  GIT_EMAIL=$(git config user.email 2>/dev/null || echo "unknown")
  UID_HASH=$(echo -n "$GIT_EMAIL" | shasum -a 256 | cut -c1-8)
  MID_HASH=$(echo -n "$(hostname)" | shasum -a 256 | cut -c1-8)
fi

# イベント種別に応じてログレコードを構築
case "$EVENT_NAME" in
  "SessionStart")
    SOURCE=$(echo "$INPUT" | jq -r '.source // empty')
    RECORD=$(jq -nc \
      --arg event "session_start" \
      --arg ts "$TIMESTAMP" \
      --arg sid "$SESSION_ID" \
      --arg uid "$UID_HASH" \
      --arg mid "$MID_HASH" \
      --arg project "$PROJECT" \
      --arg source "$SOURCE" \
      --arg cli "gemini" \
      '{event:$event,ts:$ts,sid:$sid,uid:$uid,mid:$mid,project:$project,source:$source,cli:$cli}')
    ;;

  "SessionEnd")
    REASON=$(echo "$INPUT" | jq -r '.reason // empty')
    RECORD=$(jq -nc \
      --arg event "session_end" \
      --arg ts "$TIMESTAMP" \
      --arg sid "$SESSION_ID" \
      --arg uid "$UID_HASH" \
      --arg mid "$MID_HASH" \
      --arg project "$PROJECT" \
      --arg reason "$REASON" \
      --arg cli "gemini" \
      '{event:$event,ts:$ts,sid:$sid,uid:$uid,mid:$mid,project:$project,reason:$reason,cli:$cli}')
    ;;

  "BeforeAgent")
    PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty')
    PROMPT_LEN=${#PROMPT}
    RECORD=$(jq -nc \
      --arg event "user_prompt" \
      --arg ts "$TIMESTAMP" \
      --arg sid "$SESSION_ID" \
      --arg uid "$UID_HASH" \
      --arg mid "$MID_HASH" \
      --arg project "$PROJECT" \
      --argjson prompt_len "$PROMPT_LEN" \
      --arg cli "gemini" \
      '{event:$event,ts:$ts,sid:$sid,uid:$uid,mid:$mid,project:$project,prompt_len:$prompt_len,cli:$cli}')
    ;;

  "AfterAgent")
    RECORD=$(jq -nc \
      --arg event "agent_response" \
      --arg ts "$TIMESTAMP" \
      --arg sid "$SESSION_ID" \
      --arg uid "$UID_HASH" \
      --arg mid "$MID_HASH" \
      --arg project "$PROJECT" \
      --arg cli "gemini" \
      '{event:$event,ts:$ts,sid:$sid,uid:$uid,mid:$mid,project:$project,cli:$cli}')
    ;;

  "AfterTool")
    TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

    # Gemini CLI のツール名をカテゴリに分類
    case "$TOOL_NAME" in
      run_shell_command|shell) CATEGORY="bash" ;;
      edit_file|write_file|create_file) CATEGORY="file_edit" ;;
      read_file|read_many_files) CATEGORY="file_read" ;;
      glob|grep|find_files|list_directory) CATEGORY="search" ;;
      web_search|web_fetch) CATEGORY="web" ;;
      mcp__*) CATEGORY="mcp" ;;
      *) CATEGORY="other" ;;
    esac

    # detail抽出
    case "$TOOL_NAME" in
      run_shell_command|shell)
        DETAIL=$(echo "$INPUT" | jq -r '.tool_input.command // empty' | awk '{print $1}')
        ;;
      edit_file|write_file|create_file|read_file)
        DETAIL=$(echo "$INPUT" | jq -r '.tool_input.path // .tool_input.file_path // empty' | sed 's/.*\./\./')
        ;;
      glob|grep|find_files)
        DETAIL=$(echo "$INPUT" | jq -r '.tool_input.pattern // .tool_input.query // empty' | cut -c1-10)
        ;;
      mcp__*)
        DETAIL=$(echo "$TOOL_NAME" | sed 's/mcp__\([^_]*\)__.*/\1/')
        ;;
      web_fetch)
        DETAIL=$(echo "$INPUT" | jq -r '.tool_input.url // empty' | sed -E 's#https?://([^/]+).*#\1#' | cut -d: -f1)
        ;;
      web_search)
        DETAIL=$(echo "$INPUT" | jq -r '.tool_input.query // empty' | awk '{print $1}')
        ;;
      *)
        DETAIL=""
        ;;
    esac

    # エラー判定
    HAS_ERROR=$(echo "$INPUT" | jq -r '.tool_response.error // empty')
    if [ -n "$HAS_ERROR" ]; then
      EVENT_TYPE="tool_failure"
      RECORD=$(jq -nc \
        --arg event "$EVENT_TYPE" \
        --arg ts "$TIMESTAMP" \
        --arg sid "$SESSION_ID" \
        --arg uid "$UID_HASH" \
        --arg mid "$MID_HASH" \
        --arg project "$PROJECT" \
        --arg tool "$TOOL_NAME" \
        --arg category "$CATEGORY" \
        --arg error_head "$(echo "$HAS_ERROR" | cut -c1-100)" \
        --arg cli "gemini" \
        '{event:$event,ts:$ts,sid:$sid,uid:$uid,mid:$mid,project:$project,tool:$tool,category:$category,error_head:$error_head,cli:$cli}')
    else
      EVENT_TYPE="tool_use"
      RECORD=$(jq -nc \
        --arg event "$EVENT_TYPE" \
        --arg ts "$TIMESTAMP" \
        --arg sid "$SESSION_ID" \
        --arg uid "$UID_HASH" \
        --arg mid "$MID_HASH" \
        --arg project "$PROJECT" \
        --arg tool "$TOOL_NAME" \
        --arg category "$CATEGORY" \
        --arg detail "$DETAIL" \
        --arg cli "gemini" \
        '{event:$event,ts:$ts,sid:$sid,uid:$uid,mid:$mid,project:$project,tool:$tool,category:$category,detail:$detail,cli:$cli}')
    fi
    ;;

  "PreCompress")
    TRIGGER=$(echo "$INPUT" | jq -r '.trigger // empty')
    RECORD=$(jq -nc \
      --arg event "compaction" \
      --arg ts "$TIMESTAMP" \
      --arg sid "$SESSION_ID" \
      --arg uid "$UID_HASH" \
      --arg mid "$MID_HASH" \
      --arg project "$PROJECT" \
      --arg trigger "$TRIGGER" \
      --arg cli "gemini" \
      '{event:$event,ts:$ts,sid:$sid,uid:$uid,mid:$mid,project:$project,trigger:$trigger,cli:$cli}')
    ;;

  *)
    # 未対応イベントは無視、Gemini CLIにはallowを返す
    echo '{"decision":"allow"}'
    exit 0
    ;;
esac

# JSONLに追記（atomic append）
echo "$RECORD" >> "$LOG_FILE"

# Supabase Storageにバックグラウンド同期（30秒デバウンス）
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

# Gemini CLI にはallowを返す（hookを通過させる）
echo '{"decision":"allow"}'
exit 0
