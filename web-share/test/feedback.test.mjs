import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import {
  MIN_INSTALLS, deleteFeedback, feedbackSummary, purgeOldFeedback, storeFeedback, summarizeFeedback,
  validateFeedbackReport,
} from "../src/feedback.js";

const now = new Date("2026-11-02T12:00:00Z");
const installId = "3F2504E0-4F89-41D3-9A0C-0305E82C3301";
const event = (over = {}) => ({
  eventId: "6F9619FF-8B86-D011-B42D-00C04FC964FF",
  day: "2026-11-01",
  signal: "talkTime",
  rating: "annoying",
  minute: 12,
  meetingType: "salesCall",
  features: { youShare: 0.71, lastYouTurnSec: 95.5, turnsSoFar: 40 },
  ...over,
});
const report = (events = [event()]) => ({ installId, appVersion: "0.34.0", events });

function d1(t) {
  const db = new DatabaseSync(":memory:");
  for (const m of ["0001_shared_notes.sql", "0002_referral_clicks.sql", "0003_usage.sql", "0004_feedback.sql"]) {
    db.exec(readFileSync(new URL("../migrations/" + m, import.meta.url), "utf8"));
  }
  t.after(() => db.close());
  const prepare = (sql) => ({
    bind(...args) {
      const statement = db.prepare(sql);
      return { run: async () => statement.run(...args), first: async () => statement.get(...args) };
    },
    all: async () => ({ results: db.prepare(sql).all() }),
  });
  return { db, DB: { prepare, batch: async (statements) => Promise.all(statements.map((s) => s.run())) } };
}

const uuid = (i) => `00000000-0000-4000-8000-${String(i).padStart(12, "0")}`;

test("accepts ids and numbers only, lowercasing ids", () => {
  const { report: clean, error } = validateFeedbackReport(report(), now);
  assert.equal(error, undefined);
  assert.equal(clean.installId, installId.toLowerCase());
  assert.equal(clean.events[0].youShare, 0.71);
  assert.equal(clean.events[0].turnsSoFar, 40);
});

test("rejects text anywhere: extra fields, custom ids, string features", () => {
  assert.match(validateFeedbackReport({ ...report(), notes: "x" }, now).error, /unexpected/i);
  assert.match(validateFeedbackReport(report([event({ text: "hi" })]), now).error, /unexpected event/i);
  assert.match(validateFeedbackReport(report([event({ signal: "custom:acme_pricing" })]), now).error, /signal/i);
  assert.match(validateFeedbackReport(report([event({ features: { youShare: "0.5" } })]), now).error, /feature/i);
  assert.match(validateFeedbackReport(report([event({ features: { quote: 1 } })]), now).error, /feature/i);
  assert.match(validateFeedbackReport(report([event({ rating: "meh" })]), now).error, /rating/i);
  assert.match(validateFeedbackReport(report([event({ meetingType: "board" })]), now).error, /meeting type/i);
  assert.match(validateFeedbackReport(report([event({ day: "2025-01-01" })]), now).error, /range/i);
  assert.match(validateFeedbackReport(report([event(), event()]), now).error, /duplicate/i);
  assert.match(validateFeedbackReport(report([event({ features: { youShare: 1.4 } })]), now).error, /feature/i);
});

test("features are optional and huge values are clamped", () => {
  const { report: clean } = validateFeedbackReport(report([event({ features: {}, minute: 9999 })]), now);
  assert.equal(clean.events[0].youShare, null);
  assert.equal(clean.events[0].minute, 600);
});

test("resent events are ignored, opt-out deletes, purge drops old rows", async (t) => {
  const { db, DB } = d1(t);
  const { report: clean } = validateFeedbackReport(report(), now);
  await storeFeedback(DB, clean, 1000);
  await storeFeedback(DB, clean, 1000);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM feedback_events").get().n, 1);
  await purgeOldFeedback(DB, 1000 + 179 * 86400);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM feedback_events").get().n, 1);
  await purgeOldFeedback(DB, 1000 + 181 * 86400);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM feedback_events").get().n, 0);
  await storeFeedback(DB, clean, 1000);
  await deleteFeedback(DB, installId);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM feedback_events").get().n, 0);
});

test("summary hides signals with too few installs and splits helpful vs not", async (t) => {
  const { DB } = d1(t);
  for (let i = 0; i < MIN_INSTALLS; i += 1) {
    const rating = i < 2 ? "useful" : "annoying";
    const r = { installId: uuid(i), appVersion: "0.34.0", events: [
      event({ eventId: uuid(100 + i), rating, features: { youShare: rating === "useful" ? 0.8 : 0.6 } }),
    ] };
    await storeFeedback(DB, validateFeedbackReport(r, now).report, 1000);
  }
  const few = { installId: uuid(50), appVersion: "0.34.0", events: [event({ eventId: uuid(200), signal: "nextSteps" })] };
  await storeFeedback(DB, validateFeedbackReport(few, now).report, 1000);

  const summary = await feedbackSummary(DB);
  assert.deepEqual(summary.signals.map((s) => s.signal), ["talkTime"]);
  const talk = summary.signals[0];
  assert.equal(talk.installs, 5);
  assert.equal(talk.helpfulRate, 0.4);
  assert.equal(talk.features.youShare.helpful.median, 0.8);
  assert.equal(talk.features.youShare.notHelpful.median, 0.6);
  assert.equal(JSON.stringify(summary).includes(installId.toLowerCase()), false);
  assert.equal(JSON.stringify(summary).includes("00000000-0000"), false);
});

test("summarizeFeedback is pure over rows", () => {
  assert.deepEqual(summarizeFeedback([]), { minInstalls: MIN_INSTALLS, signals: [] });
});
