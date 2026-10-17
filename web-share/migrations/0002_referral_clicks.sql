-- Free-tier referral loop: one row per friend who clicked through
-- meetmouse.com/r/<code>/go. `friend` is a salted hash of IP + user agent;
-- nothing identifying is stored.
CREATE TABLE referral_clicks (
    code TEXT NOT NULL,
    friend TEXT NOT NULL,
    destination TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (code, friend)
);
