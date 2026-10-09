# Manual call matrix — run before any capture-adjacent release

CI cannot simulate FaceTime or iPhone-relayed calls, and capture failures
in this area are silent by design (silent buffers keep every watchdog
happy). This checklist is the coverage. It takes ~10 minutes with a
second phone. Run it on real hardware whenever a release touches
`AudioCaptureManager`, `MeetingDetectionService`, `MeetingDetector`, or
the silence/end logic — and record the date + build at the bottom.

Watch the log during every scenario:

```bash
tail -f /tmp/mc_debug.log | grep -E "Detect|Mic|Capture|Silence|Apple process"
```

## Scenarios

### 1. FaceTime call answered on the Mac
Calls taken on the Mac are UNCAPTURABLE, full stop: macOS hard-walls
the mic (digital zeros to every other client — AUHAL and VPIO both)
and SCK from call audio. Live-verified 2026-08-09 (decisions.md).
Expected behavior is the truth card, immediately:
- [ ] "Meeting detected" pill appears (labeled FaceTime), chirp plays
- [ ] Start coaching: orange card reads **"macOS blocks apps from
      hearing this call"** (iPhone-speakerphone / meeting-app guidance,
      NO "Open Settings" button); log: `[Capture] Apple call in progress`
- [ ] No fake transcript: nothing labeled "You"/"Them", talk-time does
      NOT climb while you talk
- [ ] Log shows periodic `all-zero ... rebuilding capture` lines (the
      zero-audio watchdog probing for the mic to come back)
- [ ] Hang up, keep the session running: capture recovers by itself
      within ~15s (watchdog rebuild lands on a live mic; room speech
      transcribes again)

### 2. iPhone cellular call answered ON the Mac (relay)
- [ ] Pill appears (FaceTime/Phone call label). If it does NOT, check the
      log for `Apple process holding mic (ignored): <id>` — that id
      belongs in `appleCallBundleIDs` (MeetingDetectionService); add it.
- [ ] Same truth card as scenario 1
- [ ] BONUS check: answer the same call on the iPhone instead, on
      speakerphone next to the Mac — session transcribes both sides via
      the room mic (this is the workaround the card recommends)

### 3. Call answered on the iPhone, Mac shows the call widget
This is the **uncapturable** case — the Mac has no audio path. Expected
behavior is honesty, not magic:
- [ ] Within ~3 minutes of a started session: orange card reads
      **"Can't hear this meeting"** with the iPhone/headset guidance —
      NOT "Meeting ended?"
- [ ] Log: `showing capture-gap warning`
- [ ] Session is NOT auto-stopped while the call is live

### 4. Handoff mid-call (iPhone → Mac)
- [ ] Start on the iPhone mid-session, hand off to the Mac
- [ ] Log shows mic recovery (`[Mic] Capture restarted` or pin lines),
      and transcription resumes within ~10s of the handoff
- [ ] Default input pinned away from the Continuity mic
      (`ccwd`/`ccwl`) — check the `[Mic]` lines

### 5. Call answered mid-session (Go Live first, then answer)
The mic zeros out the moment the call connects, with no config-change
notification — only the zero-audio watchdog catches it:
- [ ] Start a session, then answer a FaceTime call
- [ ] Within ~10s the log shows `all-zero ... rebuilding capture` and
      `Apple call grabbed the mic mid-session ... adopting call mode`
- [ ] Hang up: capture recovers, transcription resumes

### 5b. Far side lost mid-call: headset / output device change (2026-10-08 field report)
A Teams call on a headset lost the other person for 30 minutes with the
status still reading "Listening (you + them)". SCK delivers buffers
continuously while alive, so the new watchdog treats a quiet stream as dead.
- [ ] On a Zoom/Meet/Teams call with the other side talking, connect a
      Bluetooth headset (or switch output in Sound settings) mid-session
- [ ] Log: `Default output device changed → <name>`; "Them" text keeps
      arriving after the switch with NO restart line (SCK survives the
      switch). If a `no buffers for … rebuilding stream` line follows the
      switch instead, the watchdog has caught a real stall — note the
      headset model
- [ ] Lock the screen for 15s, unlock: log shows `System audio stream
      stopped` → `System audio restarted (stream stopped…)`; "Them" resumes
- [ ] Revoke Screen Recording mid-call: within ~20s the status reads
      "Can't hear the other side — reconnecting…"; re-grant and the log
      shows `System audio back — dual pipelines active again`

### 6. Speaker names on a three-person Meet call (2026-09-17 regression)
- [ ] Leave Anna in the last-used setup, then start via Go Live without
      submitting setup. On a call with two different remote guests, neither
      live partials nor new diarized slots should display Anna
- [ ] Name the first guest's numbered speaker. Before the second guest has
      spoken, unassigned live text still says Them; once both speak, their
      turns retain separate numbered/named labels
- [ ] Repeat with both guests confirmed in setup: saved voices may name
      their own turns, but unassigned text never borrows the first name
- [ ] Confirm a single guest in setup: provisional naming works, then
      suspends if a second remote voice is detected
- [ ] Rename both speakers, stop, and inspect the saved transcript and JSON:
      unknown-call participant metadata uses this call's named speakers,
      never the unconfirmed last-used guest
- [ ] Include overlapping speech before naming a speaker; verify their
      saved voice clip contains solo speech (or no profile saves when less
      than three seconds of solo speech is available)

### 7. Opt-in speaker snapshots (Zoom-style green/yellow outlines)
- [ ] With automatic speaker snapshots off (default), start a real meeting:
      no screenshot assistance runs until explicitly
      allowed. Open the consent sheet, cancel, and verify it remains off
- [ ] With one recognized meeting window, consent automatically names the app
      and window without requiring a picker. With two calls or no recognized
      window, select manually; unrelated windows are never auto-selected
- [ ] Allow the detected meeting window (or use Choose another window). Observe no focus changes, sounds,
      or window movement; macOS capture indicators remain available
- [ ] Two remote guests take sustained turns with visible name labels and
      active-speaker outlines. Up to six snapshots produce tentative matches;
      verify each proposed name against the actual speaker before confirming
- [ ] Dismiss a match: it stays dismissed. Confirm a match: only that voice is
      renamed, with the existing voice-profile behavior
- [ ] Chat/sidebar names, multiple highlighted tiles, missing names, and
      overlapping voices do not produce confident automatic renames
- [ ] Minimize/close the selected window or switch a browser tab to a different
      title: capture stops without switching to another window or the desktop
- [ ] Stop assistance mid-run; stop the meeting; force mic-only fallback:
      each cancels pending capture and removes unconfirmed visual matches
- [ ] Enable automatic speaker snapshots in General settings or the consent sheet.
      Next meeting starts snapshots of one recognized window without a new prompt;
      two/no recognized windows require manual selection. Disable the setting and
      verify the next meeting takes no snapshots until explicitly allowed
- [ ] Stop while “Finding your meeting window” is visible: delayed discovery must
      not start capture. New meetings and mic-only fallback also cancel discovery
- [ ] Restarting assistance in the same meeting never exceeds six total requests
- [ ] With cloud AI selected, verify no images or raw OCR enter provider
      requests or saved files. Confirmed speaker names are ordinary transcript
      text and follow the existing cloud-text consent

## Record of runs

| Date | Build | Scenarios passed | Notes |
|------|-------|------------------|-------|
| —    | —     | —                | first run pending |
