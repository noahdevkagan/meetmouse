-- Team space: one private page per team (meetmouse.com/t/<id>#<secret>).
-- Everything readable is encrypted on a member's Mac with a key derived
-- from the team secret, which lives only in the invite link's fragment.
-- `access_hash` is SHA-256 of an access token derived from the same secret;
-- it lets members list and add notes without the server learning the secret.
CREATE TABLE teams (
    id TEXT PRIMARY KEY NOT NULL,
    access_hash TEXT NOT NULL,
    name_nonce TEXT NOT NULL,
    name_ciphertext TEXT NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE TABLE team_notes (
    team_id TEXT NOT NULL,
    id TEXT NOT NULL,
    nonce TEXT NOT NULL,
    ciphertext TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    PRIMARY KEY (team_id, id)
);

CREATE INDEX team_notes_recent ON team_notes (team_id, created_at DESC, id DESC);
CREATE INDEX team_notes_expires_at ON team_notes (expires_at);
