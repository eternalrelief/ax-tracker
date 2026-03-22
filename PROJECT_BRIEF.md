# デジタルゴリラ AX事業部トラッカー

## 概要
デジタルゴリラ AX事業部のチームメンバー（約10名）が Gemini CLI を使って業務を行う際に、
案件別の工数を自動計測し、ダッシュボードで可視化するシステム。

## 背景
- 業務委託含めて各メンバーがどの案件にどれだけ時間を使っているか把握したい
- 既存の [Claude Code Dashboard](https://claude-code-dashboard-lac.vercel.app/) と同じ仕組みをGemini CLI版で展開
- Google Workspace契約済みのため、Gemini CLI は追加費用なし

## アーキテクチャ

```
【メンバー側（Gemini CLI × 10人）】
Gemini CLI hooks（.gemini/settings.json）
  └── gc-logger.sh（自動ログ収集）
      └── ~/.ax-tracker/logs/YYYY-MM-DD.jsonl
          30秒デバウンスで Supabase Storage に自動sync

【ダッシュボード】
claude-code-dashboard（Vercel）拡張
  └── AX事業部 工数ビュー
      ├── Google認証（デジゴリアカウント）
      ├── メンバー別 稼働時間
      ├── 案件別 工数内訳
      └── チーム全体サマリー
```

## Gemini CLI Hooks 対応表

| イベント | Gemini CLI Hook | 記録内容 |
|---------|----------------|---------|
| セッション開始 | `SessionStart` | 開始時刻、プロジェクト名、source |
| セッション終了 | `SessionEnd` | 終了時刻、reason |
| プロンプト投入 | `BeforeAgent` | プロンプト長 |
| 応答完了 | `AfterAgent` | 応答完了 |
| ツール使用後 | `AfterTool` | ツール名、カテゴリ、詳細 |
| コンテキスト圧縮 | `PreCompress` | trigger |

## 成果物

| # | ファイル | 説明 |
|---|---------|------|
| 1 | `scripts/gc-logger.sh` | Gemini CLI用ログ収集スクリプト |
| 2 | `scripts/gc-install.sh` | メンバー配布用インストーラー |
| 3 | `config/gemini-settings.json` | Gemini CLI hooks設定テンプレート |
| 4 | `docs/setup-guide.md` | メンバー向けセットアップ手順 |

## 参考
- Claude Code Dashboard: https://github.com/UC5454/claude-code-dashboard
- cc-logger.sh: `~/.claude-code-dashboard/scripts/cc-logger.sh`
- Gemini CLI Hooks: https://geminicli.com/docs/hooks/reference/

## 担当
- プロジェクト統括: 龍造寺隆信（RYZ-001）
- データ設計・集計: 鍋島直茂（RYZ-002）
- ドキュメント: 成松信勝（RYZ-003）

## ステータス
- 起票日: 2026-03-20
- 状態: プロトタイプ作成中
