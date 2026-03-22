# AX事業部トラッカー セットアップガイド

## 前提条件
- macOS または Linux
- Gemini CLI インストール済み（`gemini` コマンドが使える状態）
- `jq` インストール済み（`brew install jq` / `apt install jq`）
- Git設定済み（`git config user.email` が返る状態）

## セットアップ手順

### 1. インストーラーを実行

```bash
bash gc-install.sh
```

これで以下が自動的に行われます：
- `~/.ax-tracker/` ディレクトリ作成
- `gc-logger.sh` の配置
- ユーザープロファイル生成（git emailからUID生成）
- `~/.gemini/settings.json` にhooks設定を追加

### 2. 動作確認

```bash
# Gemini CLIを起動
gemini

# 何か質問する
> こんにちは

# セッション終了後、ログを確認
cat ~/.ax-tracker/logs/$(date -u +%Y-%m-%d).jsonl | jq .
```

以下のようなログが記録されていればOK：

```json
{
  "event": "session_start",
  "ts": "2026-03-20T10:00:00.000Z",
  "sid": "abc123",
  "uid": "a1b2c3d4",
  "mid": "e5f6g7h8",
  "project": "my-project",
  "source": "startup",
  "cli": "gemini"
}
```

### 3. Supabase同期（管理者が設定）

ダッシュボードにデータを表示するには、環境変数を設定します：

```bash
# ~/.zshrc または ~/.bashrc に追記
export AX_TRACKER_SUPABASE_URL='https://xxxxx.supabase.co'
export AX_TRACKER_SUPABASE_KEY='eyJxxx...'
```

## ログの仕組み

### 記録されるイベント

| イベント | タイミング | 記録内容 |
|---------|----------|---------|
| `session_start` | Gemini CLI起動時 | プロジェクト名、開始元 |
| `session_end` | Gemini CLI終了時 | 終了理由 |
| `user_prompt` | プロンプト入力時 | プロンプト文字数 |
| `agent_response` | 応答完了時 | - |
| `tool_use` | ツール実行成功時 | ツール名、カテゴリ、詳細 |
| `tool_failure` | ツール実行失敗時 | ツール名、エラー |
| `compaction` | コンテキスト圧縮時 | トリガー |

### プロジェクト名の判定
`cwd`（カレントディレクトリ）のフォルダ名が自動的にプロジェクト名になります。
案件ごとにディレクトリを分けて作業すれば、自動的に案件別の工数が計測されます。

```
~/projects/案件A/  → project: "案件A"
~/projects/案件B/  → project: "案件B"
```

### 個人情報について
- メールアドレスはSHA256ハッシュ化されてUID（先頭8文字）として記録
- プロンプト内容は記録されません（文字数のみ）
- ツール実行の詳細は最小限（拡張子、コマンド名の先頭のみ）

## トラブルシューティング

### ログが記録されない
```bash
# hooks設定を確認
cat ~/.gemini/settings.json | jq '.hooks'

# gc-logger.sh に実行権限があるか確認
ls -la ~/.ax-tracker/scripts/gc-logger.sh
```

### Supabase同期が動かない
```bash
# 環境変数を確認
echo $AX_TRACKER_SUPABASE_URL
echo $AX_TRACKER_SUPABASE_KEY

# 手動で同期テスト
curl -v -X POST "${AX_TRACKER_SUPABASE_URL}/storage/v1/object/ax-tracker-logs/test/test.jsonl" \
  -H "Authorization: Bearer ${AX_TRACKER_SUPABASE_KEY}" \
  -H "Content-Type: application/octet-stream" \
  --data '{"test":true}'
```
