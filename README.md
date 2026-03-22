# AX事業部 工数トラッカー

デジタルゴリラ AX事業部の**工数自動集計システム**。

各メンバーのGoogleカレンダーから日報を自動生成し、顧客別・メンバー別の工数をダッシュボードで可視化します。

## 仕組み

```
各メンバーのGoogleカレンダー
  → worklog-auto.gs（GAS / 日次自動実行）
  → 日報 MD + 構造化 JSON を生成
  → Supabase Storage にアップロード
  → ダッシュボード（Vercel）で自動集計・可視化
```

**ダッシュボード**: https://ax-tracker.vercel.app

## セットアップ（メンバー向け）

### 1. カレンダーの予定に案件タグをつける

予定タイトルの先頭に `[顧客名]` をつけてください。

```
[川口印刷] AI研修 準備      → 顧客: 川口印刷
[ブレイク] LP修正レビュー    → 顧客: ブレイク
[丸善工業] AI導入 現状診断   → 顧客: 丸善工業
定例MTG                     → カテゴリ: 社内MTG（自動分類）
```

### 2. GASスクリプトをデプロイ

1. [Google Apps Script](https://script.google.com/) で新規プロジェクト作成
2. `scripts/worklog-auto.gs` の内容をすべて貼り付け
3. `generateAndUpload` を手動実行して動作確認
4. `setupTrigger` を実行（毎朝9時に前日分を自動生成）

### 3. 過去分のバックフィル（任意）

GASエディタで以下を実行：

```javascript
backfill(14);  // 過去14日分を一括生成
```

## カレンダー → 日報の自動分類

タイトルに `[顧客名]` がない場合、キーワードで自動分類されます：

| キーワード | カテゴリ |
|-----------|---------|
| 研修・トレーニング | 研修 |
| 制作・LP・デザイン・開発 | 制作/開発 |
| AI導入・コンサル・診断 | AI導入支援 |
| 講座・セミナー | AI講座 |
| MTG・定例・会議 | 社内MTG |
| 1on1・面談 | 1on1 |
| 営業・商談・提案 | 営業 |

## 生成される日報

各日、以下の2ファイルが Supabase に保存されます：

### 日報MD（人間が読む用）

```markdown
# 日報 2026-03-21

- **担当者**: T Yasunaga（t.yasunaga@digital-gorilla.co.jp）
- **合計稼働**: 7.5h（450分）

## 顧客別サマリー

| 顧客 | 時間 | 件数 | 構成比 |
|------|------|------|--------|
| 川口印刷 | 3.0h | 2件 | 40% |
| ブレイク | 2.5h | 1件 | 33% |
| 社内MTG | 2.0h | 2件 | 27% |

## タイムライン

- 09:00-12:00 | **川口印刷** | [川口印刷] AI研修 準備 (3.0h)
- 13:00-15:30 | **ブレイク** | [ブレイク] LP修正レビュー (2.5h)
- 15:30-17:30 | **社内MTG** | 定例MTG (2.0h)
```

### 構造化JSON（ダッシュボードが読む用）

```json
{
  "date": "2026-03-21",
  "uid": "327cb009",
  "name": "T Yasunaga",
  "total_hours": 7.5,
  "clients": [
    { "name": "川口印刷", "hours": 3.0, "count": 2 },
    { "name": "ブレイク", "hours": 2.5, "count": 1 }
  ],
  "categories": [
    { "name": "研修", "hours": 3.0 },
    { "name": "制作/開発", "hours": 2.5 }
  ]
}
```

## ダッシュボードの表示内容

- **チーム合計稼働** / **稼働メンバー数** / **顧客数** / **日報提出率**
- **顧客別 工数**（横棒 + ドーナツ）
- **メンバー別 稼働時間**（横棒 + 日別推移）
- **顧客別 詳細テーブル**（顧客 × 時間 × 担当者数 × 構成比）
- **メンバー別 詳細テーブル**（メンバー × 時間 × 顧客数 × 日報数）
- **案件カテゴリ別 工数**

## ファイル構成

```
ax-tracker/
├── README.md
├── PROJECT_BRIEF.md
├── dashboard/
│   └── index.html            # ダッシュボード（Vercel デプロイ）
├── scripts/
│   ├── worklog-auto.gs       # カレンダー→日報 自動生成（★メイン）
│   ├── worklog-draft.gs      # 日報素案 Web App版（レガシー）
│   ├── gc-logger.sh          # Gemini CLI ロガー（補助）
│   ├── cc-logger.sh          # Claude Code ロガー（補助）
│   ├── gc-install.sh         # CLIロガー インストーラー
│   └── *.ps1                 # Windows版
├── config/
│   └── gemini-settings.json  # Gemini CLI hooks テンプレート
└── docs/
    └── setup-guide.md        # 詳細セットアップガイド
```

## インフラ

| コンポーネント | サービス | 用途 |
|--------------|---------|------|
| 日報データ | Supabase Storage | `ax-tracker-logs` バケット |
| ダッシュボード | Vercel | https://ax-tracker.vercel.app |
| 日報生成 | Google Apps Script | 各メンバーのカレンダー読み取り |

## Supabase Storage 構造

```
ax-tracker-logs/
├── {uid}/
│   ├── profile.json              # メンバープロファイル
│   └── worklogs/
│       ├── 2026-03-20.md         # 日報（MD）
│       ├── 2026-03-20.json       # 日報（構造化JSON）
│       ├── 2026-03-21.md
│       └── 2026-03-21.json
```
