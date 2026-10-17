// Free tier: "invite 2 friends, get MeetMouse Unlimited free" (ported from
// Rhino's website). The app mints a per-install code (ReferralLink.swift);
// friends land on /r/<code>, /r/<code>/go counts them once, and
// /r/<code>/status shows the unlock button at 2. Also serves /get, the
// counted "Download free" redirect to the newest DMG.

export const referralsNeeded = 2;
export const appSumoUrl = "https://appsumo.com/products/meeting-coach/";
export const appSumoCoupon = "coachfree";
/** Same code as /thanks; the app checks its SHA-256 in UsageGate.swift. */
export const unlockCode = "MOUSE-5KC5-7EDA";
const releasesPage = "https://github.com/noahdevkagan/meeting-coach-releases/releases/latest";
const latestReleaseAPI = "https://api.github.com/repos/noahdevkagan/meeting-coach-releases/releases/latest";

/** Must match ReferralLink.isValid in the app: 8 lowercase base32 chars. */
export function isReferralCode(code) {
  return typeof code === "string" && /^[a-z2-7]{8}$/.test(code);
}

/** Parses /r/<code>, /r/<code>/go, /r/<code>/status. Null for anything else. */
export function referralRoute(pathname) {
  const match = /^\/r\/([^/]+)(?:\/(go|status))?\/?$/.exec(pathname);
  if (!match || !isReferralCode(match[1])) return null;
  return { code: match[1], action: match[2] ?? "landing" };
}

async function sha256Hex(value) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * One friend = one browser on one network: a hash of IP + user agent, salted
 * with the code. Repeat clicks from the same friend count once.
 */
export async function recordReferralClick(db, code, request, destination) {
  const ip = request.headers.get("cf-connecting-ip") ?? "";
  const ua = request.headers.get("user-agent") ?? "";
  const friend = await sha256Hex(`${code}|${ip}|${ua}`);
  await db.prepare(
    "INSERT OR IGNORE INTO referral_clicks (code, friend, destination, created_at) VALUES (?1, ?2, ?3, ?4)",
  ).bind(code, friend, destination, Date.now()).run();
}

export async function referralCount(db, code) {
  const row = await db.prepare("SELECT COUNT(*) AS n FROM referral_clicks WHERE code = ?1")
    .bind(code).first();
  return Number(row?.n ?? 0);
}

/** Newest DMG URL, cached 10 minutes; falls back to the releases page. */
export async function latestDMG(fetchImpl = fetch) {
  try {
    const res = await fetchImpl(latestReleaseAPI, {
      headers: { "User-Agent": "meetmouse.com", Accept: "application/vnd.github+json" },
      cf: { cacheTtl: 600, cacheEverything: true },
    });
    if (!res.ok) return releasesPage;
    const release = await res.json();
    const dmg = (release.assets ?? []).find((a) => String(a.name).endsWith(".dmg"));
    return dmg?.browser_download_url ?? releasesPage;
  } catch {
    return releasesPage;
  }
}

function page(title, body) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${title}</title>
<link rel="icon" type="image/png" href="/icon.png">
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
    background: #fff; color: #1a1a1a; line-height: 1.6; -webkit-font-smoothing: antialiased; }
  main { max-width: 560px; margin: 0 auto; padding: 80px 24px; text-align: center; }
  img.icon { width: 72px; height: 72px; }
  h1 { font-size: 32px; letter-spacing: -0.02em; margin-top: 16px; }
  p { color: #555; margin-top: 14px; }
  .btn { display: inline-block; background: #111; color: #fff; font-size: 17px; font-weight: 600;
    text-decoration: none; border-radius: 10px; padding: 14px 28px; margin-top: 28px; }
  .btn:hover { background: #333; }
  .btn.secondary { background: #fff; color: #111; border: 1px solid #ccc; margin-top: 16px; }
  .note { font-size: 14px; color: #888; margin-top: 10px; }
  code { background: #f3f3f3; border-radius: 6px; padding: 2px 8px; font-size: 15px; word-break: break-all; }
  .back { display: block; text-align: left; color: #888; font-size: 14px; text-decoration: none; }
</style>
</head>
<body><main><a class="back" href="/">← MeetMouse</a>${body}</main></body>
</html>`;
}

export function landingHTML(code) {
  return page("A friend gave you MeetMouse", `
  <img class="icon" src="/icon.png" alt="">
  <h1>A friend gave you MeetMouse.</h1>
  <p>Notes and live coaching for your meetings, running on your Mac. No bot joins the call, and transcription never leaves your computer.</p>
  <a class="btn" href="/r/${code}/go?to=appsumo">Get MeetMouse Unlimited free on AppSumo</a>
  <p class="note">Use coupon <code>${appSumoCoupon}</code> at checkout.</p>
  <a class="btn secondary" href="/r/${code}/go?to=download">Or download the free version</a>
  <p class="note">Requires macOS 14 or later.</p>`);
}

export function statusHTML(code, count) {
  const shown = Math.min(count, referralsNeeded);
  if (shown >= referralsNeeded) {
    return page("Your MeetMouse invites", `
  <img class="icon" src="/icon.png" alt="">
  <h1>You unlocked MeetMouse Unlimited.</h1>
  <p>${referralsNeeded} friends got MeetMouse through your link. Thank you.</p>
  <a class="btn" href="meetmouse://unlock?code=${unlockCode}">Unlock MeetMouse</a>
  <p class="note">Click on the Mac where MeetMouse is installed. It opens already unlimited.</p>`);
  }
  const link = `https://meetmouse.com/r/${code}`;
  return page("Your MeetMouse invites", `
  <img class="icon" src="/icon.png" alt="">
  <h1>${shown} of ${referralsNeeded} friends</h1>
  <p>When ${referralsNeeded} friends get MeetMouse through your link, MeetMouse Unlimited is yours free. Your link:</p>
  <p><code>${link}</code></p>
  <p class="note">A friend counts once they open your link and click to get MeetMouse. Check back here any time.</p>`);
}
