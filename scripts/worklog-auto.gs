/**
 * worklog-auto.gs - Googleカレンダーから日報MDを自動生成 → Supabase保存
 *
 * 各メンバーが自分のGASプロジェクトにコピーしてデプロイ。
 * 日次トリガーで自動実行 → カレンダーから日報MD生成 → Supabaseにアップロード
 *
 * セットアップ:
 *   1. GASエディタで新規プロジェクト作成
 *   2. このコードを貼り付け
 *   3. CONFIG のSUPABASE_URL, SUPABASE_KEY を設定
 *   4. setupTrigger() を1回実行（日次トリガー設定）
 *   5. 手動テスト: generateAndUpload() を実行
 */

// ========== 設定 ==========
const CONFIG = {
  SUPABASE_URL: 'https://ccbyeaxfcnvnnotcurrk.supabase.co',
  SUPABASE_KEY: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNjYnllYXhmY252bm5vdGN1cnJrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQxNTEzMzcsImV4cCI6MjA4OTcyNzMzN30.b21WhWIAayql8WhZaayZZlhYMU0MXo3EbhOv-USBdek',
  BUCKET: 'ax-tracker-logs',
  TIMEZONE: 'Asia/Tokyo',
};

// 案件分類マッピング（カスタマイズ可）
const PROJECT_MAPPINGS = [
  { pattern: /研修|トレーニング/i, project: "研修" },
  { pattern: /制作|LP|デザイン|コーディング|開発/i, project: "制作/開発" },
  { pattern: /AI導入|コンサル|診断/i, project: "AI導入支援" },
  { pattern: /講座|セミナー|ウェビナー/i, project: "AI講座" },
  { pattern: /MTG|ミーティング|定例|会議/i, project: "社内MTG" },
  { pattern: /1on1|面談|フィードバック/i, project: "1on1" },
  { pattern: /営業|商談|提案/i, project: "営業" },
  { pattern: /事務|経理|請求|契約/i, project: "事務・管理" },
];

// ========== メイン処理 ==========

/**
 * メイン: 日報生成 → Supabaseアップロード
 * トリガーまたは手動で実行
 */
function generateAndUpload(targetDate) {
  const date = targetDate
    ? Utilities.formatDate(new Date(targetDate), CONFIG.TIMEZONE, 'yyyy-MM-dd')
    : Utilities.formatDate(new Date(), CONFIG.TIMEZONE, 'yyyy-MM-dd');

  const email = Session.getActiveUser().getEmail() || Session.getEffectiveUser().getEmail();
  const uid = hashUid(email);

  // カレンダー読み取り
  const entries = getCalendarEntries(date);

  // 日報MD生成
  const md = buildDailyReportMd(date, email, entries);

  // 構造化データ（JSON）も生成
  const summary = buildSummaryJson(date, email, uid, entries);

  // Supabaseアップロード
  uploadToSupabase(`${uid}/worklogs/${date}.md`, md, 'text/markdown');
  uploadToSupabase(`${uid}/worklogs/${date}.json`, JSON.stringify(summary, null, 2), 'application/json');

  // プロファイルも最新化
  const profile = {
    uid: uid,
    email: email,
    name: extractName(email),
    updated_at: new Date().toISOString(),
  };
  uploadToSupabase(`${uid}/profile.json`, JSON.stringify(profile), 'application/json');

  Logger.log(`✅ ${date} の日報をアップロードしました (${entries.length}件のイベント)`);
  return { date, entries: entries.length, md_length: md.length };
}

/**
 * 過去N日分をまとめて生成（初回セットアップ用）
 */
function backfill(days) {
  const n = days || 7;
  const results = [];
  for (let i = 0; i < n; i++) {
    const d = new Date();
    d.setDate(d.getDate() - i);
    const dateStr = Utilities.formatDate(d, CONFIG.TIMEZONE, 'yyyy-MM-dd');
    try {
      const r = generateAndUpload(dateStr);
      results.push(r);
      Utilities.sleep(500); // API制限回避
    } catch (e) {
      Logger.log(`⚠️ ${dateStr}: ${e.message}`);
    }
  }
  Logger.log(`バックフィル完了: ${results.length}/${n}日分`);
  return results;
}

// ========== カレンダー読み取り ==========

function getCalendarEntries(dateStr) {
  const date = new Date(dateStr + 'T00:00:00');
  const startOfDay = new Date(date.getFullYear(), date.getMonth(), date.getDate(), 0, 0, 0);
  const endOfDay = new Date(date.getFullYear(), date.getMonth(), date.getDate(), 23, 59, 59);

  const calendar = CalendarApp.getDefaultCalendar();
  const events = calendar.getEvents(startOfDay, endOfDay);

  return events
    .filter(e => !e.isAllDayEvent())
    .map(e => {
      const start = e.getStartTime();
      const end = e.getEndTime();
      const durationMin = (end - start) / (1000 * 60);
      const title = e.getTitle();
      const projectMatch = title.match(/^\[(.+?)\]/);
      const project = projectMatch ? projectMatch[1] : guessProject(title);
      // 顧客名: [顧客名/案件] or [顧客名] 形式から抽出
      const clientMatch = title.match(/^\[([^\]\/]+)/);
      const client = clientMatch ? clientMatch[1].trim() : project;

      return {
        start: Utilities.formatDate(start, CONFIG.TIMEZONE, 'HH:mm'),
        end: Utilities.formatDate(end, CONFIG.TIMEZONE, 'HH:mm'),
        duration_min: durationMin,
        duration_h: Math.round(durationMin / 60 * 10) / 10,
        title: title,
        project: project,
        client: client,
        description: (e.getDescription() || '').substring(0, 200),
      };
    })
    .sort((a, b) => a.start.localeCompare(b.start));
}

function guessProject(title) {
  for (const m of PROJECT_MAPPINGS) {
    if (m.pattern.test(title)) return m.project;
  }
  return 'その他';
}

// ========== 日報MD生成 ==========

function buildDailyReportMd(date, email, entries) {
  const byProject = aggregateBy(entries, 'project');
  const byClient = aggregateBy(entries, 'client');
  const totalMin = entries.reduce((s, e) => s + e.duration_min, 0);
  const totalH = Math.round(totalMin / 60 * 10) / 10;
  const name = extractName(email);

  let md = '';
  md += `# 日報 ${date}\n\n`;
  md += `- **担当者**: ${name}（${email}）\n`;
  md += `- **合計稼働**: ${totalH}h（${totalMin}分）\n`;
  md += `- **イベント数**: ${entries.length}件\n`;
  md += `- **生成日時**: ${new Date().toISOString()}\n\n`;

  // 顧客別サマリー
  md += `## 顧客別サマリー\n\n`;
  md += `| 顧客 | 時間 | 件数 | 構成比 |\n`;
  md += `|------|------|------|--------|\n`;
  const clients = Object.keys(byClient).sort((a, b) => byClient[b].total_min - byClient[a].total_min);
  for (const c of clients) {
    const d = byClient[c];
    const h = Math.round(d.total_min / 60 * 10) / 10;
    const pct = totalMin > 0 ? Math.round(d.total_min / totalMin * 100) : 0;
    md += `| ${c} | ${h}h | ${d.entries.length}件 | ${pct}% |\n`;
  }

  // 案件別サマリー
  md += `\n## 案件カテゴリ別\n\n`;
  md += `| カテゴリ | 時間 | 件数 |\n`;
  md += `|----------|------|------|\n`;
  const projects = Object.keys(byProject).sort((a, b) => byProject[b].total_min - byProject[a].total_min);
  for (const p of projects) {
    const d = byProject[p];
    const h = Math.round(d.total_min / 60 * 10) / 10;
    md += `| ${p} | ${h}h | ${d.entries.length}件 |\n`;
  }

  // タイムライン
  md += `\n## タイムライン\n\n`;
  for (const e of entries) {
    md += `- ${e.start}-${e.end} | **${e.client}** | ${e.title} (${e.duration_h}h)\n`;
  }

  if (entries.length === 0) {
    md += `_この日のカレンダーイベントはありませんでした。_\n`;
  }

  md += `\n---\n`;
  md += `> Googleカレンダーから自動生成（worklog-auto.gs）\n`;

  return md;
}

// ========== 構造化JSON ==========

function buildSummaryJson(date, email, uid, entries) {
  const byClient = aggregateBy(entries, 'client');
  const byProject = aggregateBy(entries, 'project');
  const totalMin = entries.reduce((s, e) => s + e.duration_min, 0);

  return {
    date: date,
    uid: uid,
    email: email,
    name: extractName(email),
    total_hours: Math.round(totalMin / 60 * 10) / 10,
    total_minutes: totalMin,
    event_count: entries.length,
    generated_at: new Date().toISOString(),
    clients: Object.keys(byClient).map(c => ({
      name: c,
      hours: Math.round(byClient[c].total_min / 60 * 10) / 10,
      minutes: byClient[c].total_min,
      count: byClient[c].entries.length,
    })).sort((a, b) => b.minutes - a.minutes),
    categories: Object.keys(byProject).map(p => ({
      name: p,
      hours: Math.round(byProject[p].total_min / 60 * 10) / 10,
      minutes: byProject[p].total_min,
      count: byProject[p].entries.length,
    })).sort((a, b) => b.minutes - a.minutes),
    timeline: entries.map(e => ({
      start: e.start,
      end: e.end,
      hours: e.duration_h,
      client: e.client,
      title: e.title,
      project: e.project,
    })),
  };
}

// ========== Supabase ==========

function uploadToSupabase(path, content, contentType) {
  const url = `${CONFIG.SUPABASE_URL}/storage/v1/object/${CONFIG.BUCKET}/${path}`;
  const options = {
    method: 'post',
    contentType: contentType || 'application/octet-stream',
    headers: {
      'Authorization': `Bearer ${CONFIG.SUPABASE_KEY}`,
      'apikey': CONFIG.SUPABASE_KEY,
      'x-upsert': 'true',
    },
    payload: content,
    muteHttpExceptions: true,
  };
  const res = UrlFetchApp.fetch(url, options);
  if (res.getResponseCode() >= 300) {
    throw new Error(`Supabase upload failed (${res.getResponseCode()}): ${res.getContentText()}`);
  }
  return JSON.parse(res.getContentText());
}

// ========== ユーティリティ ==========

function aggregateBy(entries, field) {
  const result = {};
  for (const e of entries) {
    const key = e[field] || 'その他';
    if (!result[key]) result[key] = { total_min: 0, entries: [] };
    result[key].total_min += e.duration_min;
    result[key].entries.push(e);
  }
  return result;
}

function hashUid(email) {
  const raw = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, email);
  return raw.map(b => ('0' + ((b + 256) % 256).toString(16)).slice(-2)).join('').substring(0, 8);
}

function extractName(email) {
  // t.yasunaga@digital-gorilla.co.jp → T.Yasunaga
  const local = email.split('@')[0];
  return local.split('.').map(s => s.charAt(0).toUpperCase() + s.slice(1)).join(' ');
}

// ========== トリガー設定 ==========

/**
 * 日次トリガーを設定（毎朝9時に前日分を自動生成）
 * 初回に1度だけ実行してください
 */
function setupTrigger() {
  // 既存トリガー削除
  const triggers = ScriptApp.getProjectTriggers();
  for (const t of triggers) {
    if (t.getHandlerFunction() === 'dailyRun') {
      ScriptApp.deleteTrigger(t);
    }
  }
  // 毎朝9時に実行
  ScriptApp.newTrigger('dailyRun')
    .timeBased()
    .everyDays(1)
    .atHour(9)
    .create();
  Logger.log('✅ 日次トリガーを設定しました（毎朝9時）');
}

/**
 * トリガーから呼ばれる: 前日分の日報を生成
 */
function dailyRun() {
  const yesterday = new Date();
  yesterday.setDate(yesterday.getDate() - 1);
  const dateStr = Utilities.formatDate(yesterday, CONFIG.TIMEZONE, 'yyyy-MM-dd');
  generateAndUpload(dateStr);
}

// ========== Web App ==========

function doGet(e) {
  const action = (e.parameter.action || 'draft').toLowerCase();
  const date = e.parameter.date || null;

  if (action === 'draft') {
    const md = buildDailyReportMd(
      date || Utilities.formatDate(new Date(), CONFIG.TIMEZONE, 'yyyy-MM-dd'),
      Session.getActiveUser().getEmail(),
      getCalendarEntries(date || Utilities.formatDate(new Date(), CONFIG.TIMEZONE, 'yyyy-MM-dd'))
    );
    return ContentService.createTextOutput(md).setMimeType(ContentService.MimeType.TEXT);
  }

  if (action === 'generate') {
    const result = generateAndUpload(date);
    return ContentService.createTextOutput(JSON.stringify(result, null, 2))
      .setMimeType(ContentService.MimeType.JSON);
  }

  if (action === 'backfill') {
    const days = parseInt(e.parameter.days || '7', 10);
    const results = backfill(days);
    return ContentService.createTextOutput(JSON.stringify(results, null, 2))
      .setMimeType(ContentService.MimeType.JSON);
  }

  return ContentService.createTextOutput(JSON.stringify({ error: 'unknown action', available: ['draft', 'generate', 'backfill'] }))
    .setMimeType(ContentService.MimeType.JSON);
}
