#!/bin/bash
# gc-install.sh - AX事業部トラッカー インストーラー（macOS / Linux）
# Gemini CLI + Claude Code 両対応
#
# 使い方:
#   cd /tmp && git clone --depth 1 https://github.com/eternalrelief/ax-tracker.git && bash ax-tracker/scripts/gc-install.sh && rm -rf ax-tracker
#   または: bash gc-install.sh

set -euo pipefail

TRACKER_DIR="$HOME/.ax-tracker"
SCRIPTS_DIR="$TRACKER_DIR/scripts"
LOGS_DIR="$TRACKER_DIR/logs"
WORKLOGS_DIR="$TRACKER_DIR/worklogs"
GEMINI_SETTINGS="$HOME/.gemini/settings.json"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

echo "=== デジタルゴリラ AX事業部トラッカー セットアップ ==="
echo ""

# 1. jq チェック
if ! command -v jq >/dev/null 2>&1; then
  echo "❌ jq がインストールされていません"
  echo "   macOS: brew install jq"
  echo "   Ubuntu/Debian: sudo apt install jq"
  exit 1
fi
echo "✅ jq 確認OK"

# 2. ディレクトリ作成
mkdir -p "$SCRIPTS_DIR" "$LOGS_DIR" "$WORKLOGS_DIR"
echo "✅ ディレクトリ作成: $TRACKER_DIR"

# 3. スクリプトコピー
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
for SCRIPT in gc-logger.sh cc-logger.sh; do
  if [ -f "$SCRIPT_DIR/$SCRIPT" ]; then
    cp "$SCRIPT_DIR/$SCRIPT" "$SCRIPTS_DIR/$SCRIPT"
    chmod +x "$SCRIPTS_DIR/$SCRIPT"
    echo "✅ $SCRIPT インストール"
  else
    echo "⚠️  $SCRIPT が見つかりません"
  fi
done

# 4. ユーザープロファイル生成
PROFILE="$TRACKER_DIR/user-profile.json"
if [ ! -f "$PROFILE" ]; then
  GIT_NAME=$(git config user.name 2>/dev/null || echo "Unknown")
  GIT_EMAIL=$(git config user.email 2>/dev/null || echo "unknown@example.com")
  UID_HASH=$(echo -n "$GIT_EMAIL" | shasum -a 256 | cut -c1-8)
  MID_HASH=$(echo -n "$(hostname)" | shasum -a 256 | cut -c1-8)
  REGISTERED_AT=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

  jq -nc \
    --arg uid "$UID_HASH" \
    --arg mid "$MID_HASH" \
    --arg git_name "$GIT_NAME" \
    --arg git_email "$GIT_EMAIL" \
    --arg hostname "$(hostname)" \
    --arg os "$(uname -s | tr '[:upper:]' '[:lower:]')" \
    --arg registered_at "$REGISTERED_AT" \
    '{uid:$uid,mid:$mid,git_name:$git_name,git_email:$git_email,hostname:$hostname,os:$os,registered_at:$registered_at}' \
    > "$PROFILE"

  echo "✅ ユーザープロファイル生成"
  echo "   UID: $UID_HASH / Name: $GIT_NAME / Email: $GIT_EMAIL"
else
  echo "✅ ユーザープロファイル既存: $(jq -r '.uid' "$PROFILE")"
fi

# 5. Gemini CLI hooks 設定
GEMINI_HOOKS='{
  "SessionStart": [{"hooks": [{"name": "ax-tracker-session-start", "type": "command", "command": "~/.ax-tracker/scripts/gc-logger.sh"}]}],
  "SessionEnd": [{"hooks": [{"name": "ax-tracker-session-end", "type": "command", "command": "~/.ax-tracker/scripts/gc-logger.sh"}]}],
  "BeforeAgent": [{"hooks": [{"name": "ax-tracker-prompt", "type": "command", "command": "~/.ax-tracker/scripts/gc-logger.sh"}]}],
  "AfterAgent": [{"hooks": [{"name": "ax-tracker-response", "type": "command", "command": "~/.ax-tracker/scripts/gc-logger.sh"}]}],
  "AfterTool": [{"matcher": "*", "hooks": [{"name": "ax-tracker-tool", "type": "command", "command": "~/.ax-tracker/scripts/gc-logger.sh"}]}],
  "PreCompress": [{"hooks": [{"name": "ax-tracker-compress", "type": "command", "command": "~/.ax-tracker/scripts/gc-logger.sh"}]}]
}'

mkdir -p "$(dirname "$GEMINI_SETTINGS")"
if [ -f "$GEMINI_SETTINGS" ]; then
  EXISTING=$(jq -r '.hooks // {}' "$GEMINI_SETTINGS")
  MERGED=$(echo "$EXISTING" | jq --argjson new "$GEMINI_HOOKS" '. * $new')
  jq --argjson hooks "$MERGED" '.hooks = $hooks' "$GEMINI_SETTINGS" > "${GEMINI_SETTINGS}.tmp"
  mv "${GEMINI_SETTINGS}.tmp" "$GEMINI_SETTINGS"
  echo "✅ Gemini CLI hooks 追加（既存設定とマージ）"
else
  jq -nc --argjson hooks "$GEMINI_HOOKS" '{hooks: $hooks}' > "$GEMINI_SETTINGS"
  echo "✅ Gemini CLI settings.json 新規作成"
fi

# 6. Claude Code hooks 設定
CC_LOGGER="$HOME/.ax-tracker/scripts/cc-logger.sh"
CLAUDE_HOOKS=$(jq -nc \
  --arg cmd "$CC_LOGGER" \
  '{
    SessionStart: [{hooks: [{type: "command", command: $cmd}]}],
    SessionEnd: [{hooks: [{type: "command", command: $cmd}]}],
    UserPromptSubmit: [{hooks: [{type: "command", command: $cmd}]}],
    PostToolUse: [{hooks: [{type: "command", command: $cmd}]}],
    PostToolUseFailure: [{hooks: [{type: "command", command: $cmd}]}],
    SubagentStart: [{hooks: [{type: "command", command: $cmd}]}],
    SubagentStop: [{hooks: [{type: "command", command: $cmd}]}],
    PreCompact: [{hooks: [{type: "command", command: $cmd}]}]
  }')

mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
if [ -f "$CLAUDE_SETTINGS" ]; then
  EXISTING_CC=$(jq -r '.hooks // {}' "$CLAUDE_SETTINGS")
  MERGED_CC=$(echo "$EXISTING_CC" | jq --argjson new "$CLAUDE_HOOKS" '. * $new')
  jq --argjson hooks "$MERGED_CC" '.hooks = $hooks' "$CLAUDE_SETTINGS" > "${CLAUDE_SETTINGS}.tmp"
  mv "${CLAUDE_SETTINGS}.tmp" "$CLAUDE_SETTINGS"
  echo "✅ Claude Code hooks 追加（既存設定とマージ）"
else
  jq -nc --argjson hooks "$CLAUDE_HOOKS" '{hooks: $hooks}' > "$CLAUDE_SETTINGS"
  echo "✅ Claude Code settings.json 新規作成"
fi

# 7. 完了
echo ""
echo "=== セットアップ完了 ==="
echo ""
echo "📊 ログ保存先: $LOGS_DIR/YYYY-MM-DD.jsonl"
echo "📝 ワークログ: $WORKLOGS_DIR/"
echo ""
echo "対応CLI:"
echo "  ✅ Gemini CLI → 自動ログ記録"
echo "  ✅ Claude Code → 自動ログ記録"
echo ""
echo "⚠️  Supabase同期（オプション）:"
echo "   export AX_TRACKER_SUPABASE_URL='https://xxxxx.supabase.co'"
echo "   export AX_TRACKER_SUPABASE_KEY='eyJxxx...'"
echo ""
