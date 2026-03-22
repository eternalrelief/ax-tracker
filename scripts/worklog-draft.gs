/**
 * worklog-draft.gs - Googleカレンダーから日次ワークログ素案を生成
 *
 * GAS Web App として公開し、各メンバーが自分のカレンダーから
 * 当日の予定を案件別に集計 → MDフォーマットのワークログ素案を返す
 *
 * デプロイ: ウェブアプリとして公開（実行ユーザー: アクセスしたユーザー）
 *
 * エンドポイント:
 *   GET ?action=draft           → 当日のワークログ素案（MD形式）
 *   GET ?action=draft&date=YYYY-MM-DD → 指定日のワークログ素案
 *   GET ?action=confirm         → 素案を確定して保存
 */

/**
 * カレンダーイベントを取得して案件別に集計
 */
function getCalendarEvents(targetDate) {
  const date = targetDate ? new Date(targetDate) : new Date();
  const startOfDay = new Date(date.getFullYear(), date.getMonth(), date.getDate(), 0, 0, 0);
  const endOfDay = new Date(date.getFullYear(), date.getMonth(), date.getDate(), 23, 59, 59);

  const calendar = CalendarApp.getDefaultCalendar();
  const events = calendar.getEvents(startOfDay, endOfDay);

  const entries = events
    .filter(e => !e.isAllDayEvent()) // 終日イベントは除外
    .map(e => {
      const start = e.getStartTime();
      const end = e.getEndTime();
      const durationMin = (end - start) / (1000 * 60);
      const title = e.getTitle();

      // 案件名の推定: [案件名] プレフィックスまたはカレンダーのカラー等で分類
      const projectMatch = title.match(/^\[(.+?)\]/);
      const project = projectMatch ? projectMatch[1] : guessProject(title);

      return {
        start: Utilities.formatDate(start, Session.getScriptTimeZone(), "HH:mm"),
        end: Utilities.formatDate(end, Session.getScriptTimeZone(), "HH:mm"),
        duration_min: durationMin,
        duration_h: Math.round(durationMin / 60 * 10) / 10,
        title: title,
        project: project,
        description: e.getDescription() || ""
      };
    })
    .sort((a, b) => a.start.localeCompare(b.start));

  return entries;
}

/**
 * イベントタイトルから案件名を推定
 * カスタマイズ: ここにメンバーごとの案件マッピングを追加
 */
function guessProject(title) {
  const mappings = [
    { pattern: /研修|トレーニング/i, project: "研修" },
    { pattern: /制作|LP|デザイン|コーディング/i, project: "制作/開発" },
    { pattern: /AI導入|コンサル|診断/i, project: "AI導入支援" },
    { pattern: /講座|セミナー|ウェビナー/i, project: "AI講座" },
    { pattern: /MTG|ミーティング|定例|会議/i, project: "社内MTG" },
    { pattern: /1on1|面談/i, project: "1on1" },
    { pattern: /営業|商談|提案/i, project: "営業" },
  ];

  for (const m of mappings) {
    if (m.pattern.test(title)) return m.project;
  }
  return "その他";
}

/**
 * 案件別に集計
 */
function aggregateByProject(entries) {
  const byProject = {};
  for (const e of entries) {
    if (!byProject[e.project]) {
      byProject[e.project] = { total_min: 0, entries: [] };
    }
    byProject[e.project].total_min += e.duration_min;
    byProject[e.project].entries.push(e);
  }
  return byProject;
}

/**
 * MD形式のワークログ素案を生成
 */
function generateDraftMd(targetDate) {
  const date = targetDate || Utilities.formatDate(new Date(), Session.getScriptTimeZone(), "yyyy-MM-dd");
  const user = Session.getActiveUser().getEmail();
  const entries = getCalendarEvents(targetDate);
  const byProject = aggregateByProject(entries);

  const totalMin = entries.reduce((sum, e) => sum + e.duration_min, 0);
  const totalH = Math.round(totalMin / 60 * 10) / 10;

  let md = `# 日次ワークログ（素案）\n\n`;
  md += `- **日付**: ${date}\n`;
  md += `- **担当者**: ${user}\n`;
  md += `- **合計稼働**: ${totalH}h（${totalMin}分）\n`;
  md += `- **ステータス**: ⚠️ 未確定（要確認）\n\n`;

  md += `## 案件別サマリー\n\n`;
  md += `| 案件 | 時間 | 件数 |\n`;
  md += `|------|------|------|\n`;

  const projects = Object.keys(byProject).sort((a, b) => byProject[b].total_min - byProject[a].total_min);
  for (const p of projects) {
    const data = byProject[p];
    const h = Math.round(data.total_min / 60 * 10) / 10;
    md += `| ${p} | ${h}h | ${data.entries.length}件 |\n`;
  }

  md += `\n## タイムライン\n\n`;
  for (const e of entries) {
    md += `- ${e.start}-${e.end} | **${e.project}** | ${e.title} (${e.duration_h}h)\n`;
  }

  md += `\n---\n`;
  md += `> この素案はGoogleカレンダーから自動生成されました。\n`;
  md += `> 内容に誤りがあれば修正してから確定してください。\n`;

  return md;
}

/**
 * Web App エントリポイント
 */
function doGet(e) {
  const action = (e.parameter.action || "draft").toLowerCase();
  const date = e.parameter.date || null;

  if (action === "draft") {
    const md = generateDraftMd(date);
    return ContentService.createTextOutput(md).setMimeType(ContentService.MimeType.TEXT);
  }

  if (action === "events") {
    const entries = getCalendarEvents(date);
    return ContentService.createTextOutput(JSON.stringify(entries, null, 2))
      .setMimeType(ContentService.MimeType.JSON);
  }

  return ContentService.createTextOutput(JSON.stringify({ error: "unknown action" }))
    .setMimeType(ContentService.MimeType.JSON);
}
