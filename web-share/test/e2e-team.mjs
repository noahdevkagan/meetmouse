// Browser check of the team page: a real Chromium decrypts notes sealed by
// the reference client. Not part of `npm test` (needs Playwright):
//   node test/e2e-team.mjs [screenshot-dir]
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { createRequire } from "node:module";
import { loadWorker, makeEnv } from "./harness.mjs";
import { accessToken, b64u, createBody, noteID, notePayload, seal } from "./team-client.mjs";

const require = createRequire(import.meta.url);
const { chromium } = require("playwright");
const shots = process.argv[2];

const worker = await loadWorker();
const { db, env } = makeEnv();
const server = createServer(async (incoming, outgoing) => {
  const chunks = [];
  for await (const chunk of incoming) chunks.push(chunk);
  const response = await worker.fetch(new Request(`http://${incoming.headers.host}${incoming.url}`, {
    method: incoming.method,
    headers: incoming.headers,
    body: chunks.length ? Buffer.concat(chunks) : undefined,
  }), env);
  outgoing.writeHead(response.status, Object.fromEntries(response.headers));
  outgoing.end(Buffer.from(await response.arrayBuffer()));
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const origin = `http://127.0.0.1:${server.address().port}`;

const teamID = "TEAMabcdefghijklmnopqr";
const secret = Buffer.alloc(32, 7);
const call = (path, method, body) => fetch(origin + path, {
  method, headers: { Authorization: "Bearer " + accessToken(secret) }, body: JSON.stringify(body),
});
assert.equal((await call("/api/teams/create", "POST", createBody(secret, teamID, "Acme Growth"))).status, 201);
const people = ["Ana Lopez", "Ben Okafor", "Chidi Park"];
for (let n = 0; n < 23; n += 1) {
  const id = noteID(secret, `member-${n % 3}`, `session_${n}.md`);
  const day = String(1 + n).padStart(2, "0");
  const payload = notePayload(people[n % 3], n === 22 ? "Pricing review with <b>Initech</b>" : `Weekly sync ${n}`,
    `2026-08-${day}T15:30:00Z`);
  assert.equal((await call(`/api/teams/${teamID}/notes/${id}`, "PUT", seal(secret, teamID, id, payload))).status, 201);
  db.prepare("UPDATE team_notes SET created_at = ? WHERE id = ?").run(1000 + n, id);
}

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1100, height: 900 }, deviceScaleFactor: shots ? 2 : 1 });
const problems = [];
page.on("console", message => { if (message.type() === "error") problems.push(message.text()); });
page.on("pageerror", error => problems.push(String(error)));

await page.goto(`${origin}/t/${teamID}#${b64u(secret)}`);
await page.waitForSelector("#content:not([hidden])");
assert.equal(await page.textContent("#teamName"), "Acme Growth");
assert.match(await page.textContent("#meta"), /23 shared notes/);
assert.equal(await page.locator(".team-note").count(), 20);
// Newest meeting first; markup in a title is shown as text, never run.
assert.equal(await page.locator(".team-note .team-title").first().textContent(), "Pricing review with <b>Initech</b>");
assert.equal(await page.locator(".team-note b").count(), 0);
assert.match(await page.locator(".team-note .team-by").first().textContent(), /Ben Okafor · 30 min/);
assert.equal(await page.getAttribute("#openApp", "href"), `meetmouse://team?id=${teamID}&key=${b64u(secret)}`);

await page.locator(".team-note summary").first().click();
await page.waitForSelector(".team-note[open] .team-body");
assert.match(await page.locator(".team-note[open] .team-body").textContent(), /ship on Friday[\s\S]*Send the deck/);
if (shots) await page.screenshot({ path: `${shots}/team-page.png`, fullPage: false });

await page.fill("#search", "initech");
assert.equal(await page.locator(".team-note:visible").count(), 1);
await page.fill("#search", "nothing-like-this");
assert.equal(await page.locator(".team-note:visible").count(), 0);
assert.match(await page.textContent("#empty"), /Load older notes/);
await page.fill("#search", "");

await page.click("#moreButton");
await page.waitForFunction(() => document.querySelectorAll(".team-note").length === 23);
assert.equal(await page.isHidden("#moreButton"), true);
assert.equal(await page.locator(".team-note .team-title").last().textContent(), "Weekly sync 0");

// Dark appearance and a phone width, for the screenshots.
if (shots) {
  await page.emulateMedia({ colorScheme: "dark" });
  await page.setViewportSize({ width: 390, height: 800 });
  await page.screenshot({ path: `${shots}/team-page-dark-phone.png` });
  await page.emulateMedia({ colorScheme: "light" });
}

// Wrong secret, missing secret, unknown team, empty team.
const expectError = async (url, pattern) => {
  const tab = await browser.newPage();
  await tab.goto(url);
  await tab.waitForSelector("#error:not([hidden])");
  assert.match(await tab.textContent("#errorTitle"), pattern);
  await tab.close();
};
await expectError(`${origin}/t/${teamID}#${b64u(Buffer.alloc(32, 9))}`, /doesn't match/);
await expectError(`${origin}/t/${teamID}`, /incomplete/);
await expectError(`${origin}/t/UNKNOWNabcdefghijklmno#${b64u(secret)}`, /not found/);
await expectError(`${origin}/t/${teamID}#tooshort`, /could not be opened/);

const emptyID = "EMPTYabcdefghijklmnopq";
await call("/api/teams/create", "POST", createBody(secret, emptyID, "New Team"));
const empty = await browser.newPage();
await empty.goto(`${origin}/t/${emptyID}#${b64u(secret)}`);
await empty.waitForSelector("#content:not([hidden])");
assert.match(await empty.textContent("#empty"), /finish meetings in MeetMouse/);
if (shots) await empty.screenshot({ path: `${shots}/team-page-empty.png` });

// 403/404 answers are expected console noise for the error-state tabs only.
assert.deepEqual(problems, []);
await browser.close();
server.close();
console.log("team page e2e: PASS");
