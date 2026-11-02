-- Albums copied from the iPhone (and later ones made in Bottomless), kept in the cloud so they survive the photos being
-- removed from the phone. Membership rows are clustered on their key (WITHOUT ROWID): one row write per photo added.
CREATE TABLE albums (
  id          TEXT PRIMARY KEY,
  title       TEXT NOT NULL,
  source      TEXT NOT NULL,            -- 'iphone'
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);
CREATE TABLE album_items (
  album_id  TEXT NOT NULL,
  asset_id  TEXT NOT NULL,
  added_at  INTEGER NOT NULL,
  PRIMARY KEY (album_id, asset_id)
) WITHOUT ROWID;
