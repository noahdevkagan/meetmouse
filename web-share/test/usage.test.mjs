import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import { recordDownload, storeUsage, usageStats, validateUsageReport } from "../src/usage.js";

const now = new Date("2026-11-02T12:00:00Z");
const report = {
  installId: "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
  appVersion: "0.34.0",
  osMajor: 15,
  days: [{ day: "2026-11-01", meetings: 3, meetingMinutes: 95, nudges: 7 }],
};

function d1(t) {
  const db = new DatabaseSync(":memory:");
  for (const m of ["0001_shared_notes.sql", "0002_referral_clicks.sql", "0003_usage.sql"]) {
    db.exec(readFileSync(new URL("../migrations/" + m, import.meta.url), "utf8"));
  }
  t.after(() => db.close());
  const prepare = (sql) => ({
    bind(...args) {
      const statement = db.prepare(sql);
      return { run: async () => statement.run(...args), first: async () => statement.get(...args) };
    },
    first: async () => db.prepare(sql).get(),
  });
  return { db, DB: { prepare, batch: async (statements) => Promise.all(statements.map((s) => s.run())) } };
}

test("accepts a well-formed report and lowercases the install id", () => {
  const { report: clean, error } = validateUsageReport(report, now);
  assert.equal(error, undefined);
  assert.equal(clean.installId, report.installId.toLowerCase());
  assert.deepEqual(clean.days, report.days);
});

test("rejects anything beyond counts: extra fields, bad ids, bad days", () => {
  assert.match(validateUsageReport({ ...report, transcript: "hi" }, now).error, /unexpected/i);
  assert.match(validateUsageReport({ ...report, installId: "nope" }, now).error, /install id/i);
  assert.match(validateUsageReport({ ...report, appVersion: "<b>" }, now).error, /version/i);
  assert.match(validateUsageReport({ ...report, osMajor: 9 }, now).error, /macos/i);
  assert.match(validateUsageReport({ ...report, days: [] }, now).error, /days/i);
  const day = report.days[0];
  assert.match(validateUsageReport({ ...report, days: [{ ...day, title: "1:1" }] }, now).error, /unexpected/i);
  assert.match(validateUsageReport({ ...report, days: [{ ...day, day: "2025-01-01" }] }, now).error, /range/i);
  assert.match(validateUsageReport({ ...report, days: [{ ...day, meetings: -1 }] }, now).error, /counts/i);
  assert.match(validateUsageReport({ ...report, days: [{ ...day, nudges: 1.5 }] }, now).error, /counts/i);
  assert.match(validateUsageReport({ ...report, days: [day, day] }, now).error, /duplicate/i);
});

test("clamps implausible counts instead of trusting them", () => {
  const big = { ...report, days: [{ day: "2026-11-01", meetings: 9999, meetingMinutes: 99999, nudges: 99999 }] };
  const { report: clean } = validateUsageReport(big, now);
  assert.deepEqual(clean.days[0], { day: "2026-11-01", meetings: 50, meetingMinutes: 1440, nudges: 2000 });
});

test("resending a day replaces it, and stats aggregate across installs", async (t) => {
  const { DB } = d1(t);
  const first = validateUsageReport(report, now).report;
  await storeUsage(DB, first);
  await storeUsage(DB, first); // retried after a lost response
  const other = validateUsageReport({
    ...report,
    installId: "9B2E7A10-1C3D-4E5F-8A9B-0C1D2E3F4A5B",
    days: [{ day: "2026-10-01", meetings: 2, meetingMinutes: 30, nudges: 1 }],
  }, now).report;
  await storeUsage(DB, other);
  await recordDownload(DB, now);
  await recordDownload(DB, now);
  const stats = await usageStats(DB, now);
  assert.deepEqual(stats, { meetings: 5, hoursCoached: 2, nudges: 8, activeInstalls30d: 1, downloads: 2 });
});
