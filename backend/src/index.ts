import type { Env } from './env.ts';
import { getAsset, getBySha, toApi, updateWithSeq, type AssetRow } from './db.ts';
import { blobSignature, originalStore } from './originals.ts';
import { sharePage } from './share.ts';
import { admitDownload, admitUpload, caps, usage, CapError } from './caps.ts';

const MAX_THUMB = 2 * 1024 * 1024;
const MAX_PREVIEW = 15 * 1024 * 1024;

class HttpError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

function json(data: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json', ...headers } });
}

async function authorized(req: Request, env: Env): Promise<boolean> {
  const h = req.headers.get('Authorization') ?? '';
  const m = /^Bearer (.+)$/.exec(h);
  if (!m || !env.APP_TOKEN) return false;
  const a = new TextEncoder().encode(m[1]);
  const b = new TextEncoder().encode(env.APP_TOKEN);
  if (a.byteLength !== b.byteLength) return false;
  return crypto.subtle.timingSafeEqual(a, b);
}

async function body<T>(req: Request): Promise<T> {
  try { return await req.json() as T; } catch { throw new HttpError(400, 'invalid JSON body'); }
}

const HEX64 = /^[0-9a-f]{64}$/;
const HEX32 = /^[0-9a-f]{32}$/;

interface PrepareBody {
  sha256: string; md5?: string; size: number; mime: string; kind: 'photo' | 'video' | 'live';
  filename?: string; takenAt: number; width?: number; height?: number; duration?: number;
  lat?: number; lon?: number; favorite?: boolean;
  paired?: { size: number; md5?: string; mime: string };
}

function validatePrepare(b: PrepareBody): void {
  if (!HEX64.test(b.sha256 ?? '')) throw new HttpError(400, 'sha256 must be 64 lowercase hex chars');
  if (b.md5 !== undefined && !HEX32.test(b.md5)) throw new HttpError(400, 'md5 must be 32 lowercase hex chars');
  if (!Number.isInteger(b.size) || b.size < 0) throw new HttpError(400, 'size must be a non-negative integer');
  if (typeof b.mime !== 'string' || !b.mime.includes('/')) throw new HttpError(400, 'mime is required');
  if (!['photo', 'video', 'live'].includes(b.kind)) throw new HttpError(400, 'kind must be photo, video or live');
  if (typeof b.takenAt !== 'number' || !Number.isFinite(b.takenAt)) throw new HttpError(400, 'takenAt (unix ms) is required');
  if (b.paired && (!Number.isInteger(b.paired.size) || typeof b.paired.mime !== 'string')) throw new HttpError(400, 'paired needs size and mime');
  if (b.paired?.md5 !== undefined && !HEX32.test(b.paired.md5)) throw new HttpError(400, 'paired.md5 must be 32 hex chars');
}

async function uploadPlan(env: Env, a: AssetRow, origin: string) {
  const store = originalStore(env);
  const uploads: Record<string, unknown> = { original: await store.uploadTarget(a.original_key, a.mime, origin) };
  if (a.paired_key) uploads.paired = await store.uploadTarget(a.paired_key, a.paired_mime ?? 'video/quicktime', origin);
  return {
    status: 'upload', assetId: a.id, uploads,
    derived: { thumb: `/v1/assets/${a.id}/thumb`, preview: `/v1/assets/${a.id}/preview` },
  };
}

async function prepare(req: Request, env: Env, origin: string): Promise<Response> {
  const b = await body<PrepareBody>(req);
  validatePrepare(b);
  const existing = await getBySha(env, b.sha256);
  if (existing && (existing.status === 'ready' || existing.status === 'trashed')) {
    return json({ status: 'exists', assetId: existing.id, asset: toApi(existing) });
  }
  const now = Date.now();
  if (existing) {
    if (existing.status === 'purged') await admitUpload(env, b.size + (b.paired?.size ?? 0));
    // A pending (interrupted) upload or a purged asset coming back: reuse the row and hand out fresh URLs.
    await env.DB.prepare(`UPDATE assets SET md5 = ?, kind = ?, mime = ?, size = ?, filename = ?, width = ?, height = ?,
        duration = ?, taken_at = ?, lat = ?, lon = ?, favorite = ?, paired_key = ?, paired_size = ?, paired_md5 = ?,
        paired_mime = ?, status = 'pending', trashed_at = NULL, has_thumb = 0, has_preview = 0, updated_at = ? WHERE id = ?`)
      .bind(b.md5 ?? null, b.kind, b.mime, b.size, b.filename ?? null, b.width ?? null, b.height ?? null,
            b.duration ?? null, b.takenAt, b.lat ?? null, b.lon ?? null, b.favorite ? 1 : 0,
            b.paired ? `o/${existing.id}.pair` : null, b.paired?.size ?? null, b.paired?.md5 ?? null,
            b.paired?.mime ?? null, now, existing.id).run();
    return json(await uploadPlan(env, (await getAsset(env, existing.id))!, origin));
  }
  await admitUpload(env, b.size + (b.paired?.size ?? 0));
  const id = crypto.randomUUID();
  await env.DB.prepare(`INSERT INTO assets (id, sha256, md5, kind, mime, size, filename, width, height, duration, taken_at,
      lat, lon, favorite, original_key, paired_key, paired_size, paired_md5, paired_mime, status, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)`)
    .bind(id, b.sha256, b.md5 ?? null, b.kind, b.mime, b.size, b.filename ?? null, b.width ?? null, b.height ?? null,
          b.duration ?? null, b.takenAt, b.lat ?? null, b.lon ?? null, b.favorite ? 1 : 0, `o/${id}`,
          b.paired ? `o/${id}.pair` : null, b.paired?.size ?? null, b.paired?.md5 ?? null, b.paired?.mime ?? null, now, now)
    .run();
  return json(await uploadPlan(env, (await getAsset(env, id))!, origin), 201);
}

async function putDerived(req: Request, env: Env, a: AssetRow, which: 'thumb' | 'preview'): Promise<Response> {
  const limit = which === 'thumb' ? MAX_THUMB : MAX_PREVIEW;
  const len = Number(req.headers.get('Content-Length') ?? 0);
  if (len > limit) throw new HttpError(413, `${which} is larger than ${limit} bytes`);
  const data = await req.arrayBuffer();
  if (data.byteLength === 0) throw new HttpError(400, 'empty body');
  if (data.byteLength > limit) throw new HttpError(413, `${which} is larger than ${limit} bytes`);
  const contentType = req.headers.get('Content-Type') || 'image/jpeg';
  await env.DERIVED.put(`${which === 'thumb' ? 't' : 'p'}/${a.id}`, data, { httpMetadata: { contentType } });
  // Pending assets get their flags at commit, which checks R2 directly: one database write per upload instead of three.
  if (a.status !== 'pending') await updateWithSeq(env, a.id, `${which === 'thumb' ? 'has_thumb' : 'has_preview'} = 1`, []);
  return json({ ok: true, bytes: data.byteLength });
}

async function getDerived(env: Env, id: string, which: 't' | 'p'): Promise<Response> {
  const obj = await env.DERIVED.get(`${which}/${id}`);
  if (!obj) throw new HttpError(404, 'not found');
  return new Response(obj.body, {
    headers: {
      'Content-Type': obj.httpMetadata?.contentType ?? 'image/jpeg',
      'Cache-Control': 'private, max-age=31536000, immutable',
      ETag: obj.httpEtag,
    },
  });
}

async function commit(env: Env, a: AssetRow): Promise<Response> {
  if (a.status === 'ready') return json({ status: 'ready', asset: toApi(a) });
  if (a.status !== 'pending') throw new HttpError(409, `asset is ${a.status}`);
  const store = originalStore(env);
  const checks: [string, number, string | null][] = [[a.original_key, a.size, a.md5]];
  if (a.paired_key) checks.push([a.paired_key, a.paired_size ?? -1, a.paired_md5]);
  for (const [key, size, md5] of checks) {
    const h = await store.head(key);
    if (!h) throw new HttpError(409, `${key.endsWith('.pair') ? 'paired video' : 'original'} not uploaded yet`);
    if (h.size !== size) throw new HttpError(409, `size mismatch for ${key}: expected ${size}, stored ${h.size}`);
    if (md5 && h.etag && h.etag !== md5) throw new HttpError(409, `checksum mismatch for ${key}`);
  }
  const [thumb, preview] = await Promise.all([env.DERIVED.head(`t/${a.id}`), env.DERIVED.head(`p/${a.id}`)]);
  if (!thumb || !preview) throw new HttpError(409, 'thumbnail and preview must be uploaded first');
  await updateWithSeq(env, a.id, "status = 'ready', has_thumb = 1, has_preview = 1", []);
  return json({ status: 'ready', asset: toApi((await getAsset(env, a.id))!) });
}

// Joins a photo and its motion clip that were uploaded separately (Google Takeout often puts the two halves of a Live
// or Motion Photo in different zips) into one Live Photo. The clip's stored file becomes the photo's paired video, so
// nothing is copied. The clip's own row is purged (apps drop it through the feed) and its hash is retired, so a later
// upload of the same clip gets a new row and key instead of reusing the file the photo now points at.
async function mergeLive(req: Request, env: Env, p: AssetRow): Promise<Response> {
  const { videoId } = await body<{ videoId?: string }>(req);
  if (typeof videoId !== 'string' || !videoId || videoId === p.id) throw new HttpError(400, 'videoId is required');
  if (p.status !== 'ready' || p.kind === 'video') throw new HttpError(409, 'asset must be a ready photo');
  const v = await getAsset(env, videoId);
  if (!v || v.status !== 'ready' || v.kind !== 'video') throw new HttpError(409, 'videoId must be a ready video');
  if (p.paired_key) {
    // Already a Live Photo. Another export of the same photo (a second Google account) can bring the same clip in
    // again as a separate video; when it is byte for byte the clip the photo already has, it is just a duplicate.
    if (!(p.paired_md5 && v.md5 && p.paired_md5 === v.md5 && p.paired_size === v.size)) {
      throw new HttpError(409, 'this photo already has a different motion clip');
    }
    await originalStore(env).delete(v.original_key);
    await env.DERIVED.delete([`t/${v.id}`, `p/${v.id}`]);
    await updateWithSeq(env, v.id, "status = 'purged', sha256 = ?, has_thumb = 0, has_preview = 0", [`merged:${v.id}`]);
    return json({ asset: toApi(p), duplicate: true });
  }
  await updateWithSeq(env, p.id, "kind = 'live', paired_key = ?, paired_size = ?, paired_md5 = ?, paired_mime = ?, favorite = MAX(favorite, ?)",
                      [v.original_key, v.size, v.md5, v.mime, v.favorite]);
  await updateWithSeq(env, v.id, "status = 'purged', sha256 = ?, has_thumb = 0, has_preview = 0", [`merged:${v.id}`]);
  await env.DERIVED.delete([`t/${v.id}`, `p/${v.id}`]);
  return json({ asset: toApi((await getAsset(env, p.id))!) });
}

// MARK: albums

const ALBUM_ID = /^[A-Za-z0-9_-]{1,80}$/;

/** Every album with the ids of its photos that are in the library (trashed or purged ones are left out). */
async function listAlbums(env: Env): Promise<Response> {
  const { results: albums } = await env.DB.prepare('SELECT id, title, source, updated_at FROM albums ORDER BY title COLLATE NOCASE')
    .all<{ id: string; title: string; source: string; updated_at: number }>();
  const { results: items } = await env.DB.prepare(`SELECT i.album_id, i.asset_id FROM album_items i
      JOIN assets a ON a.id = i.asset_id WHERE a.status = 'ready' ORDER BY a.taken_at DESC`).all<{ album_id: string; asset_id: string }>();
  const byAlbum = new Map<string, string[]>();
  for (const r of items) (byAlbum.get(r.album_id) ?? byAlbum.set(r.album_id, []).get(r.album_id)!).push(r.asset_id);
  const version = albums.reduce((v, a) => Math.max(v, a.updated_at), 0);
  return json({
    version,
    albums: albums.map((a) => ({ id: a.id, title: a.title, source: a.source, updatedAt: a.updated_at, assetIds: byAlbum.get(a.id) ?? [] })),
  });
}

/** Creates or renames an album and adds/removes photos. The phone sends only what changed since its last sync. */
async function putAlbum(req: Request, env: Env, id: string): Promise<Response> {
  if (!ALBUM_ID.test(id)) throw new HttpError(400, 'bad album id');
  const b = await body<{ title?: string; source?: string; add?: string[]; remove?: string[] }>(req);
  const title = typeof b.title === 'string' ? b.title.trim().slice(0, 200) : '';
  if (!title) throw new HttpError(400, 'title is required');
  const add = Array.isArray(b.add) ? b.add.filter((x) => typeof x === 'string').slice(0, 5000) : [];
  const remove = Array.isArray(b.remove) ? b.remove.filter((x) => typeof x === 'string').slice(0, 5000) : [];
  const now = Date.now();
  const stmts = [env.DB.prepare(`INSERT INTO albums (id, title, source, created_at, updated_at) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET title = excluded.title, updated_at = excluded.updated_at`).bind(id, title, b.source ?? 'iphone', now, now)];
  for (const a of add) stmts.push(env.DB.prepare('INSERT OR IGNORE INTO album_items (album_id, asset_id, added_at) VALUES (?, ?, ?)').bind(id, a, now));
  for (const a of remove) stmts.push(env.DB.prepare('DELETE FROM album_items WHERE album_id = ? AND asset_id = ?').bind(id, a));
  for (let i = 0; i < stmts.length; i += 500) await env.DB.batch(stmts.slice(i, i + 500));
  const n = await env.DB.prepare('SELECT COUNT(*) AS n FROM album_items WHERE album_id = ?').bind(id).first<{ n: number }>();
  return json({ album: { id, title, updatedAt: now, count: n?.n ?? 0 } });
}

async function deleteAlbum(env: Env, id: string): Promise<Response> {
  await env.DB.batch([
    env.DB.prepare('DELETE FROM album_items WHERE album_id = ?').bind(id),
    env.DB.prepare('DELETE FROM albums WHERE id = ?').bind(id),
  ]);
  return json({ ok: true });
}

async function changes(env: Env, url: URL): Promise<Response> {
  const since = Math.max(0, Number(url.searchParams.get('since') ?? 0) || 0);
  const limit = Math.min(1000, Math.max(1, Number(url.searchParams.get('limit') ?? 500) || 500));
  const { results } = await env.DB.prepare("SELECT * FROM assets WHERE seq > ? AND status != 'pending' ORDER BY seq LIMIT ?")
    .bind(since, limit).all<AssetRow>();
  const cursor = results.length ? results[results.length - 1].seq : since;
  return json({ assets: results.map(toApi), cursor, hasMore: results.length === limit });
}

async function patchAsset(req: Request, env: Env, a: AssetRow): Promise<Response> {
  const b = await body<{ favorite?: boolean; hidden?: boolean; liveOff?: boolean; takenAt?: number; lat?: number | null; lon?: number | null }>(req);
  const sets: string[] = [];
  const binds: unknown[] = [];
  if (typeof b.favorite === 'boolean') { sets.push('favorite = ?'); binds.push(b.favorite ? 1 : 0); }
  if (typeof b.hidden === 'boolean') { sets.push('hidden = ?'); binds.push(b.hidden ? 1 : 0); }
  if (typeof b.liveOff === 'boolean') {
    if (!a.paired_key) throw new HttpError(409, 'only a Live Photo can have Live turned off');
    sets.push('live_off = ?'); binds.push(b.liveOff ? 1 : 0);
  }
  // Metadata corrections (e.g. a Google Takeout sidecar that arrived after the photo was imported).
  if (b.takenAt !== undefined) {
    if (typeof b.takenAt !== 'number' || !Number.isFinite(b.takenAt)) throw new HttpError(400, 'takenAt must be unix ms');
    sets.push('taken_at = ?'); binds.push(Math.round(b.takenAt));
  }
  for (const k of ['lat', 'lon'] as const) {
    if (b[k] === undefined) continue;
    const v = b[k];
    if (v !== null && (typeof v !== 'number' || Math.abs(v) > (k === 'lat' ? 90 : 180))) throw new HttpError(400, `${k} out of range`);
    sets.push(`${k} = ?`); binds.push(v);
  }
  if (!sets.length) throw new HttpError(400, 'nothing to update (favorite, hidden, liveOff, takenAt, lat, lon)');
  await updateWithSeq(env, a.id, sets.join(', '), binds);
  return json({ asset: toApi((await getAsset(env, a.id))!) });
}

async function stats(env: Env): Promise<Response> {
  const { results } = await env.DB.prepare(`SELECT status, kind, COUNT(*) AS n, SUM(size) + COALESCE(SUM(paired_size), 0) AS bytes,
      SUM(favorite) AS favorites FROM assets GROUP BY status, kind`).all<{ status: string; kind: string; n: number; bytes: number; favorites: number }>();
  const out = { ready: 0, trashed: 0, pending: 0, purged: 0, bytes: 0, favorites: 0, byKind: {} as Record<string, number> };
  for (const r of results) {
    (out as Record<string, unknown>)[r.status] = ((out as unknown as Record<string, number>)[r.status] ?? 0) + r.n;
    if (r.status === 'ready') {
      out.bytes += r.bytes ?? 0; out.favorites += r.favorites ?? 0;
      out.byKind[r.kind] = (out.byKind[r.kind] ?? 0) + r.n;
    }
  }
  const { value } = (await env.DB.prepare("SELECT value FROM counters WHERE name = 'seq'").first<{ value: number }>())!;
  const c = caps(env);
  const u = await usage(env);
  return json({ ...out, seq: value, usage: u, caps: c });
}

function randomToken(): string {
  const b = crypto.getRandomValues(new Uint8Array(16));
  return btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

interface ShareRow { token: string; title: string | null; asset_ids: string; allow_original: number; created_at: number; expires_at: number }

async function createShare(req: Request, env: Env, origin: string): Promise<Response> {
  const b = await body<{ assetIds: string[]; title?: string; days?: number; allowOriginal?: boolean }>(req);
  if (!Array.isArray(b.assetIds) || !b.assetIds.length || b.assetIds.length > 500) throw new HttpError(400, 'assetIds: 1 to 500 ids');
  const ids = [...new Set(b.assetIds.map(String))];
  const placeholders = ids.map(() => '?').join(',');
  const { results } = await env.DB.prepare(`SELECT id FROM assets WHERE status = 'ready' AND id IN (${placeholders})`).bind(...ids).all<{ id: string }>();
  if (results.length !== ids.length) throw new HttpError(400, 'some assets do not exist or are not ready');
  const days = Math.min(30, Math.max(1, Math.round(b.days ?? 7)));
  const token = randomToken();
  const now = Date.now();
  const expiresAt = now + days * 86400_000;
  await env.DB.prepare('INSERT INTO shares (token, title, asset_ids, allow_original, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)')
    .bind(token, (b.title ?? '').slice(0, 120) || null, JSON.stringify(ids), b.allowOriginal ? 1 : 0, now, expiresAt).run();
  return json({ token, url: `${origin}/s/${token}`, expiresAt }, 201);
}

async function loadShare(env: Env, token: string): Promise<ShareRow> {
  const s = await env.DB.prepare('SELECT * FROM shares WHERE token = ?').bind(token).first<ShareRow>();
  if (!s || s.expires_at < Date.now()) throw new HttpError(404, 'this link has expired or does not exist');
  return s;
}

async function publicShare(env: Env, origin: string, parts: string[]): Promise<Response> {
  const s = await loadShare(env, parts[0]);
  const ids: string[] = JSON.parse(s.asset_ids);
  if (parts.length === 1) {
    const placeholders = ids.map(() => '?').join(',');
    const { results } = await env.DB.prepare(`SELECT id, kind, filename, taken_at FROM assets WHERE status = 'ready' AND id IN (${placeholders}) ORDER BY taken_at`)
      .bind(...ids).all<{ id: string; kind: string; filename: string | null; taken_at: number }>();
    const html = sharePage(s.token, s.title, results.map((r) => ({ id: r.id, kind: r.kind, filename: r.filename, takenAt: r.taken_at })),
                           !!s.allow_original, s.expires_at);
    return new Response(html, { headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'private, no-store',
                                           'X-Robots-Tag': 'noindex', 'Referrer-Policy': 'no-referrer' } });
  }
  const [, what, id] = parts;
  if (!ids.includes(id)) throw new HttpError(404, 'not found');
  if (what === 't' || what === 'p') return getDerived(env, id, what);
  if (what === 'o' && s.allow_original) {
    const a = await getAsset(env, id);
    if (!a || a.status !== 'ready') throw new HttpError(404, 'not found');
    await admitDownload(env, a.size);
    return Response.redirect(await originalStore(env).downloadUrl(a.original_key, origin, a.filename ?? undefined), 302);
  }
  throw new HttpError(404, 'not found');
}

async function blob(req: Request, env: Env, url: URL, key: string): Promise<Response> {
  if (env.ORIGINALS_MODE !== 'r2') throw new HttpError(404, 'not found');
  if (req.method === 'PUT') {
    if (!(await authorized(req, env))) throw new HttpError(401, 'unauthorized');
    const obj = await env.ORIGINALS_R2.put(key, req.body, { httpMetadata: { contentType: req.headers.get('Content-Type') ?? 'application/octet-stream' } });
    return json({ ok: true, etag: obj?.etag });
  }
  if (req.method === 'GET') {
    const exp = Number(url.searchParams.get('exp') ?? 0);
    const sig = url.searchParams.get('sig') ?? '';
    const signedOk = exp > Date.now() && sig === (await blobSignature(env.APP_TOKEN, key, exp));
    if (!signedOk && !(await authorized(req, env))) throw new HttpError(401, 'unauthorized');
    const obj = await env.ORIGINALS_R2.get(key, { range: req.headers });
    if (!obj) throw new HttpError(404, 'not found');
    const headers = new Headers({ 'Content-Type': obj.httpMetadata?.contentType ?? 'application/octet-stream', ETag: obj.httpEtag,
                                  'Accept-Ranges': 'bytes' });
    if (req.headers.has('Range') && obj.range && 'offset' in obj.range) {
      const off = obj.range.offset ?? 0;
      const len = obj.range.length ?? obj.size - off;
      headers.set('Content-Range', `bytes ${off}-${off + len - 1}/${obj.size}`);
      return new Response(obj.body, { status: 206, headers });
    }
    return new Response(obj.body, { headers });
  }
  throw new HttpError(405, 'method not allowed');
}

// Daily cleanup: purge trash older than TRASH_DAYS, drop abandoned uploads, delete expired share links.
export async function purge(env: Env, olderThanDays?: number): Promise<{ purged: number; abandoned: number; shares: number }> {
  const days = olderThanDays ?? Number(env.TRASH_DAYS ?? 30);
  const cutoff = Date.now() - days * 86400_000;
  const store = originalStore(env);
  const { results: trash } = await env.DB.prepare("SELECT * FROM assets WHERE status = 'trashed' AND trashed_at <= ? LIMIT 200")
    .bind(cutoff).all<AssetRow>();
  for (const a of trash) {
    await env.DERIVED.delete([`t/${a.id}`, `p/${a.id}`]);
    await store.delete(a.original_key);
    if (a.paired_key) await store.delete(a.paired_key);
    await updateWithSeq(env, a.id, "status = 'purged', has_thumb = 0, has_preview = 0", []);
  }
  const { results: stale } = await env.DB.prepare("SELECT * FROM assets WHERE status = 'pending' AND updated_at <= ? LIMIT 200")
    .bind(Date.now() - 7 * 86400_000).all<AssetRow>();
  for (const a of stale) {
    await env.DERIVED.delete([`t/${a.id}`, `p/${a.id}`]);
    await store.delete(a.original_key).catch(() => {});
    if (a.paired_key) await store.delete(a.paired_key).catch(() => {});
    await env.DB.prepare("DELETE FROM assets WHERE id = ? AND status = 'pending'").bind(a.id).run();
  }
  const sh = await env.DB.prepare('DELETE FROM shares WHERE expires_at < ?').bind(Date.now()).run();
  return { purged: trash.length, abandoned: stale.length, shares: sh.meta.changes ?? 0 };
}

async function route(req: Request, env: Env): Promise<Response> {
  const url = new URL(req.url);
  const origin = url.origin;
  const path = url.pathname.replace(/\/+$/, '') || '/';
  const m = req.method;

  if (path === '/' || path === '/v1/health') return json({ ok: true, service: 'bottomless', mode: env.ORIGINALS_MODE });
  if (path.startsWith('/s/')) {
    if (m !== 'GET' && m !== 'HEAD') throw new HttpError(405, 'method not allowed');
    return publicShare(env, origin, path.slice(3).split('/'));
  }
  if (path.startsWith('/v1/blob/')) return blob(req, env, url, decodeURIComponent(path.slice('/v1/blob/'.length)));
  if (!path.startsWith('/v1/')) throw new HttpError(404, 'not found');
  if (!(await authorized(req, env))) throw new HttpError(401, 'unauthorized');

  if (path === '/v1/assets/prepare' && m === 'POST') return prepare(req, env, origin);
  if (path === '/v1/changes' && m === 'GET') return changes(env, url);
  if (path === '/v1/stats' && m === 'GET') return stats(env);
  if (path === '/v1/shares' && m === 'POST') return createShare(req, env, origin);
  if (path === '/v1/albums' && m === 'GET') return listAlbums(env);
  const am = path.match(/^\/v1\/albums\/([^/]+)$/);
  if (am && m === 'PUT') return putAlbum(req, env, decodeURIComponent(am[1]));
  if (am && m === 'DELETE') return deleteAlbum(env, decodeURIComponent(am[1]));
  if (path === '/v1/shares' && m === 'GET') {
    const { results } = await env.DB.prepare('SELECT * FROM shares WHERE expires_at >= ? ORDER BY created_at DESC').bind(Date.now()).all<ShareRow>();
    return json({ shares: results.map((s) => ({ token: s.token, url: `${origin}/s/${s.token}`, title: s.title,
      count: JSON.parse(s.asset_ids).length, allowOriginal: !!s.allow_original, createdAt: s.created_at, expiresAt: s.expires_at })) });
  }
  if (path === '/v1/admin/purge' && m === 'POST') {
    const days = url.searchParams.get('olderThanDays');
    return json(await purge(env, days === null ? undefined : Number(days)));
  }
  let mm = /^\/v1\/shares\/([A-Za-z0-9_-]+)$/.exec(path);
  if (mm && m === 'DELETE') {
    await env.DB.prepare('DELETE FROM shares WHERE token = ?').bind(mm[1]).run();
    return json({ ok: true });
  }

  mm = /^\/v1\/assets\/([0-9a-f-]{36})(?:\/([a-z]+))?$/.exec(path);
  if (!mm) throw new HttpError(404, 'not found');
  const [, id, action] = mm;
  const a = await getAsset(env, id);
  if (!a || a.status === 'purged') throw new HttpError(404, 'asset not found');

  if (!action && m === 'GET') return json({ asset: toApi(a) });
  if (!action && m === 'PATCH') return patchAsset(req, env, a);
  if (!action && m === 'DELETE') {
    if (a.status === 'pending') throw new HttpError(409, 'asset is still uploading');
    if (a.status !== 'trashed') await updateWithSeq(env, a.id, "status = 'trashed', trashed_at = ?", [Date.now()]);
    return json({ asset: toApi((await getAsset(env, a.id))!) });
  }
  if (action === 'restore' && m === 'POST') {
    if (a.status !== 'trashed') throw new HttpError(409, `asset is ${a.status}`);
    await updateWithSeq(env, a.id, "status = 'ready', trashed_at = NULL", []);
    return json({ asset: toApi((await getAsset(env, a.id))!) });
  }
  if (action === 'commit' && m === 'POST') return commit(env, a);
  if (action === 'live' && m === 'POST') return mergeLive(req, env, a);
  if ((action === 'thumb' || action === 'preview') && m === 'PUT') return putDerived(req, env, a, action);
  if ((action === 'thumb' || action === 'preview') && m === 'GET') return getDerived(env, a.id, action === 'thumb' ? 't' : 'p');
  if (action === 'original' && m === 'GET') {
    if (a.status === 'pending') throw new HttpError(409, 'asset is still uploading');
    const paired = url.searchParams.get('paired') === '1';
    if (paired && !a.paired_key) throw new HttpError(404, 'asset has no paired video');
    const key = paired ? a.paired_key! : a.original_key;
    const download = url.searchParams.get('download') === '1';
    const name = a.filename ? (paired ? a.filename.replace(/\.[^.]+$/, '') + '.MOV' : a.filename) : undefined;
    await admitDownload(env, paired ? (a.paired_size ?? 0) : a.size);
    const dl = await originalStore(env).downloadUrl(key, origin, download ? name : undefined);
    return json({ url: dl, expiresAt: Date.now() + 3600_000 });
  }
  throw new HttpError(405, 'method not allowed');
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    try {
      return await route(req, env);
    } catch (e) {
      if (e instanceof HttpError) return json({ error: e.message }, e.status);
      if (e instanceof CapError) return json({ error: e.message, cap: true }, 429);
      const msg = String((e as Error)?.message ?? e);
      // D1's free tier blocks reads or writes for the rest of the UTC day once a daily limit is hit.
      if (/D1/i.test(msg) && /exceed|limit/i.test(msg)) {
        return json({ error: `Cloudflare D1 daily free-tier cap reached; resumes at 00:00 UTC (${msg})`, cap: true }, 429);
      }
      console.error('unhandled', e);
      return json({ error: 'internal error', detail: String((e as Error)?.message ?? e) }, 500);
    }
  },
  async scheduled(_controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(purge(env).then((r) => console.log('purge', JSON.stringify(r))));
  },
} satisfies ExportedHandler<Env>;
