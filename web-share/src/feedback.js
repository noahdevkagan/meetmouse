// Opt-in coaching feedback (decisions.md 2026-11-02 "coaching feedback").
// The app sends rated nudges as ids and numbers only; the weekly improve
// workflow reads the per-signal summary and proposes threshold tweaks.
// Pure helpers are exported for tests.

export const MAX_FEEDBACK_BYTES = 64 * 1024;
export const RETENTION_SECONDS = 180 * 24 * 60 * 60;
/** A signal shows in the summary only once this many installs rated it. */
export const MIN_INSTALLS = 5;
const MAX_EVENTS_PER_REPORT = 500;
const UUID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/i;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const VERSION = /^\d{1,4}(\.\d{1,4}){0,3}$/;
const DAY_MS = 24 * 60 * 60 * 1000;

// Built-in signal keys (NudgeType raw values). User-authored rubric signals
// are reported as the bare word "custom": their ids are user text.
export const SIGNALS = new Set([
  "talkTime", "missingDiscovery", "timeCheck", "repetitionLoop", "stackedQuestions", "nextSteps",
  "goingQuiet", "yesMan", "unansweredQuestion", "interruption", "commitmentGap", "droppedThread",
  "priceFlinch", "vagueAnswer", "overrun", "voiceShare", "questionParked", "questionLanded",
  "ownershipHanded", "refocused", "commitmentLocked", "reflectedBack", "noDecision",
  "alignmentReached", "buriedSignal", "hedgeNotPinned", "custom",
]);
export const RATINGS = new Set(["useful", "annoying", "wrong"]);
const MEETING_TYPES = new Set(["general", "oneOnOne", "salesCall", "teamMeeting"]);
export const FEATURES = ["youShare", "lastYouTurnSec", "turnsSoFar"];

function optionalNumber(value, min, max, integer = false) {
  if (value === undefined || value === null) return { value: null };
  if (typeof value !== "number" || !Number.isFinite(value)) return { error: true };
  if (integer && !Number.isInteger(value)) return { error: true };
  if (value < min) return { error: true };
  return { value: Math.min(value, max) };
}

/** Returns { report } with clamped values, or { error }. Unknown fields are rejected. */
export function validateFeedbackReport(body, now = new Date()) {
  if (!body || typeof body !== "object" || Array.isArray(body)) return { error: "Invalid report." };
  if (Object.keys(body).some((k) => !["installId", "appVersion", "events"].includes(k))) {
    return { error: "Unexpected field." };
  }
  if (typeof body.installId !== "string" || !UUID.test(body.installId)) return { error: "Invalid install id." };
  if (typeof body.appVersion !== "string" || !VERSION.test(body.appVersion)) return { error: "Invalid app version." };
  if (!Array.isArray(body.events) || body.events.length === 0 || body.events.length > MAX_EVENTS_PER_REPORT) {
    return { error: "Invalid events." };
  }
  const earliest = new Date(now.getTime() - 60 * DAY_MS).toISOString().slice(0, 10);
  const latest = new Date(now.getTime() + DAY_MS).toISOString().slice(0, 10);
  const seen = new Set();
  const events = [];
  for (const e of body.events) {
    if (!e || typeof e !== "object" || Array.isArray(e)) return { error: "Invalid event." };
    if (Object.keys(e).some((k) => !["eventId", "day", "signal", "rating", "minute", "meetingType", "features"].includes(k))) {
      return { error: "Unexpected event field." };
    }
    if (typeof e.eventId !== "string" || !UUID.test(e.eventId)) return { error: "Invalid event id." };
    const eventId = e.eventId.toLowerCase();
    if (seen.has(eventId)) return { error: "Duplicate event." };
    seen.add(eventId);
    if (typeof e.day !== "string" || !DAY.test(e.day) || Number.isNaN(Date.parse(e.day))) return { error: "Invalid day." };
    if (e.day < earliest || e.day > latest) return { error: "Day out of range." };
    if (typeof e.signal !== "string" || !SIGNALS.has(e.signal)) return { error: "Unknown signal." };
    if (typeof e.rating !== "string" || !RATINGS.has(e.rating)) return { error: "Invalid rating." };
    if (!Number.isInteger(e.minute) || e.minute < 0) return { error: "Invalid minute." };
    if (typeof e.meetingType !== "string" || !MEETING_TYPES.has(e.meetingType)) return { error: "Invalid meeting type." };
    const f = e.features ?? {};
    if (typeof f !== "object" || Array.isArray(f) || Object.keys(f).some((k) => !FEATURES.includes(k))) {
      return { error: "Unexpected feature." };
    }
    const youShare = optionalNumber(f.youShare, 0, 1);
    const lastYouTurnSec = optionalNumber(f.lastYouTurnSec, 0, 3600);
    const turnsSoFar = optionalNumber(f.turnsSoFar, 0, 5000, true);
    if (youShare.error || lastYouTurnSec.error || turnsSoFar.error || f.youShare > 1) {
      return { error: "Invalid feature." };
    }
    events.push({
      eventId, day: e.day, signal: e.signal, rating: e.rating,
      minute: Math.min(e.minute, 600), meetingType: e.meetingType,
      youShare: youShare.value, lastYouTurnSec: lastYouTurnSec.value, turnsSoFar: turnsSoFar.value,
    });
  }
  return { report: { installId: body.installId.toLowerCase(), appVersion: body.appVersion, events } };
}

/** Insert-or-ignore by event id: a resent batch never double counts. */
export async function storeFeedback(db, report, nowSeconds = Math.floor(Date.now() / 1000)) {
  const statement = db.prepare(
    `INSERT OR IGNORE INTO feedback_events
     (event_id, install_id, day, signal, rating, minute, meeting_type,
      you_share, last_you_turn_sec, turns_so_far, app_version, received_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)`,
  );
  await db.batch(report.events.map((e) => statement.bind(
    e.eventId, report.installId, e.day, e.signal, e.rating, e.minute, e.meetingType,
    e.youShare, e.lastYouTurnSec, e.turnsSoFar, report.appVersion, nowSeconds,
  )));
}

export async function deleteFeedback(db, installId) {
  await db.prepare("DELETE FROM feedback_events WHERE install_id = ?1").bind(installId.toLowerCase()).run();
}

export async function purgeOldFeedback(db, nowSeconds = Math.floor(Date.now() / 1000)) {
  await db.prepare("DELETE FROM feedback_events WHERE received_at < ?1")
    .bind(nowSeconds - RETENTION_SECONDS).run();
}

function quantile(sorted, q) {
  if (sorted.length === 0) return null;
  const pos = (sorted.length - 1) * q;
  const lo = Math.floor(pos), hi = Math.ceil(pos);
  const v = sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
  return Math.round(v * 1000) / 1000;
}

function distribution(values) {
  const sorted = values.filter((v) => v !== null && v !== undefined).map(Number).sort((a, b) => a - b);
  return { n: sorted.length, p25: quantile(sorted, 0.25), median: quantile(sorted, 0.5), p75: quantile(sorted, 0.75) };
}

/**
 * Per-signal helpful rate and feature distributions (helpful = "useful",
 * not helpful = "annoying" or "wrong"). Pure over rows so tests can feed it.
 * Signals rated by fewer than MIN_INSTALLS installs are left out entirely.
 */
export function summarizeFeedback(rows, minInstalls = MIN_INSTALLS) {
  const bySignal = new Map();
  for (const r of rows) {
    if (!bySignal.has(r.signal)) bySignal.set(r.signal, []);
    bySignal.get(r.signal).push(r);
  }
  const signals = [];
  for (const [signal, list] of [...bySignal.entries()].sort(([a], [b]) => a.localeCompare(b))) {
    const installs = new Set(list.map((r) => r.install_id)).size;
    if (installs < minInstalls) continue;
    const helpful = list.filter((r) => r.rating === "useful");
    const notHelpful = list.filter((r) => r.rating !== "useful");
    const features = {};
    for (const [name, column] of [["youShare", "you_share"], ["lastYouTurnSec", "last_you_turn_sec"], ["turnsSoFar", "turns_so_far"], ["minute", "minute"]]) {
      features[name] = {
        helpful: distribution(helpful.map((r) => r[column])),
        notHelpful: distribution(notHelpful.map((r) => r[column])),
      };
    }
    signals.push({
      signal,
      installs,
      ratings: list.length,
      useful: helpful.length,
      annoying: list.filter((r) => r.rating === "annoying").length,
      wrong: list.filter((r) => r.rating === "wrong").length,
      helpfulRate: Math.round((helpful.length / list.length) * 1000) / 1000,
      features,
    });
  }
  return { minInstalls, signals };
}

export async function feedbackSummary(db) {
  const result = await db.prepare(
    `SELECT install_id, signal, rating, minute, you_share, last_you_turn_sec, turns_so_far
     FROM feedback_events`,
  ).all();
  return summarizeFeedback(result?.results ?? []);
}
