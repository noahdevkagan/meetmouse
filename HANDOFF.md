# HANDOFF — session seed

Auto-injected into every Claude session in this repo (SessionStart hook in
`.claude/settings.json`). Rewritten by `/handoff` at the end of a session.
Keep it short: current state, outstanding work, and the prompt to start from.
The durable "why" behind choices goes in `decisions.md`, not here.

## Current state (2026-09-21): Merge social/site and release main updates — resolved

Merged origin/main's social-card/site generator updates and strict Worker release
deployment. Only benchmark histories conflicted; both branches' records are retained
in date order and validated as JSON. App sources unchanged; incoming site and
workflow files match main. Push-gate validation pending.

## Current state (2026-09-21): Merge release/site main updates — validated

Merged latest origin/main's homepage restyle, best-effort Worker deployment, and
released 0.25.1 changelog. Resolved the changelog conflict by preserving released
notes exactly and retaining automatic AI-note generation under Unreleased.
App source unchanged. Full push gate passed with no scorecard regressions; merge
pushed to PR #17. Log: .context/merge-site-main-push.log.

## Current state (2026-09-21): Merge release-workflow main update — validated

Merged latest origin/main's Worker release deployment and release instructions.
Resolved only benchmark-history conflicts, keeping both branches' records in
chronological order. JSON validation confirms no record from either branch lost;
app sources and release workflow match their intended parents. Full push gate
passed with no scorecard regressions; merge pushed to PR #17. Validation log:
.context/merge-release-main-push.log.
The previously validated Share notes implementation remains unchanged.

## Current state (2026-09-21): Merge latest main — validated

Merged origin/main's direct-link sharing and icon-only settings updates. Share notes
now generates missing AI notes, then creates/copies the encrypted link directly.
Existing notes immediately enter link creation; progress/errors and review reuse
remain. Updated help text, changelog, and decisions to match the combined flow.

Validation: merged Debug build and full push gate passed, including 36 sharing
checks; scorecard found no regressions. Log: .context/merge-main-push.log.
Merge committed and pushed to PR #17; PR description matches the direct-link flow.
No real meeting uploaded or installed app changed; live AI-to-link verification
remains outstanding.

## Current state (2026-09-21): Direct note sharing — built

Share notes immediately creates/copies the curated encrypted snapshot, then shows
Private link ready without the extra preview/confirmation. Includes a loading
state and explicit retry on failure; existing shared-link management remains.
The user-authorized checkpoint change is recorded in decisions.md.
Validation: Debug xcodebuild, 23 Swift sharing checks, and 13 Node checks pass.
Logs: .context/direct-share-{build,tests}.log. No app launch, upload, or release.

## Current state (2026-09-21): Icon-only AI provider settings

Sidebar AI provider settings now shows only the gear icon, retaining its accessible
name and hover tooltip. Debug xcodebuild and git diff --check pass.
Build log: `.context/icon-only-build.log`.

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

## Current state: Review fixes — complete (2026-09-21)

Applied both review fixes on the reviewed redesign/sharing baseline (892832b).
Missing-ID revocations share creation's client-IP quota; existing owners can
still revoke when quota is exhausted. Long chat turns preserve source labels
and select bounded context around the strongest query matches.

Validation: Debug xcodebuild succeeds; 169 session checks, 23 Swift sharing
checks, and 13 Node checks pass. New coverage includes allocation denial,
revocation under exhausted quota, shared client keys, late-turn evidence,
Unicode, and small context budgets. Logs: .context/{session-fixes,sharing-fixes,
review-fixes-build}.log. No deployment or replacement of the running app;
the Worker must be deployed and the new app launched for these fixes to be live.

## Current state: Push build failure diagnosis — 2026-09-21

User's initial push failed at build; hook discarded Xcode diagnostics. Capture build output
in .context/push-gate-build.log, preserve xcodebuild exit status, and print actual
errors on failure. Local reproduction is blocked earlier by sandbox cache access,
so do not attribute the user's unsandboxed failure to those permission errors.

## Current state: Review fixes and shared-page consistency — implemented, deployment pending

Implemented all four findings: cross-process flock + reload transactions; pending
owner capability saved before upload; Shared links manager on Meetings survives
local deletion; selected meeting observes review completion/generation state.
Worker revocation now retains empty-ciphertext tombstones so late uploads cannot
resurrect cancelled links. Uses existing schema; deploy updated Worker with app.
Web v4 styling matches Dorado light/dark tokens and system fonts, with MeetMouse
branding and smaller headings. Synthetic local previews: .context/share-preview-
light.html and share-preview-dark.html. Browser policy blocked local-file visual
inspection; no visual QA claim. Production still needs deployment.
Validation: 23 Swift sharing checks + 11 Node checks pass, including actual two-
process storage writes, timeout recovery, finalize-write failure, and SQLite-backed
Worker auth/expiry/late-create tests. Real sharing UI/models typecheck Swift 6;
Swift parse and diff checks pass. Full app build/runtime remain blocked as recorded
below. No release, production upload, or deployment performed.

## Current state (2026-09-20): Full code review — source review complete

Workspace restored. Source review completed; report: .context/code-review.md.
Four findings: multi-instance store overwrites revocation controls (reproduced),
upload before durable recovery state, deleting shared meetings removes revoke UI,
and post-call notes fail to refresh after asynchronous review completion. No fixes
applied. 20 sharing + 11 chat/citation + 10 simulated Worker route checks pass;
sharing UI typechecks. Full build blocked by GitHub DNS; session suite blocked by
Observation macro sandbox. Native/UI/live deployment tests remain outstanding.
No release or deployment.

## Current state (2026-09-20): Respectful sharing growth — source ready

Send is prominent after link creation. Recipients can forward the full encrypted
link or copy formatted notes/next steps with the private link and a small MeetMouse
attribution. A single product invitation follows the content. No signup gate, forced
referral, auto-send, or analytics. Opt-in upload and privacy are preserved.
Validation: 12 Swift + 8 Worker/viewer checks pass, including formatting, cancellation
and fragment preservation. Updated real sharing sheet typechecks with Swift 6.
Recipient changes still require the Cloudflare deployment described below.

## Current state (2026-09-20): Restored opt-in web sharing — source ready

Recovered the existing sharing implementation from ../milan and integrated it into
this redesigned app. Share notes sits beside the saved meeting's tabs; if notes are
not yet eligible, it opens Notes with an explanation to generate AI notes. Preview
then Create private link publishes only curated notes/next steps, AES-GCM encrypted,
with Copy/Open/Send and Stop sharing. Chat/transcript/coaching are excluded. Both
Debug and Release default to the already-deployed rhinovoice.app Cloudflare service.
Existing link records/revocation capabilities stay compatible.

Ported web-share/ Worker+D1 source and tests/sharing; added sharing to push gate.
Recipient source now says MeetMouse and links to meetmouse.com, with versioned assets.
Existing D1/routes are preserved. DO NOT create replacement database/resources.
The web rebrand still needs `cd web-share && npm ci && npm run deploy` from an
unrestricted terminal; current sandbox DNS cannot reach Cloudflare/rhinovoice.app.
Backend deployment was verified in milan on Sep 17; not reverified live this turn.

Validation: 12 Swift sharing checks + 8 Worker/viewer checks pass; real sharing sheet,
models and Dorado typecheck under Swift 6. Xcode project regenerated and Swift parse /
whitespace checks pass. Full app build remains blocked by the existing sandbox macro
restriction. Rebuild dev in user's terminal to expose the new control. No personal
meeting uploaded, no messages sent, no release or push.

## Current state (2026-09-20): Durable chat, citations, scroll following — source ready

Implemented the three requested improvements:
- Completed Q&A persists atomically beside each transcript in .chat.json. Restored
  on reopen; clear requires confirmation and preserves notes/transcript. Delete
  session removes the chat. Read/write failures remain visible, with save retry.
- Actual timestamp matches in answers link to Transcript, scroll to the source
  row and highlight it. Unmatched model citations stay plain text.
- Native user scrolling away from the bottom pauses live following. Back to live
  resumes it. The observer ignores content growth/programmatic scrolling.

11 standalone regression checks against real Foundation source pass (persistence,
clear, corruption, isolation, missing transcript, Unicode and exact citations).
Added those plus deletion lifecycle coverage to tests/session/main.swift. The full
session suite and app typecheck cannot run: sandbox blocks Observation macro plugin
execution. Native scroll observer typechecks against Swift 6/AppKit. Swift parse
and git diff --check pass. No claim of a full app build or visual QA for these latest
changes; rebuild in the user's unrestricted terminal, then check clicks/scrolling.
No release/push. Sidebars also hide scroll indicators (previous small request).

## Current state (2026-09-20): Sidebar scrollbar refinement

Noah built the updated dev app in his own terminal and says the sidebar is much
better. Hid scroll indicators in both sidebar scroll regions (meeting library and
Advanced), preserving scrolling. This small follow-up is source-only pending his
next rebuild; Swift frontend parse and whitespace checks pass. The build sandbox
limitation documented below remains. Suggested next improvements: persist meeting
chat, clickable answer citations, and automatic scroll pause while reading history.

## Current state (2026-09-20): Sidebar polish + default-open coaching — source ready

Noah wants coaching visible during calls because he checks it routinely. Restored
an open-by-default resizable coaching pane with talk-share stats; the header button
hides/shows it, and each new meeting opens it again. Header sits above both panes.

Screenshot feedback drove sidebar cleanup: removed the outer cards, compact native
Start button, larger search field, two-line meeting rows with dates below titles,
selected-row highlight, and quieter typography. Replaced the saved-path/Keep/Delete
block with a single Meeting saved row and an actions menu (Dismiss, Show in Finder,
Delete meeting). Saving behavior stays unchanged.

Validation: Swift frontend parse and git diff --check pass. Full build BLOCKED by
current sandbox denying writes to ~/Library/Caches/org.swift.swiftpm/manifests.
A later build redirected caches using -IDEPackageCacheDirPath=<workspace cache>
and -IDEDisablePackageManifestCaching=YES plus SWIFTPM_MODULECACHE_OVERRIDE.
That got past cache writes but hit sandbox-exec: sandbox_apply: Operation not
permitted while resolving packages. Latest log: .context/launch-dev-local-cache.log.
Updated binary could not be built/launched from this restricted session.
Logs: `.context/coach-default-build.log`, `.context/sidebar-polish-build.log`.
These latest changes are NOT in the running Debug preview and still need a normal
Xcode build plus light/dark sidebar inspection. Earlier September 17 build/tests
below apply only to the previous implementation. No app restart, release, or push.

## Current state (2026-09-17): Live transcript + window polish — built

Live transcript now uses a centered reading column, 15pt text, speaker/time headers,
and generous turn spacing. The fixed coaching rail is replaced by an on-demand
popover containing talk-share stats and coaching history. A compact header keeps
status, elapsed time, auto-scroll toggle, Coach, and Stop accessible even with the
new slimmer sidebar hidden. Sidebar toggle is in the title bar (Ctrl-Cmd-S).
Existing speaker naming, word correction, capture warnings, and coaching logic stay.

Signed Debug build passes (`.context/live-design-build-final.log`); diff check clean.
Ran the permission-free demo and inspected transcript with sidebar shown/hidden,
auto-scroll pause, and coaching popover. No audio capture or installed-app processes
touched. Debug preview remains open on the demo transcript. UI-only changes; no
new tests or release. Prior 154 session checks remain the latest engine validation.

## Current state (2026-09-17): Chat-first MeetMouse — built for review

Noah clarified: chat is the main product; coaching is valuable but secondary.
Implemented meetings home, Chat as the default saved-meeting tab, a pinned
composer, starter questions, copy/view-transcript controls, Stop/retry, and
secondary coaching-progress navigation. Existing global AI search is reachable
from the home and sidebar. Completed saved meetings open directly into chat;
search results still open the highlighted transcript.

Q&A reuses local Ollama. Retrieval carries prior question subjects, includes
neighboring turns and final-turn coverage, and enforces a total context budget.
Prompts request timestamps and distinguish commitments from suggested next steps.
Cancellation checks and per-meeting view identity prevent stale answers crossing
meetings. Notes reload on tab changes and before answering.

Validation: signed Debug build passes (`.context/chat-build-final.log`), all 154
session checks pass (`.context/chat-session.log`), diff whitespace check clean.
Inspected home/chat visually; real local answer, follow-up, Stop, and retry worked.
The installed granite4:3b initially confused anecdotes with follow-ups; tighter
instructions improved the tested answer, but this is not a broad quality benchmark.
Long meetings use selected excerpts. Chat history is still in-memory for the open
meeting, not persisted across visits. Debug preview is running; no release or push.

Conductor rename remains unresolved: repository actions and Git/Misc settings have
no rename control, and CLI supports only workspace/session renames. Did not alter
managed paths or internal database. Ask Conductor support about repository labels.

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


2026-09-21 push follow-up: user confirmed app build PASS. ASR SwiftPM checkout
failed looking up the pinned FluidAudio revision. Revision/tree exist in dependency
repo; reproduced failed lookup when parent GIT_DIR is inherited. push-gate.sh now
clears git rev-parse --local-env-vars after resolving its workspace so SwiftPM Git
commands use dependency repos. Shell syntax/whitespace checks pass; read-only
reproduction resolves the pinned tree after clearing env. Full gate still needs
user Terminal. Diagnostic logging and this fix remain uncommitted locally.
