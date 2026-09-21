# Encrypted meeting-note sharing

The Worker owns only `/p/*` and `/api/shared-notes/*`. MeetingCoach encrypts
the curated note on the Mac; D1 stores ciphertext, expiry, and a hash of the
owner's revocation capability. The AES key is carried in the URL fragment and
is never sent in an HTTP request.

## Local development

```bash
cd web-share
npm install
npm run db:local
npm run dev
```

Both Debug and Release use the existing HTTPS service at `rhinovoice.app`.
The backend was deployed in the milan workspace; do not create another database.
Local testing can explicitly select `http://127.0.0.1:8787`.
Override either address for a process with `MC_SHARE_API_BASE_URL` and
`MC_SHARE_VIEWER_BASE_URL`.

## Production

The existing `meetingcoach-shares` Worker and D1 database are already configured
in `wrangler.toml`. Preserve them and the existing rhinovoice.app routes so old
links and revocation capabilities continue to work. Do not provision replacements.

To publish the MeetMouse recipient branding/CTA using your Cloudflare login:

```bash
cd web-share
npm ci
npm run deploy
```

The recipient page points to `https://meetmouse.com`. This source update must be
deployed before existing live Rhino-branded pages change. No new D1 migration is
needed on the existing service. Both dev and release apps default to its HTTPS
endpoints; creating a share still requires the meeting-specific preview action.

The Worker itself enforces a 64 KB encrypted-note cap and a server-controlled
30-day expiry. Expired ciphertext is rejected immediately and swept from D1
daily. The Worker emits no analytics and never logs request bodies.

## Recovery and appearance

Use Node 22.13+ for the SQLite-backed Worker regression tests (`npm test`).
The desktop persists a pending owner capability before uploading, using a separate
cross-process lock file and an atomic JSON transaction. Pending requests remain
visible in **Meetings → Shared links**, even if the transcript is deleted. Cancel
pending uploads there with Stop sharing; failed revocations retain their controls.
Confirmed uploads can also be sent/copied from that manager.

Deploy the updated Worker with the app: revocation retains an empty-ciphertext
reservation until expiry so a delayed create cannot resurrect a cancelled link.
This uses the existing schema and needs no migration. The recipient page uses the
app's Dorado colors, native system typography, and automatic light/dark appearance.
Versioned v4 assets prevent the earlier page styling being reused.
