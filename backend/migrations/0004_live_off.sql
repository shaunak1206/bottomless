-- Per-photo "Live" switch: 1 shows a Live Photo as a still (the motion clip is kept), like turning Live off in Photos.
ALTER TABLE assets ADD COLUMN live_off INTEGER NOT NULL DEFAULT 0;
