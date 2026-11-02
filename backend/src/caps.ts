// Hard spending guardrails. Google Cloud budgets only send emails; these limits make it impossible for a bug (or a
// leaked token) to run up the bill: past a cap the Worker refuses the request until the next month.
//   CAP_NEW_ASSETS_MONTH   new uploads per month (each costs storage requests)      default 40,000
//   CAP_DOWNLOAD_GB_MONTH  originals downloaded per month (retrieval + egress)       default 20 GB
//   CAP_STORED_GB          total originals kept                                     default 300 GB
import type { Env } from './env.ts';

const GB = 1024 ** 3;

export interface Caps { newAssetsMonth: number; downloadBytesMonth: number; storedBytes: number }

export function caps(env: Env): Caps {
  const num = (v: string | undefined, d: number) => (v !== undefined && v !== '' && Number.isFinite(Number(v)) ? Number(v) : d);
  return {
    newAssetsMonth: num(env.CAP_NEW_ASSETS_MONTH, 40_000),
    downloadBytesMonth: num(env.CAP_DOWNLOAD_GB_MONTH, 20) * GB,
    storedBytes: num(env.CAP_STORED_GB, 300) * GB,
  };
}

export function period(d = new Date()): string {
  return d.toISOString().slice(0, 7);
}

export interface Usage { newAssets: number; downloadBytes: number; storedBytes: number }

async function monthUsage(env: Env): Promise<{ newAssets: number; downloadBytes: number }> {
  const u = await env.DB.prepare('SELECT new_assets, download_bytes FROM usage WHERE period = ?').bind(period())
    .first<{ new_assets: number; download_bytes: number }>();
  return { newAssets: u?.new_assets ?? 0, downloadBytes: u?.download_bytes ?? 0 };
}

const STORED_TTL_MS = 3600_000;

async function sumStoredBytes(env: Env): Promise<number> {
  const s = await env.DB.prepare("SELECT COALESCE(SUM(size), 0) + COALESCE(SUM(paired_size), 0) AS b FROM assets WHERE status IN ('ready', 'trashed', 'pending')")
    .first<{ b: number }>();
  return s?.b ?? 0;
}

/** Bytes of originals kept. Summing every row on every upload read 28M rows in one afternoon of importing (D1's free
 *  tier allows 5M a day), so the total is cached in `counters` and recomputed at most hourly. */
export async function storedBytes(env: Env, maxAgeMs = STORED_TTL_MS): Promise<number> {
  const { results } = await env.DB.prepare("SELECT name, value FROM counters WHERE name IN ('stored_bytes', 'stored_bytes_at')")
    .all<{ name: string; value: number }>();
  const m = Object.fromEntries(results.map((r) => [r.name, r.value]));
  const now = Date.now();
  if (m.stored_bytes !== undefined && now - (m.stored_bytes_at ?? 0) < maxAgeMs) return m.stored_bytes;
  const b = await sumStoredBytes(env);
  const set = "INSERT INTO counters (name, value) VALUES (?, ?) ON CONFLICT(name) DO UPDATE SET value = excluded.value";
  await env.DB.batch([env.DB.prepare(set).bind('stored_bytes', b), env.DB.prepare(set).bind('stored_bytes_at', now)]);
  return b;
}

export async function usage(env: Env): Promise<Usage> {
  return { ...(await monthUsage(env)), storedBytes: await storedBytes(env) };
}

export class CapError extends Error {}

/** Called before a new asset is created; throws CapError when it would go over a cap, otherwise counts it. */
export async function admitUpload(env: Env, bytes: number): Promise<void> {
  const c = caps(env);
  const u = await monthUsage(env);
  if (u.newAssets + 1 > c.newAssetsMonth) {
    throw new CapError(`monthly upload limit reached (${c.newAssetsMonth} new items); resumes next month or raise CAP_NEW_ASSETS_MONTH`);
  }
  // The cached total can be up to an hour behind, so it is recounted exactly once the library is past half the cap.
  let stored = await storedBytes(env);
  if (stored + bytes > c.storedBytes / 2) stored = await storedBytes(env, 0);
  if (stored + bytes > c.storedBytes) {
    throw new CapError(`storage limit reached (${Math.round(c.storedBytes / GB)} GB); raise CAP_STORED_GB to store more`);
  }
  await env.DB.prepare(`INSERT INTO usage (period, new_assets) VALUES (?, 1)
      ON CONFLICT(period) DO UPDATE SET new_assets = new_assets + 1`).bind(period()).run();
}

/** Called before handing out a download link for an original. */
export async function admitDownload(env: Env, bytes: number): Promise<void> {
  const c = caps(env);
  const u = await monthUsage(env);
  if (u.downloadBytes + bytes > c.downloadBytesMonth) {
    throw new CapError(`monthly download limit reached (${Math.round(c.downloadBytesMonth / GB)} GB of originals); previews still work`);
  }
  try {
    await env.DB.prepare(`INSERT INTO usage (period, download_bytes) VALUES (?, ?)
        ON CONFLICT(period) DO UPDATE SET download_bytes = download_bytes + excluded.download_bytes`).bind(period(), bytes).run();
  } catch (e) {
    // When D1's free daily write limit is used up (a big first backup), still let photos and Live Photo clips open:
    // the cap above was checked, only this one download goes uncounted.
    if (!/D1/i.test(String(e)) || !/exceed|limit/i.test(String(e))) throw e;
  }
}
