-- Every index costs a row write on each insert and on each change to its column. Nothing filters or sorts on
-- taken_at server side (the app sorts its own catalog), and status is only filtered by the daily cleanup, so both
-- go: a new photo now costs about 8 row writes instead of 13 (D1's free tier allows 100,000 a day).
DROP INDEX IF EXISTS idx_assets_taken;
DROP INDEX IF EXISTS idx_assets_status;
