// Opt-in transcript fixes (decisions.md 2026-11-02 "transcript fixes").
// The app sends scrubbed "Fix a misheard term" pairs; the weekly improve
// workflow reads the summary (pairs taught on MIN_INSTALLS+ Macs) and
// proposes additions to the bundled common_corrections.json. Every pair is
// re-scrubbed here with the same rules as the app (TranscriptFixScrub) and
// the merge script; tests/transcripts/scrub_cases.json keeps all three equal.

export const MAX_TRANSCRIPT_FIX_BYTES = 64 * 1024;
export const RETENTION_SECONDS = 180 * 24 * 60 * 60;
export const MIN_INSTALLS = 3;
export const MAX_WORDS = 5;
export const MAX_CHARS = 60;
const MAX_FIXES_PER_REPORT = 200;
const UUID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/i;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const VERSION = /^\d{1,4}(\.\d{1,4}){0,3}$/;
const LANGUAGE = /^([a-z]{2,3}(-[A-Za-z]{2,4})?|auto)$/;
const ENGINES = new Set(["", "parakeetV2", "parakeetV3", "sfSpeech"]);
const DAY_MS = 24 * 60 * 60 * 1000;

// Same as TranscriptFixScrub.personalPatterns (Swift) and PERSONAL (merge script).
export const PERSONAL = [
  /[\x00-\x1f\x7f<>]/,
  /[^\s@]+@[^\s@]+\.[^\s@]+/,
  /\b(https?:\/\/|www\.)/i,
  /\b[a-z0-9-]+\.(com|net|org|io|app|ai|co|dev|me|us|uk|de)\b/i,
  /\d[\d\s.,-]{2,}\d/,
  /\d{4,}/,
  /\b(sk|pk|rk|ghp|gho|xox[abp]|akia)[-_][A-Za-z0-9]/i,
  /[A-Za-z0-9_\-]{24,}/,
  /\b(?=[A-Za-z0-9]*\d)(?=[A-Za-z0-9]*[A-Za-z])[A-Za-z0-9]{12,}\b/,
];

export function collapse(text) {
  return String(text).split(/\s+/).filter(Boolean).join(" ");
}

export function shareable(text) {
  return text.length > 0 && [...text].length <= MAX_CHARS && /\p{L}/u.test(text)
    && text.split(" ").length <= MAX_WORDS && !PERSONAL.some((p) => p.test(text));
}

/** { heard, corrected } collapsed, or null when the pair may not be stored. */
export function scrubPair(heard, corrected) {
  if (typeof heard !== "string" || typeof corrected !== "string") return null;
  const h = collapse(heard), c = collapse(corrected);
  if (h === c || !shareable(h) || !shareable(c)) return null;
  return { heard: h, corrected: c };
}

/** Returns { report } or { error }. Unknown fields are rejected; unshareable pairs are dropped. */
export function validateTranscriptFixReport(body, now = new Date()) {
  if (!body || typeof body !== "object" || Array.isArray(body)) return { error: "Invalid report." };
  if (Object.keys(body).some((k) => !["installId", "appVersion", "fixes"].includes(k))) {
    return { error: "Unexpected field." };
  }
  if (typeof body.installId !== "string" || !UUID.test(body.installId)) return { error: "Invalid install id." };
  if (typeof body.appVersion !== "string" || !VERSION.test(body.appVersion)) return { error: "Invalid app version." };
  if (!Array.isArray(body.fixes) || body.fixes.length === 0 || body.fixes.length > MAX_FIXES_PER_REPORT) {
    return { error: "Invalid fixes." };
  }
  const earliest = new Date(now.getTime() - 60 * DAY_MS).toISOString().slice(0, 10);
  const latest = new Date(now.getTime() + DAY_MS).toISOString().slice(0, 10);
  const fixes = [];
  const seen = new Set();
  for (const f of body.fixes) {
    if (!f || typeof f !== "object" || Array.isArray(f)) return { error: "Invalid fix." };
    if (Object.keys(f).some((k) => !["fixId", "day", "heard", "corrected", "engine", "language"].includes(k))) {
      return { error: "Unexpected fix field." };
    }
    if (typeof f.fixId !== "string" || !UUID.test(f.fixId)) return { error: "Invalid fix id." };
    if (typeof f.day !== "string" || !DAY.test(f.day) || Number.isNaN(Date.parse(f.day))) return { error: "Invalid day." };
    if (f.day < earliest || f.day > latest) return { error: "Day out of range." };
    if (typeof f.engine !== "string" || !ENGINES.has(f.engine)) return { error: "Invalid engine." };
    if (typeof f.language !== "string" || (f.language !== "" && !LANGUAGE.test(f.language))) {
      return { error: "Invalid language." };
    }
    const pair = scrubPair(f.heard, f.corrected);
    if (!pair) continue; // dropped whole, like the app does
    const key = `${pair.heard.toLowerCase()}\u0000${pair.corrected}`;
    if (seen.has(key)) continue;
    seen.add(key);
    fixes.push({ ...pair, heardKey: pair.heard.toLowerCase(), engine: f.engine, language: f.language, day: f.day });
  }
  return { report: { installId: body.installId.toLowerCase(), appVersion: body.appVersion, fixes } };
}

/** Upsert per install + pair: re-sending a fix never counts twice. */
export async function storeTranscriptFixes(db, report, nowSeconds = Math.floor(Date.now() / 1000)) {
  if (report.fixes.length === 0) return;
  const statement = db.prepare(
    `INSERT INTO transcript_fixes
     (install_id, heard_key, heard, corrected, engine, language, day, app_version, received_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
     ON CONFLICT (install_id, heard_key, corrected) DO UPDATE SET
       heard = excluded.heard, engine = excluded.engine, language = excluded.language,
       day = excluded.day, app_version = excluded.app_version, received_at = excluded.received_at`,
  );
  await db.batch(report.fixes.map((f) => statement.bind(
    report.installId, f.heardKey, f.heard, f.corrected, f.engine, f.language, f.day,
    report.appVersion, nowSeconds,
  )));
}

export async function deleteTranscriptFixes(db, installId) {
  await db.prepare("DELETE FROM transcript_fixes WHERE install_id = ?1").bind(installId.toLowerCase()).run();
}

export async function purgeOldTranscriptFixes(db, nowSeconds = Math.floor(Date.now() / 1000)) {
  await db.prepare("DELETE FROM transcript_fixes WHERE received_at < ?1")
    .bind(nowSeconds - RETENTION_SECONDS).run();
}

/**
 * Pairs taught on at least `minInstalls` different Macs, with the languages
 * and engines they came from. Never install ids. Pure over rows for tests.
 */
export function summarizeTranscriptFixes(rows, minInstalls = MIN_INSTALLS, now = new Date()) {
  const groups = new Map();
  for (const r of rows) {
    const key = `${r.heard_key}\u0000${r.corrected}`;
    if (!groups.has(key)) {
      groups.set(key, { heard: r.heard, corrected: r.corrected, installs: new Set(), languages: new Set(), engines: new Set() });
    }
    const g = groups.get(key);
    g.installs.add(r.install_id);
    g.languages.add(r.language ?? "");
    g.engines.add(r.engine ?? "");
  }
  const pairs = [...groups.values()]
    .filter((g) => g.installs.size >= minInstalls)
    .map((g) => ({
      heard: g.heard,
      corrected: g.corrected,
      installs: g.installs.size,
      languages: [...g.languages].sort().join(","),
      engines: [...g.engines].filter(Boolean).sort().join(","),
    }))
    .sort((a, b) => b.installs - a.installs || a.heard.localeCompare(b.heard));
  return { generatedAt: now.toISOString(), minInstalls, pairs };
}

export async function transcriptFixSummary(db) {
  const result = await db.prepare(
    "SELECT install_id, heard_key, heard, corrected, engine, language FROM transcript_fixes",
  ).all();
  return summarizeTranscriptFixes(result?.results ?? []);
}
