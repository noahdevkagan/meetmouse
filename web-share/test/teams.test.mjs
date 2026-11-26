import assert from "node:assert/strict";
import test from "node:test";
import { loadWorker, makeEnv } from "./harness.mjs";
import {
  accessHash, accessToken, b64u, createBody, noteID, notePayload, notesKey, seal, unseal,
} from "./team-client.mjs";
import { teamRoute, validateCreateTeam, validateNote } from "../src/teams.js";

const worker = await loadWorker();
const teamID = "TEAMabcdefghijklmnopqr";
const secret = Buffer.alloc(32, 7);
const otherSecret = Buffer.alloc(32, 9);

function fixture(t) {
  const { db, env } = makeEnv();
  t.after(() => db.close());
  const req = (path, { method = "GET", body, key = secret, auth = true } = {}) =>
    worker.fetch(new Request("https://example.com" + path, {
      method,
      headers: auth ? { Authorization: "Bearer " + accessToken(key) } : {},
      body: body === undefined ? undefined : JSON.stringify(body),
    }), env);
  const create = (name = "Acme") =>
    req("/api/teams/create", { method: "POST", body: createBody(secret, teamID, name), auth: false });
  const put = (id, payload, options = {}) =>
    req(`/api/teams/${teamID}/notes/${id}`, { method: "PUT", body: seal(secret, teamID, id, payload), ...options });
  return { db, env, req, create, put };
}

const idFor = n => noteID(secret, "member-1", `session_${n}.md`);

test("team key derivation matches the Swift contract vectors", () => {
  // The same constants are asserted in tests/team/main.swift.
  assert.equal(accessToken(secret), "-yp-K4zAAXg4RfCUqqpRMp9ER9x3QCfdNjam1w7Fk3U");
  assert.equal(accessHash(secret), "fqWs97gOqPbzgIA_HYHnYwSL9EHYkGo4Cva4gE54hLQ");
  assert.equal(b64u(notesKey(secret)), "8brxkuOho6mFxHyaxS-5Vd9CutsQyB3Ee4w9NHpOSrY");
  assert.equal(noteID(secret, "member-1", "session_2026-08-01_15-30.md"), "rWwKzE36mVM7MpHzZ6SS1A");
  const sealed = seal(secret, teamID, "name", { name: "Acme" }, Buffer.alloc(12, 1));
  assert.equal(sealed.ciphertext, "tPzi-TjBWOiGUtLxcUPY3TjSYqfkagT-HM2mQjxaDg");
});

test("only exact team API paths route", () => {
  assert.deepEqual(teamRoute("/api/teams/create"), { action: "create" });
  assert.deepEqual(teamRoute(`/api/teams/${teamID}`), { action: "team", teamID });
  assert.deepEqual(teamRoute(`/api/teams/${teamID}/notes`), { action: "notes", teamID });
  assert.equal(teamRoute(`/api/teams/${teamID}/notes/short`), null);
  assert.equal(teamRoute(`/api/teams/${teamID}/extra`), null);
  assert.equal(teamRoute("/api/teams/<script>"), null);
});

test("create and note envelopes are validated", () => {
  const body = createBody(secret, teamID, "Acme");
  assert.equal(validateCreateTeam(body), null);
  assert.match(validateCreateTeam({ ...body, id: "short" }), /team id/i);
  assert.match(validateCreateTeam({ ...body, accessHash: "AAAA" }), /access/i);
  assert.match(validateCreateTeam({ ...body, nameCiphertext: "A".repeat(4000) }), /team name/i);
  assert.equal(validateNote(seal(secret, teamID, "x", { a: 1 })), null);
  assert.match(validateNote({ nonce: "bad", ciphertext: "AAAA" }), /encrypted note/i);
  assert.match(validateNote({ nonce: "AAAAAAAAAAAAAAAA", ciphertext: "A".repeat(90_000) }), /encrypted note/i);
});

test("a team is created once and only members can read it", async t => {
  const f = fixture(t);
  assert.equal((await f.create()).status, 201);
  assert.equal((await f.create()).status, 409);
  assert.equal((await f.req(`/api/teams/${teamID}`, { auth: false })).status, 401);
  assert.equal((await f.req(`/api/teams/${teamID}`, { key: otherSecret })).status, 403);
  assert.equal((await f.req("/api/teams/UNKNOWNabcdefghijklmno")).status, 404);
  const res = await f.req(`/api/teams/${teamID}`);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("cache-control"), "no-store");
  const team = await res.json();
  assert.equal(team.accessHash, undefined);
  assert.equal(team.access_hash, undefined);
  assert.equal(team.noteCount, 0);
  assert.deepEqual(unseal(secret, teamID, "name", team.nameNonce, team.nameCiphertext), { name: "Acme" });
});

test("the server stores only ciphertext and the access hash", async t => {
  const f = fixture(t);
  await f.create("Acme Secret Plans");
  await f.put(idFor(1), notePayload("Ana", "Pricing review", "2026-08-01T15:30:00Z"));
  const dump = JSON.stringify([
    f.db.prepare("SELECT * FROM teams").all(), f.db.prepare("SELECT * FROM team_notes").all(),
  ]);
  for (const leak of ["Acme", "Pricing", "Ana", accessToken(secret), b64u(secret)]) {
    assert.ok(!dump.includes(leak), `stored rows must not contain ${leak}`);
  }
  assert.ok(dump.includes(accessHash(secret)));
});

test("members add, update, list and remove notes; outsiders cannot", async t => {
  const f = fixture(t);
  await f.create();
  const first = idFor(1);
  assert.equal((await f.put(first, notePayload("Ana", "Kickoff", "2026-08-01T15:30:00Z"))).status, 201);
  assert.equal((await f.put(first, notePayload("Ana", "Kickoff"), { key: otherSecret })).status, 403);
  assert.equal((await f.put(first, notePayload("Ana", "Kickoff"), { auth: false })).status, 401);
  // Sharing the same meeting again replaces the note in place.
  const update = await f.put(first, notePayload("Ana", "Kickoff (edited)", "2026-08-01T15:30:00Z"));
  assert.equal(update.status, 200);
  assert.equal((await update.json()).updated, true);
  assert.equal((await f.put(idFor(2), notePayload("Ben", "Retro", "2026-08-02T15:30:00Z"))).status, 201);

  assert.equal((await f.req(`/api/teams/${teamID}/notes`, { key: otherSecret })).status, 403);
  const list = await (await f.req(`/api/teams/${teamID}/notes`)).json();
  assert.equal(list.notes.length, 2);
  assert.equal(list.next, null);
  const titles = list.notes.map(row => unseal(secret, teamID, row.id, row.nonce, row.ciphertext).note.title).sort();
  assert.deepEqual(titles, ["Kickoff (edited)", "Retro"]);
  assert.equal((await (await f.req(`/api/teams/${teamID}`)).json()).noteCount, 2);

  // A note sealed for one id cannot be replayed under another id.
  const moved = list.notes[0];
  assert.throws(() => unseal(secret, teamID, idFor(9), moved.nonce, moved.ciphertext));

  assert.equal((await f.req(`/api/teams/${teamID}/notes/${first}`, { method: "DELETE", key: otherSecret })).status, 403);
  assert.equal((await f.req(`/api/teams/${teamID}/notes/${first}`, { method: "DELETE" })).status, 204);
  assert.equal((await (await f.req(`/api/teams/${teamID}/notes`)).json()).notes.length, 1);
});

test("notes page newest first with a stable cursor", async t => {
  const f = fixture(t);
  await f.create();
  for (let n = 0; n < 45; n += 1) {
    await f.put(idFor(n), notePayload("Ana", `Call ${n}`, "2026-08-01T15:30:00Z"));
    // Two notes a second, so some share a created_at and the id breaks the tie.
    f.db.prepare("UPDATE team_notes SET created_at = ? WHERE id = ?").run(1000 + Math.floor(n / 2), idFor(n));
  }
  const seen = [];
  let cursor = null;
  let pages = 0;
  do {
    const page = await (await f.req(`/api/teams/${teamID}/notes${cursor ? `?before=${cursor}` : ""}`)).json();
    seen.push(...page.notes.map(row => row.id));
    cursor = page.next;
    pages += 1;
  } while (cursor);
  assert.equal(pages, 3);
  assert.equal(new Set(seen).size, 45);
  assert.equal(seen.length, 45);
  assert.equal((await f.req(`/api/teams/${teamID}/notes?before=nonsense`)).status, 400);
});

test("expired notes disappear and the sweep removes them", async t => {
  const f = fixture(t);
  await f.create();
  await f.put(idFor(1), notePayload("Ana", "Old call", "2025-01-01T10:00:00Z"));
  f.db.exec("UPDATE team_notes SET expires_at = 1");
  assert.equal((await (await f.req(`/api/teams/${teamID}/notes`)).json()).notes.length, 0);
  const pending = [];
  await worker.scheduled({}, f.env, { waitUntil: promise => pending.push(promise) });
  await Promise.all(pending);
  assert.equal(f.db.prepare("SELECT count(*) AS n FROM team_notes").get().n, 0);
});

test("rate limits and the team size cap are enforced", async t => {
  const f = fixture(t);
  await f.create();
  f.env.CREATE_RATE_LIMITER.limit = async ({ key }) => ({ success: key !== `team:${teamID}` });
  assert.equal((await f.put(idFor(1), notePayload("Ana", "Call"))).status, 429);
  f.env.CREATE_RATE_LIMITER.limit = async () => ({ success: true });
  const insert = f.db.prepare(
    "INSERT INTO team_notes (team_id,id,nonce,ciphertext,created_at,updated_at,expires_at) VALUES (?,?,?,?,?,?,?)");
  for (let n = 0; n < 1000; n += 1) {
    insert.run(teamID, `fill${String(n).padStart(18, "0")}`, "n", "c", 1, 1, 9_999_999_999);
  }
  const full = await f.put(idFor(1), notePayload("Ana", "One too many"));
  assert.equal(full.status, 409);
  assert.match((await full.json()).error, /full/);
  // Updating a note that is already there still works on a full page.
  assert.equal((await f.req(`/api/teams/${teamID}/notes/fill${"0".repeat(18)}`, {
    method: "PUT", body: seal(secret, teamID, "x", { a: 1 }),
  })).status, 200);
  f.env.CREATE_RATE_LIMITER.limit = async () => ({ success: false });
  assert.equal((await worker.fetch(new Request("https://example.com/api/teams/create", {
    method: "POST", body: JSON.stringify(createBody(secret, "OTHERabcdefghijklmnopq", "B")),
  }), f.env)).status, 429);
});

test("the team page is served with the strict policy and its own assets", async t => {
  const f = fixture(t);
  const page = await f.req(`/t/${teamID}`, { auth: false });
  assert.equal(page.status, 200);
  assert.match(page.headers.get("content-security-policy"), /default-src 'none'/);
  assert.equal(page.headers.get("cache-control"), "no-store");
  const html = await page.text();
  assert.match(html, /\/t\/assets\/team-v1\.js/);
  assert.doesNotMatch(html, /—/);
  assert.equal((await f.req("/t/short", { auth: false })).status, 404);
  const script = await f.req("/t/assets/team-v1.js", { auth: false });
  assert.match(script.headers.get("content-type"), /javascript/);
  const js = await script.text();
  assert.match(js, /meetmouse-team-access-v1/);
  assert.match(js, /meetmouse-team-notes-v1/);
  assert.doesNotMatch(js, /utm_|analytics|track\(|innerHTML/i);
  assert.match((await f.req("/t/assets/team-v1.css", { auth: false })).headers.get("content-type"), /css/);
});
