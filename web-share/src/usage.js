// Opt-in anonymous usage counts (decisions.md 2026-11-02) and the aggregate
// totals the website's stat strip reads. Pure helpers are exported for tests.

export const MAX_USAGE_BYTES = 16 * 1024;
const MAX_DAYS_PER_REPORT = 60;
const LIMITS = { meetings: 50, meetingMinutes: 24 * 60, nudges: 2000 };
const INSTALL_ID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/i;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const VERSION = /^\d{1,4}(\.\d{1,4}){0,3}$/;
const DAY_MS = 24 * 60 * 60 * 1000;

export function dayString(date) {
  return date.toISOString().slice(0, 10);
}

function count(value, max) {
  if (!Number.isInteger(value) || value < 0) return null;
  return Math.min(value, max);
}

/**
 * Validates a report and returns { report } with clamped values, or { error }.
 * Days older than 60 days or more than a day in the future are rejected:
 * the app only holds unsent days for a short window.
 */
export function validateUsageReport(body, now = new Date()) {
  if (!body || typeof body !== "object" || Array.isArray(body)) return { error: "Invalid report." };
  const allowed = new Set(["installId", "appVersion", "osMajor", "days"]);
  if (Object.keys(body).some((key) => !allowed.has(key))) return { error: "Unexpected field." };
  if (typeof body.installId !== "string" || !INSTALL_ID.test(body.installId)) {
    return { error: "Invalid install id." };
  }
  if (typeof body.appVersion !== "string" || !VERSION.test(body.appVersion)) {
    return { error: "Invalid app version." };
  }
  if (!Number.isInteger(body.osMajor) || body.osMajor < 10 || body.osMajor > 99) {
    return { error: "Invalid macOS version." };
  }
  if (!Array.isArray(body.days) || body.days.length === 0 || body.days.length > MAX_DAYS_PER_REPORT) {
    return { error: "Invalid days." };
  }
  const earliest = dayString(new Date(now.getTime() - MAX_DAYS_PER_REPORT * DAY_MS));
  const latest = dayString(new Date(now.getTime() + DAY_MS));
  const seen = new Set();
  const days = [];
  for (const entry of body.days) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) return { error: "Invalid day." };
    const keys = Object.keys(entry);
    if (keys.some((key) => !["day", "meetings", "meetingMinutes", "nudges"].includes(key))) {
      return { error: "Unexpected day field." };
    }
    if (typeof entry.day !== "string" || !DAY.test(entry.day) || Number.isNaN(Date.parse(entry.day))) {
      return { error: "Invalid day." };
    }
    if (entry.day < earliest || entry.day > latest) return { error: "Day out of range." };
    if (seen.has(entry.day)) return { error: "Duplicate day." };
    seen.add(entry.day);
    const meetings = count(entry.meetings, LIMITS.meetings);
    const meetingMinutes = count(entry.meetingMinutes, LIMITS.meetingMinutes);
    const nudges = count(entry.nudges, LIMITS.nudges);
    if (meetings === null || meetingMinutes === null || nudges === null) return { error: "Invalid counts." };
    days.push({ day: entry.day, meetings, meetingMinutes, nudges });
  }
  return {
    report: {
      installId: body.installId.toLowerCase(),
      appVersion: body.appVersion,
      osMajor: body.osMajor,
      days,
    },
  };
}

/**
 * Upserts each day. A resend of the same day replaces it rather than adding,
 * so a report retried after a lost response never double counts.
 */
export async function storeUsage(db, report, nowSeconds = Math.floor(Date.now() / 1000)) {
  const statement = db.prepare(
    `INSERT INTO usage_days
     (install_id, day, meetings, meeting_minutes, nudges, app_version, os_major, received_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
     ON CONFLICT (install_id, day) DO UPDATE SET
       meetings = excluded.meetings,
       meeting_minutes = excluded.meeting_minutes,
       nudges = excluded.nudges,
       app_version = excluded.app_version,
       os_major = excluded.os_major,
       received_at = excluded.received_at`,
  );
  await db.batch(report.days.map((d) => statement.bind(
    report.installId, d.day, d.meetings, d.meetingMinutes, d.nudges,
    report.appVersion, report.osMajor, nowSeconds,
  )));
}

export async function recordDownload(db, now = new Date()) {
  await db.prepare(
    `INSERT INTO download_days (day, count) VALUES (?1, 1)
     ON CONFLICT (day) DO UPDATE SET count = count + 1`,
  ).bind(dayString(now)).run();
}

export async function usageStats(db, now = new Date()) {
  const since = dayString(new Date(now.getTime() - 30 * DAY_MS));
  const totals = await db.prepare(
    `SELECT COALESCE(SUM(meetings), 0) AS meetings,
            COALESCE(SUM(meeting_minutes), 0) AS minutes,
            COALESCE(SUM(nudges), 0) AS nudges
     FROM usage_days`,
  ).first();
  const active = await db.prepare(
    "SELECT COUNT(DISTINCT install_id) AS installs FROM usage_days WHERE day >= ?1",
  ).bind(since).first();
  const downloads = await db.prepare(
    "SELECT COALESCE(SUM(count), 0) AS downloads FROM download_days",
  ).first();
  return {
    meetings: Number(totals?.meetings ?? 0),
    hoursCoached: Math.floor(Number(totals?.minutes ?? 0) / 60),
    nudges: Number(totals?.nudges ?? 0),
    activeInstalls30d: Number(active?.installs ?? 0),
    downloads: Number(downloads?.downloads ?? 0),
  };
}
