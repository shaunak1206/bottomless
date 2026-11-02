-- People: faces found by the Mac indexer (scripts/faces.py) grouped by who they are. A face's box is a fraction of
-- the photo's width and height (x, y = top left). The face embeddings stay on the Mac; only the grouping lives here,
-- so naming, merging and hiding people on the phone survive the indexer running again.
CREATE TABLE people (
  id          TEXT PRIMARY KEY,
  name        TEXT,
  hidden      INTEGER NOT NULL DEFAULT 0,
  cover_face  TEXT,                     -- face shown as the person's picture (the best face when unset)
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);
CREATE TABLE faces (
  id          TEXT PRIMARY KEY,
  asset_id    TEXT NOT NULL,
  person_id   TEXT,
  x REAL NOT NULL, y REAL NOT NULL, w REAL NOT NULL, h REAL NOT NULL,
  score       REAL NOT NULL,
  rejected    TEXT                      -- person this face was taken out of ("Not this person"); never put back there
);
-- 'version': bumped on every change, so the phone only downloads the people list when something moved.
CREATE TABLE people_meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
