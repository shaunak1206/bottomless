// Puts one cloud-only Live Photo in a backend, the way the Google Photos importer does, and prints its id.
//   node scripts/seed_live.mjs <api base> <token file> <photo.jpg> <clip.mov>
// The photo bytes get a suffix so they never collide with the same sample photo backed up from the simulator. The
// capture time is set to tomorrow so the Live Photo is the first cell in the library.
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const [base, tokenFile, photoPath, clipPath] = process.argv.slice(2);
const H = { Authorization: `Bearer ${readFileSync(tokenFile, 'utf8').trim()}`, 'Content-Type': 'application/json' };
const photo = Buffer.concat([readFileSync(photoPath), Buffer.from('bottomless-live-seed')]);
const clip = readFileSync(clipPath);
const hex = (alg, b) => createHash(alg).update(b).digest('hex');
const api = async (path, init = {}) => {
  const r = await fetch(base + path, { ...init, headers: { ...H, ...(init.headers ?? {}) } });
  const body = await r.json();
  if (!r.ok) throw new Error(`${path}: ${r.status} ${JSON.stringify(body)}`);
  return body;
};

const takenAt = Date.now() + 86400_000;
const prep = await api('/v1/assets/prepare', { method: 'POST', body: JSON.stringify({
  sha256: hex('sha256', photo), md5: hex('md5', photo), size: photo.length, mime: 'image/jpeg', kind: 'live',
  filename: 'LIVE_SEED.JPG', takenAt, paired: { size: clip.length, md5: hex('md5', clip), mime: 'video/quicktime' } }) });
const id = prep.assetId;
if (prep.status === 'upload') {
  const put = (t, data) => fetch(t.url, { method: t.method, headers: t.headers, body: data });
  await put(prep.uploads.original, photo);
  await put(prep.uploads.paired, clip);
  for (const w of ['thumb', 'preview']) {
    await fetch(`${base}/v1/assets/${id}/${w}`, { method: 'PUT', headers: { ...H, 'Content-Type': 'image/jpeg' }, body: photo });
  }
  await api(`/v1/assets/${id}/commit`, { method: 'POST' });
}
await api(`/v1/assets/${id}`, { method: 'PATCH', body: JSON.stringify({ takenAt, liveOff: false }) });
console.log(id);
