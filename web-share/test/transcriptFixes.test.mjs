import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import {
  MIN_INSTALLS, collapse, deleteTranscriptFixes, purgeOldTranscriptFixes, scrubPair, shareable,
  storeTranscriptFixes, summarizeTranscriptFixes, transcriptFixSummary, validateTranscriptFixReport,
} from "../src/transcriptFixes.js";

const now = new Date("2026-11-02T12:00:00Z");
const installId = "3F2504E0-4F89-41D3-9A0C-0305E82C3301";
const uuid = (i) => `00000000-0000-4000-8000-${String(i).padStart(12, "0")}`;
const fix = (over = {}) => ({
  fixId: "6F9619FF-8B86-D011-B42D-00C04FC964FF", day: "2026-11-01",
  heard: "cooper net ease", corrected: "Kubernetes", engine: "parakeetV2", language: "en", ...over,
});
const report = (fixes = [fix()], id = installId) => ({ installId: id, appVersion: "0.34.0", fixes });

function d1(t) {
  const db = new DatabaseSync(":memory:");
  for (const m of ["0001_shared_notes.sql", "0002_referral_clicks.sql", "0003_usage.sql", "0004_feedback.sql", "0005_transcript_fixes.sql"]) {
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

test("shared scrub fixture: Worker agrees with the app and the merge script", () => {
  const { cases } = JSON.parse(readFileSync(new URL("../../tests/transcripts/scrub_cases.json", import.meta.url), "utf8"));
  for (const c of cases) {
    const h = collapse(c.heard), k = collapse(c.corrected);
    assert.equal(h !== k && shareable(h) && shareable(k), c.share, `${JSON.stringify(c.heard)} → ${JSON.stringify(c.corrected)}`);
    assert.equal(scrubPair(c.heard, c.corrected) !== null, c.share);
  }
});

test("accepts the scrubbed pair, lowercases the id, drops unshareable pairs whole", () => {
  const { report: clean, error } = validateTranscriptFixReport(
    report([fix(), fix({ fixId: uuid(2), heard: "email", corrected: "noah@example.com" })]), now);
  assert.equal(error, undefined);
  assert.equal(clean.installId, installId.toLowerCase());
  assert.deepEqual(clean.fixes.map((f) => f.corrected), ["Kubernetes"]);
});

test("rejects anything beyond the pair and ids", () => {
  assert.match(validateTranscriptFixReport({ ...report(), transcript: "x" }, now).error, /unexpected/i);
  assert.match(validateTranscriptFixReport(report([fix({ context: "the line" })]), now).error, /unexpected fix/i);
  assert.match(validateTranscriptFixReport(report([fix({ engine: "Parakeet v2 on Noah's Mac" })]), now).error, /engine/i);
  assert.match(validateTranscriptFixReport(report([fix({ language: "English" })]), now).error, /language/i);
  assert.match(validateTranscriptFixReport(report([fix({ day: "2025-01-01" })]), now).error, /range/i);
  assert.match(validateTranscriptFixReport(report([]), now).error, /fixes/i);
  assert.match(validateTranscriptFixReport({ ...report(), installId: "x" }, now).error, /install/i);
});

test("summary: only pairs from 3+ installs, never install ids; resend never double counts", async (t) => {
  const { DB } = d1(t);
  for (let i = 1; i <= MIN_INSTALLS; i++) {
    const { report: r } = validateTranscriptFixReport(report([fix()], uuid(i)), now);
    await storeTranscriptFixes(DB, r);
    await storeTranscriptFixes(DB, r);
  }
  const { report: lone } = validateTranscriptFixReport(report([fix({ heard: "fig ma", corrected: "Figma" })], uuid(9)), now);
  await storeTranscriptFixes(DB, lone);
  const summary = await transcriptFixSummary(DB);
  assert.deepEqual(summary.pairs.map((p) => [p.heard, p.corrected, p.installs, p.languages, p.engines]),
    [["cooper net ease", "Kubernetes", 3, "en", "parakeetV2"]]);
  assert.ok(!JSON.stringify(summary).includes("00000000-0000"));
});

test("opt-out delete and 180-day purge", async (t) => {
  const { db, DB } = d1(t);
  const { report: r } = validateTranscriptFixReport(report(), now);
  await storeTranscriptFixes(DB, r, 1_000);
  const { report: other } = validateTranscriptFixReport(report([fix()], uuid(5)), now);
  await storeTranscriptFixes(DB, other, 1_000 + 200 * 86_400);
  await purgeOldTranscriptFixes(DB, 1_000 + 181 * 86_400);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM transcript_fixes").get().n, 1);
  await deleteTranscriptFixes(DB, uuid(5).toUpperCase());
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM transcript_fixes").get().n, 0);
});

test("summarize groups by heard (case-insensitive) and corrected", () => {
  const rows = [1, 2, 3].map((i) => ({ install_id: uuid(i), heard_key: "fig ma", heard: i === 1 ? "Fig ma" : "fig ma", corrected: "Figma", engine: "", language: "" }));
  const { pairs } = summarizeTranscriptFixes(rows, 3, now);
  assert.equal(pairs.length, 1);
  assert.equal(pairs[0].installs, 3);
});
