# HANDOFF — session seed

Auto-injected into every Claude session in this repo (SessionStart hook in
`.claude/settings.json`). Rewritten by `/handoff` at the end of a session.
Keep it short: current state, outstanding work, and the prompt to start from.
The durable "why" behind choices goes in `decisions.md`, not here.

## Current state (2026-09-21): Optional cloud AI / BYOK — built

Settings → AI now offers Local / Claude / OpenAI, model selection, device-only
Keychain keys, synthetic connection test, removal, and explicit text-sharing
consent plus Save and enable. Local remains default. Shared AIClient routes
coaching, names, reviews, Ask AI and note interpretation. Cloud sessions bypass
Ollama downloads/memory/preload/unload; pinned provider references cannot switch
mid-call, and every cloud completion checks the currently enabled preference.
Cloud failure leaves local transcription/built-in signals running and shows errors.
Audio is never uploaded. User explicitly authorized this optional exception to
the old local-only network rule; AGENTS.md and decisions.md now record it.

Validation: signed Debug xcodebuild passed; 35 provider/Keychain checks (mocked
HTTP, isolated disposable Keychain service), 154 session checks, 27 nudge checks
passed. New AI suite is in local and CI gates. Both provider forms inspected in
the dev app; screenshot `.context/ai-settings.png`. Logs `.context/byok-*.log`.
No real API key used, no meeting content uploaded; live provider verification
still needs a user's key via Test connection. No release, push, or deployment.
Homepage source and in-app privacy wording adjusted; Unreleased changelog added.
The dev app is open to AI settings with Local still active.

## Current state (2026-09-17): Speaker attribution reliability — built

Fixed the Anna/Tadeáš group-call failure paths: only this call's confirmed
participants seed aliases/enrollment, and unknown/group calls no longer give
unassigned speech the first named speaker's identity. Confirmed one-on-one
aliases suspend on a second diarized voice; remote base-label renames no
longer permanently claim later raw speech. Last-used setup remains editable,
but stale guests are excluded from prompts, ASR hints, saved titles, filenames,
and metadata. Enrollment no longer refreshes voice-profile recency. Profile
clips exclude other slots' finalized/tentative overlap, with the 12s cap kept.

Validation: session suite (including 11 checks demonstrated failing before
implementation), nudge suite, and signed Debug xcodebuild all pass. Logs are
in `.context/speaker-{session-final,nudges,build-final}.log`. Changelog staged
under Unreleased; no release tag, installation, or live-call interruption.
Added a real three-person-call checklist to `tests/calls-manual.md`; hardware
validation remains pending before release.

Reading Meet's tile names and active-speaker cues remains a separate
integration to prototype. Unknown guests currently need in-call naming;
profiles can be reused when the next call's guest list is confirmed.

## Current state (2026-09-16, branch `crxnamja/fix-meetingcoach-name`): Installed app filename fixed

The updated app's internals were already branded MeetMouse, but Sparkle kept
the original installed bundle URL, leaving `/Applications/MeetingCoach.app` in
Finder. Release builds now recognize only that exact legacy/rebranded bundle,
quit, rename it to `MeetMouse.app` via a post-exit helper, and relaunch. Debug
builds and existing destinations are guarded. `SUBundleName` is explicit for
Sparkle archive lookup; the legacy bundle ID and data paths remain unchanged.
Hygiene regression tests plus signed Debug and Release builds pass, and the
Release plist/signature verify.

## Prior state: Support email, downloads, and redirects complete

Cloudflare Email Routing is ready: `support@meetmouse.com` forwards to the
already-verified `noahkagan@gmail.com`, and the required MX, SPF, and DKIM
records are live. Customer-facing site and app support links use the branded
address. All 51 historical GitHub DMGs are now named `MeetMouse-*.dmg`; the live
Sparkle appcast points at the renamed latest asset, and future packaging already
uses the MeetMouse name. Active Cloudflare 301 rules canonicalize `www` and both
legacy `getmeetingcoach.com` hosts to `https://meetmouse.com` while preserving
paths and query strings. A test sent from Noah's Gmail to the support alias was
received by Cloudflare; its expected same-account deduplication notice arrived
in Noah's inbox, confirming the routing path.

## Prior state: MeetMouse Cloudflare live

`meetmouse.com` and `www.meetmouse.com` are active custom domains on the existing
Cloudflare Pages project, both backed by proxied CNAMEs to `meetcoach.pages.dev`.
The current green MeetMouse site is deployed; the apex returns 200 with the
MeetMouse title, and an active Cloudflare rule permanently redirects `www` to
the apex while preserving paths and query strings. The repository now owns the
Pages setup through root `wrangler.toml`, and release/manual deploy commands use
it. `/appsumo` is live and refreshed with the MeetMouse icon and green brand.
The GitHub repository is renamed from `noahdevkagan/coach` to
`noahdevkagan/meetmouse`; GitHub redirects the old URL and this checkout's
origin plus README clone instructions use the new URL. The legacy Cloudflare
project name stays in place to preserve history and the old domains. GitHub
still lacks `CLOUDFLARE_API_TOKEN`, so release deployments continue to skip
safely until a long-lived Pages:Edit token is added.

## Prior state: AppSumo media ready

The stale MeetingCoach AppSumo media is replaced by an upload-ready MeetMouse
kit in `design/appsumo/`: a transparent 512×512 company icon, a branded hero,
and four focused 1920×1080 gallery frames for live coaching, meeting review,
progress, and local privacy. Every upload image is PNG and under AppSumo's 5 MB
limit, uses the exact `MeetMouse` name and Noah green, and was inspected at
listing-thumbnail scale. Product screens use only the deterministic bundled demo
or aggregate dashboard data; the README records upload order, alt text, benchmark
links, listing cleanup, and image-generation provenance.

## Prior state: Black icon matte fixed

The supplied screenshot revealed that the green phone-listening source was RGBA
but its corner pixels were opaque black. The connected outer matte is now true
transparency; every app/site/in-app size was regenerated from the corrected
master. Alpha inspection, a signed Debug build, and a live screenshot of the
rebrand popup all pass. The app is running with the announcement reset.

## Prior state: Green in-app icon fixed

The header, welcome sheet, rebrand sheet, and Debug Dock badge load a named
green phone-listening mouse asset instead of `NSApp.applicationIconImage`, which
can retain the prior coral icon through Launch Services caching.

## Prior state: Noah green + phone MeetMouse built

The one-time “Meeting Coach is now MeetMouse” sheet is built and approved.
NoahKagan.com’s production green is now the full MeetMouse brand system:
`#2BBD3E` base, site-matched hover/active states, tint, live/detected, and
positive states. The selected mark is the existing phone-listening mouse on a
green tile; transparent source, macOS sizes 16–1024, and site icons regenerated.
Signed Debug build passes and is running with the announcement reset for review.

## Prior state: MeetMouse redesign synced

Merged the latest MeetMouse redesign branch
(`origin/crxnamja/squirrel-domain-rebrand`, tip `d5e6953`) onto current
`origin/main`. Conflict resolution preserves current transcript storage,
v0.19–0.22 behavior, and chronological benchmark history while carrying the
MeetMouse public name, coral/mouse visual system, site/package copy, and legacy
identity/data compatibility. Regenerated the Xcode project, changelog, and
sitemap. Verified a signed Debug build plus session and nudge suites; all pass.

## Prior state

## Current state (2026-09-04, branch `crxnamja/shanghai`): Granola-class reviews + smarter search — BUILT

Shipped on-branch this session (see decisions.md 2026-09-04 for the why):

1. **Review**: post-call prompt now produces topic-sectioned NOTES
   (`### topic` + dense factual bullets) and owner-tagged NEXT STEPS
   ("Action (owner) — detail"); `MeetingReview.sections` renders in the
   card, round-trips recapMarkdown, legacy reviews still parse. Review
   LLM budget 10240 ctx / 1200 predict (new `numPredict` on
   OllamaClient). Verified end-to-end against the real Noah/Nick 9/3
   transcript on qwen3.5:9b AND :4b — output quality is Granola-class,
   hallucination guards added from real failures.
2. **Search**: multi-word all-words matching (app + MCP server) with
   per-token highlighting, plus an "Ask AI" card in search results —
   `Engine/MeetingAsk.swift` retrieval (coverage-scored sessions, best
   14 lines + saved review) → local model answers with meeting
   citations. Verified live: "which agency would we fire first and why?"
   answered correctly from the saved 9/3 session.
3. Tests: session suite +11 checks (parse, round-trip, token search,
   ask retrieval); full push gate run at end of session.

Not done / follow-ups: changelog bullets (batch at next release tag);
real-GUI spot check of the Ask card and sectioned review card (harness-
verified only); consider surfacing Ask on Enter in the sidebar box.

## Prior state (2026-08-14; speaker-labeling plan added 2026-09-02)

- **In progress (branch `crxnamja/fix-speaker-labeling-1on1`): speaker
  labeling accuracy.** Shipped on-branch: same-person voice-profile dedupe
  at enrollment (field report: "anna" + "Anna Notario" both enrolled →
  split identity in a 1:1). Plan, approved by Noah ("just do 1 + 2"):
  1. Scoped enrollment — pre-call participants confirmed *for this call*
     (the form was actually submitted) ⇒ enroll only matching profiles;
     otherwise ⇒ cap at the 4 most recently used. New
     `expectedParticipants` on AudioCaptureManager, selection policy in
     VoiceProfileStore (pure + testable). The confirmed-only gate matters
     because `preCallContext` outlives a session by design.
  2. Merge card — when exactly two remote labels claim transcript words
     and they're probably one person (same-person names, or the pre-call
     form said 1:1), surface a one-tap merge via the existing
     SpeakerNameSuggestion bar (new `.samePerson` kind); vetoed when the
     labels' speech overlaps in time (one voice can't talk over itself).
  Deferred by choice: People model (profile UI + multi-clip refresh, Noah
  likes it), diarizer-variant benchmark (`ami`/`callhome`), backchannel
  inheritance.

## Prior state (2026-08-14)

- **v0.20.0 SHIPPED — visible Basic mode + lightweight model fallback.**
  The full CI gate passed; the signed/notarized DMG is published in both
  release repositories, the public appcast points to 0.20.0, and the changelog
  is live. The release also includes the one-on-one short-reply speaker-alias
  fix. Tag/commit: `v0.20.0` / `bdfce05`.
- **v0.19.1 SHIPPED — microphone invalid-format crash fix.** The app now
  retries a microphone that is still connecting, then reports a clean
  microphone-unavailable error instead of quitting.
- **Shipped with one known minor bug** (Noah's call, reviewed pre-ship):
  `ParakeetDownloadState.startIfNeeded` consumes the chained `onReady`
  on download failure, so a Retry that succeeds no longer fires it —
  MenuBarLabel's recommended-LLM auto-download chain dies until next
  launch. Fix: re-register surviving completions on failure. The old
  contract explicitly promised retry-then-fire.
- v0.18.0 speaker-naming manual hardware validation still owed
  (dual-channel 1:1, three-person call, next-session voice recognition,
  callout/pencil UI).

## Outstanding

- **Verify 0.20.0 in the wild:** exercise low-memory/busy-Mac Basic mode,
  fallback to a smaller installed model, the one-click lightweight download
  for a future session, and a named speaker's short one-on-one reply.
- **Verify multilingual mode in the wild:** no real non-English meeting has run yet
  (only the synthetic French canary). Also `tests/calls-manual.md` spot
  checks — the release reworked engine selection in
  `AudioCaptureManager.start()` and the matrix was not run.
- Fix the swallowed-`onReady` retry regression (above).
- Reply to Ned Donovan (neddonovan@gmail.com) — the call-truth behavior
  shipped in 0.17.1 (2026-08-10); check whether the reply ever went out.
- Conductor clones don't inherit `core.hooksPath` → pushes silently skip
  the gate (`git config core.hooksPath scripts/githooks` per clone). Also:
  the gate's docs-only short-circuit diffs `@{u}..HEAD`, so already-pushed
  code makes it false-skip — unset upstream to force a full run.
- Deferred: Core Audio process-tap experiment; streaming Parakeet decoder
  + other CPU/memory items (decisions.md).
- Carried: speaker identity on a real group call; Matt follow-up;
  coachfree AppSumo code verify; SEO distribution (newsletter/YouTube/PH,
  AlternativeTo, GSC sitemap); green-win placement + MCP packaging;
  Settings window polish; calendar/EventKit batch B (Noah-deferred);
  untracked `.agents/`/`.codex/` dirs left alone on purpose.

## Next session

v0.20.0 is live and auto-updating users. Next: verify Basic mode and the
lightweight fallback end-to-end on a busy Mac, then run a real Spanish or
French meeting plus the call-matrix spot checks on real hardware. After that,
fix the `startIfNeeded` retry regression.
