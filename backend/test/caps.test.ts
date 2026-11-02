import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { startStack, fakeFile, TOKEN, type Stack } from './harness.ts';

// Tiny caps so the guardrails trip quickly: 3 new items a month, ~0.5 MB of original downloads, ~1.5 MB stored.
describe('spending guardrails', () => {
  let s: Stack;
  const H = { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' };
  before(async () => {
    s = await startStack('r2', 8797, 0, { CAP_NEW_ASSETS_MONTH: '3', CAP_DOWNLOAD_GB_MONTH: '0.0005', CAP_STORED_GB: '0.0014' });
  });
  after(async () => { await s?.stop(); });

  async function backup(bytes: number) {
    const f = fakeFile(bytes);
    const prep = await fetch(`${s.base}/v1/assets/prepare`, { method: 'POST', headers: H, body: JSON.stringify({
      sha256: f.sha256, md5: f.md5, size: f.data.length, mime: 'image/jpeg', kind: 'photo', takenAt: Date.now() }) });
    const body = await prep.json() as any;
    if (prep.status !== 201) return { status: prep.status, body };
    const o = body.uploads.original;
    await fetch(o.url, { method: 'PUT', headers: o.headers, body: f.data });
    for (const w of ['thumb', 'preview']) await fetch(`${s.base}/v1/assets/${body.assetId}/${w}`, { method: 'PUT', headers: { Authorization: H.Authorization }, body: 'x' });
    const c = await fetch(`${s.base}/v1/assets/${body.assetId}/commit`, { method: 'POST', headers: H });
    return { status: c.status, body: await c.json() as any, id: body.assetId as string };
  }

  let ids: string[] = [];
  test('storage cap refuses an upload that would go past it', async () => {
    const a = await backup(400_000);
    const b = await backup(400_000);
    assert.equal(a.status, 200); assert.equal(b.status, 200);
    ids = [a.id!, b.id!];
    const big = await backup(900_000);
    assert.equal(big.status, 429);
    assert.match(big.body.error, /storage limit/);
  });

  test('monthly upload cap refuses the item past the limit', async () => {
    const third = await backup(10_000);
    assert.equal(third.status, 200, 'the 3rd new item this month is allowed');
    const fourth = await backup(10_000);
    assert.equal(fourth.status, 429);
    assert.match(fourth.body.error, /monthly upload limit/);
  });

  test('download cap stops originals but not previews', async () => {
    const first = await fetch(`${s.base}/v1/assets/${ids[0]}/original`, { headers: H });
    assert.equal(first.status, 200, '400 KB is under the 512 KB cap');
    const second = await fetch(`${s.base}/v1/assets/${ids[1]}/original`, { headers: H });
    assert.equal(second.status, 429);
    assert.match(((await second.json()) as any).error, /monthly download limit/);
    assert.equal((await fetch(`${s.base}/v1/assets/${ids[1]}/preview`, { headers: H })).status, 200);
    const stats = await (await fetch(`${s.base}/v1/stats`, { headers: H })).json() as any;
    assert.equal(stats.usage.newAssets, 3);
    assert.ok(stats.caps.newAssetsMonth === 3);
  });
});
