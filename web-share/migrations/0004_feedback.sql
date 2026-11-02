-- Opt-in coaching feedback from the app (Settings → General → "Help improve
-- coaching", off by default and separate from usage counts). One row per
-- rated nudge: which built-in signal fired, how the user rated it, and a few
-- numbers describing the moment. No text of any kind — no transcript, notes,
-- titles, names, or user-authored rubric ids (custom signals arrive only as
-- "custom"). Rows are purged after 180 days by the daily cron and deleted on
-- opt-out via DELETE /api/feedback/<install id>.
CREATE TABLE feedback_events (
    event_id TEXT PRIMARY KEY,
    install_id TEXT NOT NULL,
    day TEXT NOT NULL,
    signal TEXT NOT NULL,
    rating TEXT NOT NULL,
    minute INTEGER NOT NULL,
    meeting_type TEXT NOT NULL,
    you_share REAL,
    last_you_turn_sec REAL,
    turns_so_far INTEGER,
    app_version TEXT NOT NULL,
    received_at INTEGER NOT NULL
);
CREATE INDEX feedback_events_signal ON feedback_events (signal);
CREATE INDEX feedback_events_install ON feedback_events (install_id);
CREATE INDEX feedback_events_received ON feedback_events (received_at);
