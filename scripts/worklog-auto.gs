/**
 * worklog-auto.gs - カレンダー日報 確認フロー付き
 *
 * フロー:
 *   1. 毎朝トリガー or 手動で dailyRun() → ドラフト生成 → メールで確認リンク送信
 *   2. メンバーがブラウザで確認画面を開く → 各予定の顧客名を確認・修正
 *   3. 「確定」ボタン → Supabaseに confirmed として保存 → ダッシュボード反映
 *
 * セットアップ:
 *   1. GASで新規プロジェクト作成 → このコードを貼り付け
 *   2. setupTrigger() を1回実行
 *   3. ウェブアプリとしてデプロイ（実行: 自分、アクセス: 自分のみ）
 */

// ========== 設定 ==========
const CONFIG = {
  SUPABASE_URL: 'https://ccbyeaxfcnvnnotcurrk.supabase.co',
  SUPABASE_KEY: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNjYnllYXhmY252bm5vdGN1cnJrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQxNTEzMzcsImV4cCI6MjA4OTcyNzMzN30.b21WhWIAayql8WhZaayZZlhYMU0MXo3EbhOv-USBdek',
  BUCKET: 'ax-tracker-logs',
  TIMEZONE: 'Asia/Tokyo',
  COMPANY_DOMAIN: 'digital-gorilla.co.jp', // 自社ドメイン（社内判定に使用）
};

// カテゴリ推測マッピング
const CATEGORY_RULES = [
  { pattern: /研修|トレーニング|ハンズオン/i, category: '研修' },
  { pattern: /制作|LP|デザイン|コーディング|開発|実装/i, category: '制作/開発' },
  { pattern: /AI導入|コンサル|診断|ヒアリング/i, category: 'AI導入支援' },
  { pattern: /講座|セミナー|ウェビナー|登壇/i, category: 'AI講座' },
  { pattern: /MTG|ミーティング|定例|会議|朝会|夕会/i, category: '社内MTG' },
  { pattern: /1on1|面談|フィードバック|振り返り/i, category: '1on1' },
  { pattern: /営業|商談|提案|アポ/i, category: '営業' },
  { pattern: /事務|経理|請求|契約|見積/i, category: '事務・管理' },
  { pattern: /移動|ランチ|休憩/i, category: '非稼働' },
];

// ========== カレンダー読み取り + 推測 ==========

function getCalendarEntries(dateStr) {
  const date = new Date(dateStr + 'T00:00:00');
  const startOfDay = new Date(date.getFullYear(), date.getMonth(), date.getDate(), 0, 0, 0);
  const endOfDay = new Date(date.getFullYear(), date.getMonth(), date.getDate(), 23, 59, 59);

  const calendar = CalendarApp.getDefaultCalendar();
  const events = calendar.getEvents(startOfDay, endOfDay);

  // 過去の確定済みマッピングを取得（学習用）
  const knownMappings = loadKnownMappings_();

  return events
    .filter(e => !e.isAllDayEvent())
    .map((e, idx) => {
      const start = e.getStartTime();
      const end = e.getEndTime();
      const durationMin = (end - start) / (1000 * 60);
      const title = e.getTitle();
      const organizer = e.getCreators().join(', ');
      const guests = e.getGuestList(true).map(g => g.getEmail());
      const description = (e.getDescription() || '').substring(0, 300);

      // 顧客・カテゴリを推測
      const guess = guessClientAndCategory(title, organizer, guests, description, knownMappings);

      return {
        id: idx,
        start: Utilities.formatDate(start, CONFIG.TIMEZONE, 'HH:mm'),
        end: Utilities.formatDate(end, CONFIG.TIMEZONE, 'HH:mm'),
        duration_min: durationMin,
        duration_h: Math.round(durationMin / 60 * 10) / 10,
        title: title,
        organizer: organizer,
        guests: guests.length,
        // 推測結果（メンバーが修正可能）
        client: guess.client,
        category: guess.category,
        confidence: guess.confidence, // high / medium / low
        reason: guess.reason,
      };
    })
    .sort((a, b) => a.start.localeCompare(b.start));
}

/**
 * イベント情報から顧客名とカテゴリを推測
 */
function guessClientAndCategory(title, organizer, guests, description, knownMappings) {
  let client = '';
  let category = '';
  let confidence = 'low';
  let reason = '';

  // 1. [顧客名] プレフィックス（最優先）
  const bracketMatch = title.match(/^\[(.+?)\]/);
  if (bracketMatch) {
    client = bracketMatch[1].trim();
    confidence = 'high';
    reason = 'タイトルのタグ';
  }

  // 2. 過去の確定データからタイトルで照合
  if (!client && knownMappings) {
    const normalized = title.replace(/[\s　]+/g, '').toLowerCase();
    for (const [key, val] of Object.entries(knownMappings)) {
      if (normalized.includes(key.toLowerCase())) {
        client = val;
        confidence = 'medium';
        reason = '過去の確定データ';
        break;
      }
    }
  }

  // 3. 外部ゲスト・主催者のドメインから推測
  if (!client) {
    const externalDomains = [];
    const allEmails = [organizer, ...guests].filter(Boolean);
    for (const email of allEmails) {
      const domain = email.split('@')[1];
      if (domain && domain !== CONFIG.COMPANY_DOMAIN && !domain.includes('google.com') && !domain.includes('gmail.com')) {
        externalDomains.push(domain);
      }
    }
    if (externalDomains.length > 0) {
      // ドメインから社名を推測（xxx.co.jp → xxx）
      const domain = externalDomains[0];
      client = domain.split('.')[0];
      // 頭文字大文字化
      client = client.charAt(0).toUpperCase() + client.slice(1);
      confidence = 'medium';
      reason = `外部ドメイン: ${domain}`;
    }
  }

  // 4. タイトルのキーワードから顧客名っぽい部分を抽出
  if (!client) {
    // 「○○様」「○○さん」パターン
    const nameMatch = title.match(/(.+?)[様さん]\s/);
    if (nameMatch) {
      client = nameMatch[1].trim();
      confidence = 'low';
      reason = 'タイトルの敬称';
    }
  }

  // 5. デフォルト
  if (!client) {
    client = '（未分類）';
    confidence = 'low';
    reason = '自動推測不可';
  }

  // カテゴリ推測
  for (const rule of CATEGORY_RULES) {
    if (rule.pattern.test(title) || rule.pattern.test(description)) {
      category = rule.category;
      break;
    }
  }
  if (!category) category = 'その他';

  return { client, category, confidence, reason };
}

/**
 * 過去に確定されたタイトル→顧客マッピングを読み込む
 */
function loadKnownMappings_() {
  const uid = hashUid(Session.getActiveUser().getEmail() || Session.getEffectiveUser().getEmail());
  try {
    const url = `${CONFIG.SUPABASE_URL}/storage/v1/object/${CONFIG.BUCKET}/${uid}/mappings.json`;
    const res = UrlFetchApp.fetch(url, {
      headers: { 'Authorization': `Bearer ${CONFIG.SUPABASE_KEY}`, 'apikey': CONFIG.SUPABASE_KEY },
      muteHttpExceptions: true,
    });
    if (res.getResponseCode() === 200) {
      return JSON.parse(res.getContentText());
    }
  } catch (e) { /* no mappings yet */ }
  return {};
}

/**
 * 確定時にマッピングを学習・保存
 */
function saveKnownMappings_(uid, entries) {
  // 既存マッピング読み込み
  let mappings = {};
  try {
    const url = `${CONFIG.SUPABASE_URL}/storage/v1/object/${CONFIG.BUCKET}/${uid}/mappings.json`;
    const res = UrlFetchApp.fetch(url, {
      headers: { 'Authorization': `Bearer ${CONFIG.SUPABASE_KEY}`, 'apikey': CONFIG.SUPABASE_KEY },
      muteHttpExceptions: true,
    });
    if (res.getResponseCode() === 200) mappings = JSON.parse(res.getContentText());
  } catch (e) { /* new file */ }

  // 新しいマッピング追加（タイトルの主要キーワード → 顧客名）
  for (const e of entries) {
    if (e.client && e.client !== '（未分類）') {
      // タイトルから固有名詞的な部分を抽出してキーに
      const key = e.title.replace(/[\[\]]/g, '').replace(/[\s　]+/g, '').substring(0, 20);
      if (key.length >= 3) {
        mappings[key] = e.client;
      }
    }
  }

  // 保存（最大200件、古いものから削除）
  const keys = Object.keys(mappings);
  if (keys.length > 200) {
    const excess = keys.slice(0, keys.length - 200);
    for (const k of excess) delete mappings[k];
  }

  uploadToSupabase(`${uid}/mappings.json`, JSON.stringify(mappings, null, 2), 'application/json');
}

// ========== 確定処理 ==========

/**
 * 確認画面から呼ばれる: 修正済みデータを受け取って確定保存
 */
function confirmWorklog(dateStr, entriesJson) {
  const entries = JSON.parse(entriesJson);
  const email = Session.getActiveUser().getEmail() || Session.getEffectiveUser().getEmail();
  const uid = hashUid(email);
  const name = extractName(email);

  // 非稼働を除外した集計
  const workEntries = entries.filter(e => e.category !== '非稼働');

  // 日報MD生成
  const md = buildConfirmedMd(dateStr, email, name, workEntries);

  // 構造化JSON生成
  const summary = buildConfirmedJson(dateStr, email, uid, name, workEntries);

  // Supabaseアップロード
  uploadToSupabase(`${uid}/worklogs/${dateStr}.md`, md, 'text/markdown');
  uploadToSupabase(`${uid}/worklogs/${dateStr}.json`, JSON.stringify(summary, null, 2), 'application/json');

  // プロファイル最新化
  uploadToSupabase(`${uid}/profile.json`, JSON.stringify({
    uid, email, name, updated_at: new Date().toISOString(),
  }), 'application/json');

  // マッピング学習
  saveKnownMappings_(uid, entries);

  return { success: true, date: dateStr, entries: workEntries.length };
}

function buildConfirmedMd(date, email, name, entries) {
  const byClient = {};
  for (const e of entries) {
    const c = e.client || '（未分類）';
    if (!byClient[c]) byClient[c] = { min: 0, items: [] };
    byClient[c].min += e.duration_min;
    byClient[c].items.push(e);
  }
  const totalMin = entries.reduce((s, e) => s + e.duration_min, 0);
  const totalH = Math.round(totalMin / 60 * 10) / 10;

  let md = `# 日報 ${date}（確定）\n\n`;
  md += `- **担当者**: ${name}（${email}）\n`;
  md += `- **合計稼働**: ${totalH}h（${totalMin}分）\n`;
  md += `- **確定日時**: ${new Date().toISOString()}\n\n`;

  md += `## 顧客別サマリー\n\n`;
  md += `| 顧客 | 時間 | 件数 | 構成比 |\n`;
  md += `|------|------|------|--------|\n`;
  const clients = Object.keys(byClient).sort((a, b) => byClient[b].min - byClient[a].min);
  for (const c of clients) {
    const h = Math.round(byClient[c].min / 60 * 10) / 10;
    const pct = totalMin > 0 ? Math.round(byClient[c].min / totalMin * 100) : 0;
    md += `| ${c} | ${h}h | ${byClient[c].items.length}件 | ${pct}% |\n`;
  }

  md += `\n## タイムライン\n\n`;
  for (const e of entries) {
    md += `- ${e.start}-${e.end} | **${e.client}** | ${e.title} (${e.duration_h}h)\n`;
  }

  md += `\n---\n> 確定済み日報（メンバー確認済み）\n`;
  return md;
}

function buildConfirmedJson(date, email, uid, name, entries) {
  const byClient = {};
  const byCat = {};
  for (const e of entries) {
    const c = e.client || '（未分類）';
    const cat = e.category || 'その他';
    if (!byClient[c]) byClient[c] = { min: 0, count: 0 };
    byClient[c].min += e.duration_min;
    byClient[c].count += 1;
    if (!byCat[cat]) byCat[cat] = { min: 0, count: 0 };
    byCat[cat].min += e.duration_min;
    byCat[cat].count += 1;
  }
  const totalMin = entries.reduce((s, e) => s + e.duration_min, 0);

  return {
    date, uid, email, name,
    status: 'confirmed',
    total_hours: Math.round(totalMin / 60 * 10) / 10,
    total_minutes: totalMin,
    event_count: entries.length,
    confirmed_at: new Date().toISOString(),
    clients: Object.entries(byClient).map(([n, d]) => ({
      name: n, hours: Math.round(d.min / 60 * 10) / 10, minutes: d.min, count: d.count,
    })).sort((a, b) => b.minutes - a.minutes),
    categories: Object.entries(byCat).map(([n, d]) => ({
      name: n, hours: Math.round(d.min / 60 * 10) / 10, minutes: d.min, count: d.count,
    })).sort((a, b) => b.minutes - a.minutes),
    timeline: entries.map(e => ({
      start: e.start, end: e.end, hours: e.duration_h,
      client: e.client, category: e.category, title: e.title,
    })),
  };
}

// ========== Supabase ==========

function uploadToSupabase(path, content, contentType) {
  const url = `${CONFIG.SUPABASE_URL}/storage/v1/object/${CONFIG.BUCKET}/${path}`;
  const res = UrlFetchApp.fetch(url, {
    method: 'post',
    contentType: contentType || 'application/octet-stream',
    headers: {
      'Authorization': `Bearer ${CONFIG.SUPABASE_KEY}`,
      'apikey': CONFIG.SUPABASE_KEY,
      'x-upsert': 'true',
    },
    payload: content,
    muteHttpExceptions: true,
  });
  if (res.getResponseCode() >= 300) {
    throw new Error(`Supabase upload failed (${res.getResponseCode()}): ${res.getContentText()}`);
  }
}

// ========== ユーティリティ ==========

function hashUid(email) {
  const raw = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, email);
  return raw.map(b => ('0' + ((b + 256) % 256).toString(16)).slice(-2)).join('').substring(0, 8);
}

function extractName(email) {
  const local = email.split('@')[0];
  return local.split(/[._-]/).map(s => s.charAt(0).toUpperCase() + s.slice(1)).join(' ');
}

// ========== トリガー ==========

function setupTrigger() {
  const triggers = ScriptApp.getProjectTriggers();
  for (const t of triggers) {
    if (t.getHandlerFunction() === 'dailyRun') ScriptApp.deleteTrigger(t);
  }
  ScriptApp.newTrigger('dailyRun').timeBased().everyDays(1).atHour(9).create();
  Logger.log('✅ 日次トリガー設定（毎朝9時）');
}

/**
 * 毎朝実行: 前日分の確認リンクをメール送信
 */
function dailyRun() {
  const yesterday = new Date();
  yesterday.setDate(yesterday.getDate() - 1);
  const dateStr = Utilities.formatDate(yesterday, CONFIG.TIMEZONE, 'yyyy-MM-dd');
  const email = Session.getEffectiveUser().getEmail();

  const webAppUrl = ScriptApp.getService().getUrl();
  const link = `${webAppUrl}?date=${dateStr}`;

  MailApp.sendEmail({
    to: email,
    subject: `[AXトラッカー] ${dateStr} の日報を確認してください`,
    htmlBody: `
      <div style="font-family:sans-serif;max-width:500px;">
        <h2 style="color:#1a56db;">日報確認のお願い</h2>
        <p>${dateStr} のGoogleカレンダーから日報ドラフトを生成しました。</p>
        <p>以下のリンクから内容を確認し、顧客名が正しいか確認してください。</p>
        <a href="${link}" style="display:inline-block;padding:12px 32px;background:#1a56db;color:white;text-decoration:none;border-radius:8px;font-weight:bold;margin:16px 0;">日報を確認する</a>
        <p style="color:#999;font-size:12px;">このメールはAX事業部トラッカーから自動送信されています。</p>
      </div>
    `,
  });
  Logger.log(`✅ ${email} に確認リンクを送信: ${link}`);
}

// ========== Web App ==========

function doGet(e) {
  const date = e.parameter.date || Utilities.formatDate(new Date(), CONFIG.TIMEZONE, 'yyyy-MM-dd');
  const entries = getCalendarEntries(date);
  const email = Session.getActiveUser().getEmail();
  const name = extractName(email);

  const html = HtmlService.createHtmlOutput(buildConfirmPage_(date, name, email, entries))
    .setTitle(`日報確認 ${date}`)
    .setXFrameOptionsMode(HtmlService.XFrameOptionsMode.ALLOWALL);
  return html;
}

function doPost(e) {
  try {
    const data = JSON.parse(e.postData.contents);
    const result = confirmWorklog(data.date, JSON.stringify(data.entries));
    return ContentService.createTextOutput(JSON.stringify(result)).setMimeType(ContentService.MimeType.JSON);
  } catch (err) {
    return ContentService.createTextOutput(JSON.stringify({ error: err.message })).setMimeType(ContentService.MimeType.JSON);
  }
}

// ========== 確認画面HTML ==========

function buildConfirmPage_(date, name, email, entries) {
  const entriesJson = JSON.stringify(entries).replace(/</g, '\\u003c').replace(/>/g, '\\u003e');

  return `<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>
  :root { --blue: #1a56db; --blue-dark: #0c2d6b; --green: #27ae60; --orange: #e67e22; --red: #e74c3c; --gray: #6b7280; --light: #f3f4f6; }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: -apple-system, 'Hiragino Sans', sans-serif; background: #f9fafb; color: #1f2937; }
  .header { background: linear-gradient(135deg, var(--blue-dark), var(--blue)); color: white; padding: 24px 32px; }
  .header h1 { font-size: 20px; }
  .header .sub { font-size: 13px; opacity: 0.8; margin-top: 4px; }
  .container { max-width: 800px; margin: 0 auto; padding: 24px 16px; }
  .summary { background: white; border-radius: 12px; padding: 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); margin-bottom: 20px; }
  .summary .row { display: flex; gap: 24px; flex-wrap: wrap; }
  .summary .item { }
  .summary .label { font-size: 12px; color: var(--gray); }
  .summary .val { font-size: 24px; font-weight: 700; }
  .summary .val .unit { font-size: 14px; font-weight: 400; }
  .entry { background: white; border-radius: 10px; padding: 16px 20px; margin-bottom: 12px; box-shadow: 0 1px 2px rgba(0,0,0,0.06); border-left: 4px solid var(--blue); transition: border-color 0.2s; }
  .entry.high { border-left-color: var(--green); }
  .entry.medium { border-left-color: var(--orange); }
  .entry.low { border-left-color: var(--red); }
  .entry .time { font-size: 13px; color: var(--gray); font-weight: 500; }
  .entry .title { font-size: 15px; font-weight: 600; margin: 4px 0; }
  .entry .meta { font-size: 12px; color: var(--gray); margin-bottom: 8px; }
  .entry .fields { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
  .entry label { font-size: 11px; color: var(--gray); font-weight: 500; display: block; margin-bottom: 2px; }
  .entry input, .entry select {
    width: 100%; padding: 6px 10px; border: 1px solid #e5e7eb; border-radius: 6px;
    font-size: 14px; font-family: inherit;
  }
  .entry input:focus, .entry select:focus { outline: none; border-color: var(--blue); box-shadow: 0 0 0 2px rgba(26,86,219,0.15); }
  .confidence { display: inline-block; font-size: 10px; padding: 2px 8px; border-radius: 10px; font-weight: 600; }
  .confidence.high { background: #dcfce7; color: #166534; }
  .confidence.medium { background: #fef3c7; color: #92400e; }
  .confidence.low { background: #fee2e2; color: #991b1b; }
  .actions { position: sticky; bottom: 0; background: white; padding: 16px 20px; border-top: 1px solid #e5e7eb; text-align: center; box-shadow: 0 -2px 8px rgba(0,0,0,0.05); }
  .btn { padding: 12px 40px; border-radius: 8px; font-size: 15px; font-weight: 700; border: none; cursor: pointer; transition: all 0.2s; }
  .btn-confirm { background: var(--blue); color: white; }
  .btn-confirm:hover { background: var(--blue-dark); }
  .btn-confirm:disabled { background: #9ca3af; cursor: not-allowed; }
  .done { text-align: center; padding: 48px; }
  .done h2 { color: var(--green); margin-bottom: 8px; }
  .skip-check { display: flex; align-items: center; gap: 4px; font-size: 12px; color: var(--gray); margin-top: 8px; justify-content: center; }
  .skip-check input { width: auto; }
</style>
</head>
<body>

<div class="header">
  <h1>日報確認 — ${date}</h1>
  <div class="sub">${name}（${email}）</div>
</div>

<div class="container" id="main">
  <div class="summary">
    <div class="row">
      <div class="item"><div class="label">予定数</div><div class="val" id="sumCount">--</div></div>
      <div class="item"><div class="label">合計時間</div><div class="val" id="sumHours">--<span class="unit">h</span></div></div>
      <div class="item"><div class="label">顧客数</div><div class="val" id="sumClients">--</div></div>
      <div class="item"><div class="label">推測精度</div><div class="val" id="sumConf">--</div></div>
    </div>
  </div>

  <div id="entries"></div>
</div>

<div class="actions" id="actionsBar">
  <button class="btn btn-confirm" id="confirmBtn" onclick="submitConfirm()">この内容で確定する</button>
  <div class="skip-check">
    <input type="checkbox" id="skipNonWork">
    <label for="skipNonWork">「非稼働」カテゴリは除外して集計</label>
  </div>
</div>

<div class="done" id="doneMsg" style="display:none;">
  <h2>確定しました</h2>
  <p>ダッシュボードに反映されます。</p>
  <p style="margin-top:16px;"><a href="https://ax-tracker.vercel.app" style="color:var(--blue);">ダッシュボードを開く →</a></p>
</div>

<script>
const DATE = '${date}';
let entries = ${entriesJson};

const CATEGORIES = ['AI導入支援','研修','制作/開発','AI講座','社内MTG','1on1','営業','事務・管理','非稼働','その他'];

function render() {
  const container = document.getElementById('entries');
  container.innerHTML = entries.map((e, i) => {
    const confClass = e.confidence || 'low';
    const confLabel = { high: '確度高', medium: '確度中', low: '確度低' }[confClass] || '確度低';
    return '<div class="entry ' + confClass + '">' +
      '<div class="time">' + e.start + ' - ' + e.end + '（' + e.duration_h + 'h）' +
        ' <span class="confidence ' + confClass + '">' + confLabel + '</span>' +
        (e.reason ? ' <span style="font-size:11px;color:#9ca3af;">' + e.reason + '</span>' : '') +
      '</div>' +
      '<div class="title">' + esc(e.title) + '</div>' +
      '<div class="meta">' + (e.organizer ? '主催: ' + esc(e.organizer) : '') + (e.guests > 0 ? ' / 参加者' + e.guests + '名' : '') + '</div>' +
      '<div class="fields">' +
        '<div><label>顧客名</label><input type="text" value="' + esc(e.client) + '" onchange="entries[' + i + '].client=this.value;updateSummary()"></div>' +
        '<div><label>カテゴリ</label><select onchange="entries[' + i + '].category=this.value;updateSummary()">' +
          CATEGORIES.map(c => '<option' + (c === e.category ? ' selected' : '') + '>' + c + '</option>').join('') +
        '</select></div>' +
      '</div>' +
    '</div>';
  }).join('');
  updateSummary();
}

function updateSummary() {
  const work = entries.filter(e => e.category !== '非稼働');
  const totalH = work.reduce((s, e) => s + e.duration_h, 0);
  const clients = new Set(work.map(e => e.client).filter(c => c && c !== '（未分類）'));
  const highConf = entries.filter(e => e.confidence === 'high').length;
  const pct = entries.length > 0 ? Math.round(highConf / entries.length * 100) : 0;

  document.getElementById('sumCount').textContent = entries.length;
  document.getElementById('sumHours').innerHTML = (Math.round(totalH * 10) / 10) + '<span class="unit">h</span>';
  document.getElementById('sumClients').textContent = clients.size;
  document.getElementById('sumConf').textContent = pct + '%';
}

function submitConfirm() {
  const btn = document.getElementById('confirmBtn');
  btn.disabled = true;
  btn.textContent = '送信中...';

  google.script.run
    .withSuccessHandler(function(result) {
      document.getElementById('main').style.display = 'none';
      document.getElementById('actionsBar').style.display = 'none';
      document.getElementById('doneMsg').style.display = 'block';
    })
    .withFailureHandler(function(err) {
      alert('エラー: ' + err.message);
      btn.disabled = false;
      btn.textContent = 'この内容で確定する';
    })
    .confirmWorklog(DATE, JSON.stringify(entries));
}

function esc(s) { return String(s || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }

render();
</script>
</body>
</html>`;
}
