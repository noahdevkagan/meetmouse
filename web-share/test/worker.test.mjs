import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import { shareIDFromPath, sha256Base64URL, validateCreateBody } from "../src/core.js";

const viewerHTML = readFileSync(new URL("../src/viewer.html", import.meta.url), "utf8");
const viewerJS = readFileSync(new URL("../src/viewer.js.txt", import.meta.url), "utf8");

const valid = {
  schemaVersion: 1,
  id: "abcdefghijklmnopqrstuv",
  nonce: "AAAAAAAAAAAAAAAA",
  ciphertext: "AAAAAAAAAAAAAAAAAAAAAAAA",
  revokeHash: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
};

test("accepts the narrow encrypted create envelope", () => {
  assert.equal(validateCreateBody(valid), null);
});

test("rejects malformed ids, nonce, ciphertext, and revocation hashes", () => {
  assert.match(validateCreateBody({ ...valid, id: "short" }), /share id/i);
  assert.match(validateCreateBody({ ...valid, nonce: "bad" }), /nonce/i);
  assert.match(validateCreateBody({ ...valid, ciphertext: "AAAA" }), /encrypted note/i);
  assert.match(validateCreateBody({ ...valid, revokeHash: "AAAA" }), /revocation/i);
});

test("only exact record API paths produce ids", () => {
  assert.equal(shareIDFromPath(`/api/shared-notes/${valid.id}`), valid.id);
  assert.equal(shareIDFromPath(`/api/shared-notes/${valid.id}/extra`), null);
  assert.equal(shareIDFromPath("/api/shared-notes/create"), null);
});

test("revocation hashing matches the Swift SHA-256 base64url contract", async () => {
  assert.equal(
    await sha256Base64URL("test-revoke-token"),
    "Wxu4ZkuAmh-UnQfFYokIXKnUDIO04Jr0YcRaKMpAc5o",
  );
});

test("recipient forwarding preserves the complete fragment-bearing link", () => {
  assert.match(viewerHTML, /id="shareButton"/);
  assert.match(viewerHTML, /Try MeetMouse/);
  assert.match(viewerHTML, /href="https:\/\/meetmouse\.com"/);
  assert.match(viewerJS, /url: location\.href/);
  assert.match(viewerJS, /copyText\(location\.href\)/);
  assert.doesNotMatch(viewerJS, /utm_|analytics|track\(/i);
});

function viewerContext(navigator = {}) {
  const context = vm.createContext({
    navigator,
    location: { href: "https://rhinovoice.app/p/abcdefghijklmnopqrstuv#secret-key" },
    document: { querySelector: () => ({ addEventListener() {}, textContent: "Planning" }) },
  });
  vm.runInContext(viewerJS.replace("\nopenNote();", "\n"), context);
  return context;
}

test("portable notes contain useful next steps and the full private link, excluding unrelated data", () => {
  const context = viewerContext();
  const result = context.formatNotes({
    title: "Planning", summary: "Ship the update",
    sections: [{ heading: "Decisions", bullets: ["Use the new design"] }],
    nextSteps: [{ text: "Review mockups", isDone: false }, { text: "Pick date", isDone: true }],
    transcript: "PRIVATE TRANSCRIPT", coaching: "PRIVATE COACHING", chat: "PRIVATE CHAT",
  }, context.location.href);
  assert.match(result, /Decisions\n- Use the new design/);
  assert.match(result, /- \[ \] Review mockups/);
  assert.match(result, /- \[x\] Pick date/);
  assert.ok(result.includes(context.location.href));
  assert.match(result, /Made with MeetMouse/);
  assert.doesNotMatch(result, /PRIVATE TRANSCRIPT|PRIVATE COACHING|PRIVATE CHAT/);
});

test("forwarding uses the complete link and cancellation does not copy", async () => {
  const sent = [];
  let copies = 0;
  const context = viewerContext({
    share: async data => { sent.push(data); },
    clipboard: { writeText: async () => { copies++; } },
  });
  assert.equal(sent.length, 0);
  assert.equal(copies, 0);
  await context.shareCompleteLink();
  assert.equal(sent[0].url, context.location.href);
  context.navigator.share = async () => { throw { name: "AbortError" }; };
  await context.shareCompleteLink();
  assert.equal(copies, 0);
});

test("browsers without native sharing copy the complete private link", async () => {
  const copied = [];
  const context = viewerContext({ clipboard: { writeText: async text => copied.push(text) } });
  await context.shareCompleteLink();
  assert.deepEqual(copied, [context.location.href]);
});
