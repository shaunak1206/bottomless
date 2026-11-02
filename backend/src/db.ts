import type { Env } from './env.ts';

export interface AssetRow {
  id: string; sha256: string; md5: string | null; kind: 'photo' | 'video' | 'live'; mime: string; size: number;
  filename: string | null; width: number | null; height: number | null; duration: number | null; taken_at: number;
  lat: number | null; lon: number | null; favorite: number; hidden: number; original_key: string;
  paired_key: string | null; paired_size: number | null; paired_md5: string | null; paired_mime: string | null;
  has_thumb: number; has_preview: number; live_off: number; status: 'pending' | 'ready' | 'trashed' | 'purged';
  created_at: number; updated_at: number; trashed_at: number | null; seq: number;
}

// What the app sees (camelCase, booleans, no storage keys).
export function toApi(r: AssetRow) {
  return {
    id: r.id, sha256: r.sha256, kind: r.kind, mime: r.mime, size: r.size, filename: r.filename,
    width: r.width, height: r.height, duration: r.duration, takenAt: r.taken_at, lat: r.lat, lon: r.lon,
    favorite: !!r.favorite, hidden: !!r.hidden, liveOff: !!r.live_off, hasPaired: !!r.paired_key, pairedMime: r.paired_mime,
    pairedSize: r.paired_size, hasThumb: !!r.has_thumb, hasPreview: !!r.has_preview, status: r.status,
    createdAt: r.created_at, updatedAt: r.updated_at, trashedAt: r.trashed_at, seq: r.seq,
  };
}

export async function getAsset(env: Env, id: string): Promise<AssetRow | null> {
  return env.DB.prepare('SELECT * FROM assets WHERE id = ?').bind(id).first<AssetRow>();
}

export async function getBySha(env: Env, sha256: string): Promise<AssetRow | null> {
  return env.DB.prepare('SELECT * FROM assets WHERE sha256 = ?').bind(sha256).first<AssetRow>();
}

// Apply `set` to one asset and move it to the head of the change feed, atomically.
export async function updateWithSeq(env: Env, id: string, set: string, binds: unknown[]): Promise<void> {
  const now = Date.now();
  await env.DB.batch([
    env.DB.prepare("UPDATE counters SET value = value + 1 WHERE name = 'seq'"),
    env.DB.prepare(`UPDATE assets SET ${set}, updated_at = ?, seq = (SELECT value FROM counters WHERE name = 'seq') WHERE id = ?`)
      .bind(...binds, now, id),
  ]);
}
