// Live check of a deployed Worker: uploads a tiny test photo through the real flow, reads it back, shares it, then
// trashes and purges it so nothing is left behind.   node scripts/smoke.mjs <api-url> <token-file>
import { readFileSync } from 'node:fs';
import { createHash, randomBytes } from 'node:crypto';

const [base, tokenFile] = process.argv.slice(2);
const token = readFileSync(tokenFile, 'utf8').trim();
const H = { Authorization: `Bearer ${token}` };
let failures = 0;
const ok = (cond, what) => { console.log(`   ${cond ? 'ok  ' : 'FAIL'} ${what}`); if (!cond) failures++; };
const api = async (path, init = {}) => {
  const r = await fetch(base + path, { ...init, headers: { ...H, 'Content-Type': 'application/json', ...(init.headers ?? {}) } });
  const text = await r.text();
  try { return { status: r.status, body: JSON.parse(text) }; } catch { return { status: r.status, body: text }; }
};

const health = await (await fetch(base + '/v1/health')).json();
ok(health.ok, `health (originals: ${health.mode})`);
ok((await fetch(base + '/v1/stats')).status === 401, 'requests without the token are refused');

const data = Buffer.concat([Buffer.from('bottomless smoke test '), randomBytes(64 * 1024)]);
const sha256 = createHash('sha256').update(data).digest('hex');
const md5 = createHash('md5').update(data).digest('hex');
// Only look at changes made by this run: the real library can be far bigger than one feed page.
const seqBefore = (await api('/v1/stats')).body.seq ?? 0;
const prep = await api('/v1/assets/prepare', { method: 'POST', body: JSON.stringify({
  sha256, md5, size: data.length, mime: 'image/jpeg', kind: 'photo', filename: 'smoke.jpg', takenAt: Date.now() }) });
ok(prep.status === 201 && prep.body.status === 'upload', 'prepare returns an upload URL');
const id = prep.body.assetId;
const t = prep.body.uploads.original;
const put = await fetch(t.url, { method: t.method, headers: t.headers, body: data });
ok(put.ok, `original uploaded straight to storage (${put.status})`);
for (const w of ['thumb', 'preview']) {
  const r = await fetch(`${base}/v1/assets/${id}/${w}`, { method: 'PUT', headers: { ...H, 'Content-Type': 'image/jpeg' }, body: Buffer.from(w) });
  ok(r.ok, `${w} uploaded`);
}
const commit = await api(`/v1/assets/${id}/commit`, { method: 'POST' });
ok(commit.status === 200 && commit.body.asset?.status === 'ready', 'server verified size + checksum and committed');
const feed = await api(`/v1/changes?since=${seqBefore}&limit=1000`);
ok(feed.body.assets?.some((a) => a.id === id), 'asset appears in the change feed');
const orig = await api(`/v1/assets/${id}/original`);
const back = Buffer.from(await (await fetch(orig.body.url)).arrayBuffer());
ok(createHash('sha256').update(back).digest('hex') === sha256, 'original downloads byte for byte');
const share = await api('/v1/shares', { method: 'POST', body: JSON.stringify({ assetIds: [id], days: 1 }) });
ok(share.status === 201 && (await fetch(share.body.url)).status === 200, 'share link page loads');
await api(`/v1/shares/${share.body.token}`, { method: 'DELETE' });
await api(`/v1/assets/${id}`, { method: 'DELETE' });
const purge = await api('/v1/admin/purge?olderThanDays=0', { method: 'POST' });
ok(purge.body.purged >= 1, 'test asset trashed and purged (cleanup)');
const gone = await fetch(orig.body.url);
ok(gone.status === 404 || gone.status === 403, 'original deleted from storage');
console.log(failures ? `\n${failures} check(s) failed` : '\nall live checks passed');
process.exit(failures ? 1 : 0);
