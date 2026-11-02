-- Opt-in transcript fixes from the app (Settings → General → "Help improve
-- transcripts", off by default, separate from usage counts and coaching
-- feedback). One row per install per distinct "Fix a misheard term" pair:
-- the few words the transcriber heard and what the user changed them to
-- (each ≤5 words / 60 chars), scrubbed on the Mac and again here (no emails,
-- URLs, domains, 4+ digits, keys; names of people in the meeting never leave
-- the Mac). No transcript lines, audio, notes or titles. Purged after 180 days
-- by the daily cron; deleted on opt-out via DELETE /api/transcript-fixes/<id>.
CREATE TABLE transcript_fixes (
    install_id TEXT NOT NULL,
    heard_key TEXT NOT NULL,
    heard TEXT NOT NULL,
    corrected TEXT NOT NULL,
    engine TEXT NOT NULL,
    language TEXT NOT NULL,
    day TEXT NOT NULL,
    app_version TEXT NOT NULL,
    received_at INTEGER NOT NULL,
    PRIMARY KEY (install_id, heard_key, corrected)
);
CREATE INDEX transcript_fixes_received ON transcript_fixes (received_at);
