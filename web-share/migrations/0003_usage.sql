-- Opt-in anonymous usage counts from the app (Settings → General, off by
-- default). One row per random install id per day; the id is minted on the
-- user's Mac when they opt in and deleted when they opt out. Counts only —
-- no audio, transcript, notes, titles or participants ever arrive here.
CREATE TABLE usage_days (
    install_id TEXT NOT NULL,
    day TEXT NOT NULL,
    meetings INTEGER NOT NULL,
    meeting_minutes INTEGER NOT NULL,
    nudges INTEGER NOT NULL,
    app_version TEXT NOT NULL,
    os_major INTEGER NOT NULL,
    received_at INTEGER NOT NULL,
    PRIMARY KEY (install_id, day)
);
CREATE INDEX usage_days_day ON usage_days (day);

-- Website "Download free" clicks through /get, one counter per day. No IP,
-- user agent or other visitor detail is stored.
CREATE TABLE download_days (
    day TEXT PRIMARY KEY,
    count INTEGER NOT NULL
);
