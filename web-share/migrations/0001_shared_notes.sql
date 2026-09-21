CREATE TABLE shared_notes (
    id TEXT PRIMARY KEY NOT NULL,
    schema_version INTEGER NOT NULL,
    nonce TEXT NOT NULL,
    ciphertext TEXT NOT NULL,
    revoke_hash TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
);

CREATE INDEX shared_notes_expires_at ON shared_notes (expires_at);
