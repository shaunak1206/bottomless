-- One row per photo or video. `seq` is the change feed: every write sets it to the next value of counters.seq,
-- and the app pulls rows with seq > its cursor.
CREATE TABLE assets (
  id            TEXT PRIMARY KEY,
  sha256        TEXT NOT NULL UNIQUE,
  md5           TEXT,
  kind          TEXT NOT NULL CHECK (kind IN ('photo', 'video', 'live')),
  mime          TEXT NOT NULL,
  size          INTEGER NOT NULL,
  filename      TEXT,
  width         INTEGER,
  height        INTEGER,
  duration      REAL,
  taken_at      INTEGER NOT NULL,              -- unix ms
  lat           REAL,
  lon           REAL,
  favorite      INTEGER NOT NULL DEFAULT 0,
  hidden        INTEGER NOT NULL DEFAULT 0,
  original_key  TEXT NOT NULL,
  paired_key    TEXT,                          -- the video half of a Live Photo
  paired_size   INTEGER,
  paired_md5    TEXT,
  paired_mime   TEXT,
  has_thumb     INTEGER NOT NULL DEFAULT 0,
  has_preview   INTEGER NOT NULL DEFAULT 0,
  status        TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'ready', 'trashed', 'purged')),
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL,
  trashed_at    INTEGER,
  seq           INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_assets_seq ON assets (seq);
CREATE INDEX idx_assets_taken ON assets (taken_at);
CREATE INDEX idx_assets_status ON assets (status);

CREATE TABLE counters (name TEXT PRIMARY KEY, value INTEGER NOT NULL);
INSERT INTO counters (name, value) VALUES ('seq', 0);

-- Expiring public links to a set of assets (served at /s/<token>).
CREATE TABLE shares (
  token          TEXT PRIMARY KEY,
  title          TEXT,
  asset_ids      TEXT NOT NULL,                -- JSON array
  allow_original INTEGER NOT NULL DEFAULT 0,
  created_at     INTEGER NOT NULL,
  expires_at     INTEGER NOT NULL
);
