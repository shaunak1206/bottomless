-- Monthly usage counters behind the spending guardrails (see caps.ts). period = 'YYYY-MM' (UTC).
CREATE TABLE usage (
  period          TEXT PRIMARY KEY,
  new_assets      INTEGER NOT NULL DEFAULT 0,
  download_bytes  INTEGER NOT NULL DEFAULT 0
);
