-- One-time challenges for App Attest key registration.
CREATE TABLE challenges (
  challenge TEXT PRIMARY KEY,
  expires_at INTEGER NOT NULL
);

-- App Attest keys, one per Tical installation. Nothing here identifies a person.
CREATE TABLE app_attest_keys (
  key_id TEXT PRIMARY KEY,
  app_id TEXT NOT NULL,
  public_key TEXT NOT NULL,
  counter INTEGER NOT NULL,
  environment TEXT NOT NULL,
  receipt TEXT,
  created_at INTEGER NOT NULL,
  last_used_at INTEGER NOT NULL
);

-- Daily counts for rate limits, removed after they expire.
CREATE TABLE usage (
  bucket TEXT PRIMARY KEY,
  uses INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
