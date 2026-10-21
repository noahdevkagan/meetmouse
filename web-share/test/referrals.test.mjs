import assert from "node:assert/strict";
import test from "node:test";
import {
  isReferralCode, landingHTML, latestDMG, referralRoute, statusHTML, unlockCode,
} from "../src/referrals.js";

test("referral codes match the app's 8-char base32 format", () => {
  assert.ok(isReferralCode("abcd2345"));
  assert.ok(!isReferralCode("ABCD2345"));
  assert.ok(!isReferralCode("abcd234"));
  assert.ok(!isReferralCode("abcd2341")); // 1 is not base32
});

test("only the three referral paths route", () => {
  assert.deepEqual(referralRoute("/r/abcd2345"), { code: "abcd2345", action: "landing" });
  assert.deepEqual(referralRoute("/r/abcd2345/go"), { code: "abcd2345", action: "go" });
  assert.deepEqual(referralRoute("/r/abcd2345/status"), { code: "abcd2345", action: "status" });
  assert.equal(referralRoute("/r/abcd2345/other"), null);
  assert.equal(referralRoute("/r/<script>"), null);
});

test("landing sends friends to the free download through the counting route", () => {
  const html = landingHTML("abcd2345");
  assert.match(html, /\/r\/abcd2345\/go\?to=download/);
  assert.doesNotMatch(html, /to=appsumo/);
  assert.doesNotMatch(html, /<script/);
});

test("status unlocks only at 2 friends", () => {
  assert.match(statusHTML("abcd2345", 1), /1 of 2 friends/);
  assert.doesNotMatch(statusHTML("abcd2345", 1), /meetmouse:\/\/unlock/);
  assert.match(statusHTML("abcd2345", 5), new RegExp(`meetmouse://unlock\\?code=${unlockCode}`));
});

test("latestDMG picks the DMG asset and falls back to the releases page", async () => {
  const ok = async () => new Response(JSON.stringify({
    assets: [{ name: "appcast.xml", browser_download_url: "x" },
      { name: "MeetMouse-0.31.0.dmg", browser_download_url: "https://example/MeetMouse-0.31.0.dmg" }],
  }));
  assert.equal(await latestDMG(ok), "https://example/MeetMouse-0.31.0.dmg");
  assert.match(await latestDMG(async () => new Response("", { status: 500 })), /releases\/latest$/);
  assert.match(await latestDMG(async () => { throw new Error("offline"); }), /releases\/latest$/);
});
