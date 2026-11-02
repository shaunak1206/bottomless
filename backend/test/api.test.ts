import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { startStack, fakeFile, TOKEN, type Stack } from './harness.ts';

const auth = { Authorization: `Bearer ${TOKEN}` };

for (const [mode, port, motoPort] of [['s3', 8799, 5055], ['r2', 8798, 0]] as const) {
  describe(`API (originals in ${mode})`, () => {
    let s: Stack;
    const api = (path: string, init: RequestInit = {}) =>
      fetch(s.base + path, { ...init, headers: { ...auth, ...(init.headers as Record<string, string> ?? {}) } });
    const jsonApi = async (path: string, init: RequestInit = {}) => {
      const r = await api(path, { ...init, headers: { 'Content-Type': 'application/json', ...(init.headers as Record<string, string> ?? {}) } });
      return { status: r.status, body: await r.json() as any };
    };

    before(async () => { s = await startStack(mode, port, motoPort); });
    after(async () => { await s?.stop(); });

    // Uploads a photo the way the app does: prepare → PUT original → PUT thumb/preview → commit.
    async function backup(file = fakeFile(300_000), extra: Record<string, unknown> = {}, paired?: ReturnType<typeof fakeFile>) {
      const prep = await jsonApi('/v1/assets/prepare', { method: 'POST', body: JSON.stringify({
        sha256: file.sha256, md5: file.md5, size: file.data.length, mime: 'image/heic', kind: paired ? 'live' : 'photo',
        filename: 'IMG_0001.HEIC', takenAt: Date.parse('2026-10-01T12:00:00Z'), width: 4032, height: 3024,
        lat: 30.28, lon: -97.74, ...(paired ? { paired: { size: paired.data.length, md5: paired.md5, mime: 'video/quicktime' } } : {}), ...extra,
      }) });
      if (prep.body.status === 'exists') return { prep, id: prep.body.assetId as string };
      assert.equal(prep.status, 201, JSON.stringify(prep.body));
      const id = prep.body.assetId as string;
      const o = prep.body.uploads.original;
      const put = await fetch(o.url, { method: o.method, headers: o.headers, body: file.data });
      assert.ok(put.ok, `original upload failed: ${put.status} ${await put.text()}`);
      if (paired) {
        const early = await jsonApi(`/v1/assets/${id}/commit`, { method: 'POST' });
        assert.equal(early.status, 409);
        const pu = prep.body.uploads.paired;
        assert.ok((await fetch(pu.url, { method: pu.method, headers: pu.headers, body: paired.data })).ok);
      }
      const noDerived = await jsonApi(`/v1/assets/${id}/commit`, { method: 'POST' });
      assert.equal(noDerived.status, 409, 'commit must wait for thumbnail and preview');
      for (const which of ['thumb', 'preview']) {
        const r = await api(`/v1/assets/${id}/${which}`, { method: 'PUT', headers: { 'Content-Type': 'image/jpeg' },
                                                           body: Buffer.from(`${which}-of-${id}`) });
        assert.equal(r.status, 200);
      }
      const c = await jsonApi(`/v1/assets/${id}/commit`, { method: 'POST' });
      assert.equal(c.status, 200, JSON.stringify(c.body));
      assert.equal(c.body.asset.status, 'ready');
      return { prep, id };
    }

    test('health is public, everything else needs the token', async () => {
      assert.equal((await fetch(s.base + '/v1/health')).status, 200);
      assert.equal((await fetch(s.base + '/v1/changes')).status, 401);
      assert.equal((await fetch(s.base + '/v1/changes', { headers: { Authorization: 'Bearer wrong' } })).status, 401);
    });

    test('prepare validates input', async () => {
      const r = await jsonApi('/v1/assets/prepare', { method: 'POST', body: JSON.stringify({ sha256: 'nope' }) });
      assert.equal(r.status, 400);
    });

    let photoId = '';
    let photo = fakeFile(300_000);
    test('full backup of a photo, then dedupe by hash', async () => {
      const { id } = await backup(photo);
      photoId = id;
      const again = await jsonApi('/v1/assets/prepare', { method: 'POST', body: JSON.stringify({
        sha256: photo.sha256, size: photo.data.length, mime: 'image/heic', kind: 'photo', takenAt: 1 }) });
      assert.equal(again.body.status, 'exists');
      assert.equal(again.body.assetId, id);
    });

    test('live photo needs both halves before commit', async () => {
      const { id } = await backup(fakeFile(200_000), {}, fakeFile(900_000));
      const a = (await jsonApi(`/v1/assets/${id}`)).body.asset;
      assert.equal(a.kind, 'live');
      assert.equal(a.hasPaired, true);
    });

    test('commit rejects a size mismatch', async () => {
      const f = fakeFile(50_000);
      const prep = await jsonApi('/v1/assets/prepare', { method: 'POST', body: JSON.stringify({
        sha256: f.sha256, md5: f.md5, size: f.data.length + 5, mime: 'image/jpeg', kind: 'photo', takenAt: Date.now() }) });
      const o = prep.body.uploads.original;
      await fetch(o.url, { method: 'PUT', headers: o.headers, body: f.data });
      for (const w of ['thumb', 'preview']) await api(`/v1/assets/${prep.body.assetId}/${w}`, { method: 'PUT', body: 'x' });
      const c = await jsonApi(`/v1/assets/${prep.body.assetId}/commit`, { method: 'POST' });
      assert.equal(c.status, 409);
      assert.match(c.body.error, /size mismatch/);
    });

    let cursor = 0;
    test('change feed returns ready assets once, then only newer changes', async () => {
      const all = await jsonApi('/v1/changes?since=0');
      assert.equal(all.status, 200);
      assert.equal(all.body.assets.length, 2, 'pending (failed) uploads are not in the feed');
      cursor = all.body.cursor;
      const none = await jsonApi(`/v1/changes?since=${cursor}`);
      assert.equal(none.body.assets.length, 0);
      const fav = await jsonApi(`/v1/assets/${photoId}`, { method: 'PATCH', body: JSON.stringify({ favorite: true }) });
      assert.equal(fav.body.asset.favorite, true);
      const fix = await jsonApi(`/v1/assets/${photoId}`, { method: 'PATCH', body: JSON.stringify({ takenAt: 1262304000000, lat: 48.85, lon: 2.35 }) });
      assert.equal(fix.body.asset.takenAt, 1262304000000, 'capture time can be corrected');
      assert.equal(fix.body.asset.lat, 48.85);
      assert.equal((await jsonApi(`/v1/assets/${photoId}`, { method: 'PATCH', body: JSON.stringify({ lat: 123 }) })).status, 400);
      const delta = await jsonApi(`/v1/changes?since=${cursor}`);
      assert.equal(delta.body.assets.length, 1);
      assert.equal(delta.body.assets[0].id, photoId);
      assert.equal(delta.body.assets[0].favorite, true);
      cursor = delta.body.cursor;
      const paged = await jsonApi('/v1/changes?since=0&limit=1');
      assert.equal(paged.body.assets.length, 1);
      assert.equal(paged.body.hasMore, true);
    });

    test('thumbnail, preview and original come back byte for byte', async () => {
      const t = await api(`/v1/assets/${photoId}/thumb`);
      assert.equal(await t.text(), `thumb-of-${photoId}`);
      const p = await api(`/v1/assets/${photoId}/preview`);
      assert.equal(await p.text(), `preview-of-${photoId}`);
      const o = await jsonApi(`/v1/assets/${photoId}/original?download=1`);
      assert.equal(o.status, 200);
      const dl = await fetch(o.body.url);
      assert.equal(dl.status, 200);
      const bytes = Buffer.from(await dl.arrayBuffer());
      assert.equal(createHash('sha256').update(bytes).digest('hex'), photo.sha256);
      if (mode === 'r2') {
        const ranged = await fetch(o.body.url, { headers: { Range: 'bytes=0-9' } });
        assert.equal(ranged.status, 206);
        assert.equal((await ranged.arrayBuffer()).byteLength, 10);
      }
    });

    test('share links: page, images, original, expiry', async () => {
      const sh = await jsonApi('/v1/shares', { method: 'POST', body: JSON.stringify({ assetIds: [photoId], title: 'Trip <3', days: 2, allowOriginal: true }) });
      assert.equal(sh.status, 201);
      const page = await fetch(sh.body.url);
      const html = await page.text();
      assert.equal(page.status, 200);
      assert.ok(html.includes(photoId) && html.includes('Trip &lt;3'));
      assert.equal((await fetch(`${s.base}/s/${sh.body.token}/t/${photoId}`)).status, 200);
      assert.equal((await fetch(`${s.base}/s/${sh.body.token}/p/${photoId}`)).status, 200);
      const orig = await fetch(`${s.base}/s/${sh.body.token}/o/${photoId}`, { redirect: 'manual' });
      assert.equal(orig.status, 302);
      const got = Buffer.from(await (await fetch(orig.headers.get('location')!)).arrayBuffer());
      assert.equal(createHash('sha256').update(got).digest('hex'), photo.sha256);
      assert.equal((await fetch(`${s.base}/s/${sh.body.token}/p/not-in-share`)).status, 404);
      assert.equal((await fetch(`${s.base}/s/nope`)).status, 404);
      const list = await jsonApi('/v1/shares');
      assert.equal(list.body.shares.length, 1);
      assert.equal((await jsonApi(`/v1/shares/${sh.body.token}`, { method: 'DELETE' })).status, 200);
      assert.equal((await fetch(sh.body.url)).status, 404);
    });

    test('trash, restore, purge and resurrect', async () => {
      const del = await jsonApi(`/v1/assets/${photoId}`, { method: 'DELETE' });
      assert.equal(del.body.asset.status, 'trashed');
      const restored = await jsonApi(`/v1/assets/${photoId}/restore`, { method: 'POST' });
      assert.equal(restored.body.asset.status, 'ready');
      await jsonApi(`/v1/assets/${photoId}`, { method: 'DELETE' });
      const purge = await jsonApi('/v1/admin/purge?olderThanDays=0', { method: 'POST' });
      assert.equal(purge.body.purged, 1);
      const feed = await jsonApi(`/v1/changes?since=${cursor}`);
      const row = feed.body.assets.find((a: any) => a.id === photoId);
      assert.equal(row.status, 'purged', 'the app learns about purges through the feed');
      assert.equal((await jsonApi(`/v1/assets/${photoId}/original`)).status, 404);
      // the same photo can be backed up again after a purge
      const again = await jsonApi('/v1/assets/prepare', { method: 'POST', body: JSON.stringify({
        sha256: photo.sha256, md5: photo.md5, size: photo.data.length, mime: 'image/heic', kind: 'photo', takenAt: 1 }) });
      assert.equal(again.body.status, 'upload');
      assert.equal(again.body.assetId, photoId);
    });

    test('stats and the scheduled cleanup run', async () => {
      const st = await jsonApi('/v1/stats');
      assert.equal(st.status, 200);
      assert.equal(st.body.ready, 1);
      assert.ok(st.body.seq > 0);
      const sched = await fetch(`${s.base}/__scheduled?cron=17+9+*+*+*`);
      assert.equal(sched.status, 200);
    });

    test('albums: create, add and remove photos, list only photos in the library', async () => {
      const a = await backup(fakeFile(60_000));
      const b = await backup(fakeFile(61_000));
      const put = await jsonApi('/v1/albums/iphone-trip', { method: 'PUT', body: JSON.stringify({ title: 'Paris trip', add: [a.id, b.id] }) });
      assert.equal(put.status, 200, JSON.stringify(put.body));
      assert.equal(put.body.album.count, 2);
      let list = (await jsonApi('/v1/albums')).body;
      const album = list.albums.find((x: any) => x.id === 'iphone-trip');
      assert.equal(album.title, 'Paris trip');
      assert.deepEqual(new Set(album.assetIds), new Set([a.id, b.id]));
      await jsonApi('/v1/albums/iphone-trip', { method: 'PUT', body: JSON.stringify({ title: 'Paris', remove: [b.id] }) });
      await jsonApi(`/v1/assets/${a.id}`, { method: 'DELETE' });
      list = (await jsonApi('/v1/albums')).body;
      const after = list.albums.find((x: any) => x.id === 'iphone-trip');
      assert.equal(after.title, 'Paris');
      assert.deepEqual(after.assetIds, [], 'removed and trashed photos are not listed');
      assert.equal((await jsonApi('/v1/albums/bad id!', { method: 'PUT', body: JSON.stringify({ title: 'x' }) })).status, 400);
      assert.equal((await jsonApi('/v1/albums/iphone-trip', { method: 'DELETE' })).status, 200);
      assert.equal((await jsonApi('/v1/albums')).body.albums.some((x: any) => x.id === 'iphone-trip'), false);
    });

    test('people: indexer faces, naming, merging, "not this person", only photos in the library', async () => {
      const a = await backup(fakeFile(62_000));
      const b = await backup(fakeFile(63_000));
      const c = await backup(fakeFile(64_000));
      const face = (id: string, assetId: string, personId: string | null, w = 0.2) => ({ id, assetId, personId, x: 0.1, y: 0.1, w, h: w, score: 0.9 });
      const put = await jsonApi('/v1/faces', { method: 'POST', body: JSON.stringify({ faces: [
        face(`fa-${mode}`, a.id, `p1-${mode}`, 0.3), face(`fb-${mode}`, b.id, `p1-${mode}`), face(`fc-${mode}`, c.id, `p2-${mode}`),
        face(`fa2-${mode}`, a.id, null),
      ] }) });
      assert.equal(put.status, 200, JSON.stringify(put.body));
      let list = (await jsonApi('/v1/people')).body;
      const p1 = () => list.people.find((p: any) => p.id === `p1-${mode}`);
      assert.deepEqual(new Set(p1().assetIds), new Set([a.id, b.id]));
      assert.equal(p1().cover.faceId, `fa-${mode}`, 'the biggest clear face is the picture');
      assert.equal(p1().name, null);
      assert.deepEqual((await jsonApi(`/v1/people?since=${list.version}`)).body, { version: list.version, unchanged: true });

      assert.equal((await jsonApi(`/v1/people/p2-${mode}`, { method: 'PATCH', body: JSON.stringify({ name: ' Manas ' }) })).status, 200);
      list = (await jsonApi('/v1/people')).body;
      assert.equal(list.people.find((p: any) => p.id === `p2-${mode}`).name, 'Manas');
      const merged = await jsonApi(`/v1/people/p1-${mode}/merge`, { method: 'POST', body: JSON.stringify({ from: [`p2-${mode}`] }) });
      assert.equal(merged.status, 200, JSON.stringify(merged.body));
      list = (await jsonApi('/v1/people')).body;
      assert.equal(p1().name, 'Manas', 'a merge keeps the name');
      assert.deepEqual(new Set(p1().assetIds), new Set([a.id, b.id, c.id]));
      assert.equal(list.people.some((p: any) => p.id === `p2-${mode}`), false);

      assert.equal((await jsonApi(`/v1/people/p1-${mode}/remove`, { method: 'POST', body: JSON.stringify({ assetIds: [c.id] }) })).status, 200);
      list = (await jsonApi('/v1/people')).body;
      assert.deepEqual(new Set(p1().assetIds), new Set([a.id, b.id]));
      // The indexer cannot put a face back into a person it was taken out of.
      await jsonApi('/v1/faces', { method: 'POST', body: JSON.stringify({ faces: [face(`fc-${mode}`, c.id, `p1-${mode}`)] }) });
      const all = (await jsonApi('/v1/faces?limit=2000')).body.faces;
      const fc = all.find((f: any) => f.id === `fc-${mode}`);
      assert.deepEqual([fc.personId, fc.rejected], [null, `p1-${mode}`]);

      // "This is someone else": the face moves to a new, named person.
      const moved = await jsonApi(`/v1/people/p1-${mode}/remove`, { method: 'POST', body: JSON.stringify({ assetIds: [b.id], to: `p3-${mode}`, name: 'Bhumika' }) });
      assert.equal(moved.status, 200, JSON.stringify(moved.body));
      list = (await jsonApi('/v1/people')).body;
      assert.deepEqual(p1().assetIds, [a.id]);
      const p3 = list.people.find((p: any) => p.id === `p3-${mode}`);
      assert.deepEqual([p3.name, p3.assetIds], ['Bhumika', [b.id]]);
      assert.equal((await jsonApi(`/v1/people/p3-${mode}/remove`, { method: 'POST', body: JSON.stringify({ assetIds: [b.id], to: `p1-${mode}` }) })).status, 200);
      list = (await jsonApi('/v1/people')).body;
      assert.equal(p1().name, 'Manas', 'moving into an existing person keeps its name');
      assert.equal((await jsonApi(`/v1/people/p1-${mode}/remove`, { method: 'POST', body: JSON.stringify({ assetIds: [a.id], to: `p1-${mode}` }) })).status, 400);

      await jsonApi(`/v1/assets/${a.id}`, { method: 'DELETE' });
      list = (await jsonApi('/v1/people')).body;
      assert.deepEqual(p1().assetIds, [b.id], 'trashed photos are not listed');
      assert.equal((await jsonApi('/v1/people/nobody', { method: 'PATCH', body: JSON.stringify({ name: 'x' }) })).status, 404);
      assert.equal((await jsonApi('/v1/people/bad id!', { method: 'PATCH', body: JSON.stringify({ name: 'x' }) })).status, 400);
      const bad = await jsonApi('/v1/faces', { method: 'POST', body: JSON.stringify({ faces: [{ ...face('x', 'not-an-asset', null) }] }) });
      assert.equal(bad.status, 400);

      // The indexer's working file round-trips (it runs on GitHub Actions and keeps its state here).
      const state = Buffer.from(`sqlite-bytes-${mode}`.repeat(1000));
      assert.equal((await api('/v1/faces/state', { method: 'PUT', body: state })).status, 200);
      const back = await api('/v1/faces/state');
      assert.equal(back.status, 200);
      assert.deepEqual(Buffer.from(await back.arrayBuffer()), state);
      assert.equal((await fetch(s.base + '/v1/faces/state')).status, 401, 'needs the token');
    });

    test('a photo and its separately uploaded motion clip merge into one Live Photo', async () => {
      const clip = fakeFile(120_000);
      const { id: photo } = await backup(fakeFile(150_000));
      const { id: video } = await backup(clip, { kind: 'video', mime: 'video/mp4', filename: 'IMG_0002.MP4', duration: 2.5 });
      const cursor0 = (await jsonApi('/v1/stats')).body.seq;
      assert.equal((await jsonApi(`/v1/assets/${photo}/live`, { method: 'POST', body: JSON.stringify({ videoId: photo }) })).status, 400);
      const r = await jsonApi(`/v1/assets/${photo}/live`, { method: 'POST', body: JSON.stringify({ videoId: video }) });
      assert.equal(r.status, 200, JSON.stringify(r.body));
      assert.equal(r.body.asset.kind, 'live');
      assert.equal(r.body.asset.hasPaired, true);
      assert.equal(r.body.asset.pairedSize, clip.data.length);
      const feed = (await jsonApi(`/v1/changes?since=${cursor0}`)).body.assets;
      assert.equal(feed.find((a: any) => a.id === video)?.status, 'purged', 'apps drop the separate clip');
      const pairedUrl = (await jsonApi(`/v1/assets/${photo}/original?paired=1`)).body.url;
      const got = Buffer.from(await (await fetch(pairedUrl)).arrayBuffer());
      assert.equal(createHash('sha256').update(got).digest('hex'), clip.sha256, 'the clip plays from the Live Photo');
      assert.equal((await jsonApi(`/v1/assets/${photo}/live`, { method: 'POST', body: JSON.stringify({ videoId: video }) })).status, 409);
      const still = await jsonApi(`/v1/assets/${photo}`, { method: 'PATCH', body: JSON.stringify({ liveOff: true }) });
      assert.equal(still.body.asset.liveOff, true, 'Live can be turned off and the clip is kept');
      assert.equal(still.body.asset.hasPaired, true);
      assert.equal((await jsonApi(`/v1/assets/${photoId}`, { method: 'PATCH', body: JSON.stringify({ liveOff: true }) })).status, 409,
                   'a plain photo has no Live to turn off');
      const again = await jsonApi('/v1/assets/prepare', { method: 'POST', body: JSON.stringify({
        sha256: clip.sha256, md5: clip.md5, size: clip.data.length, mime: 'video/mp4', kind: 'video', takenAt: 1 }) });
      assert.equal(again.status, 201, 'the same clip uploaded later gets a fresh row');
      assert.notEqual(again.body.assetId, video);
      // ...and if it arrives as its own video (another account's export), joining it again removes the duplicate.
      const dupId = again.body.assetId as string;
      const o = again.body.uploads.original;
      assert.ok((await fetch(o.url, { method: o.method, headers: o.headers, body: clip.data })).ok);
      for (const w of ['thumb', 'preview']) await api(`/v1/assets/${dupId}/${w}`, { method: 'PUT', headers: { 'Content-Type': 'image/jpeg' }, body: 'x' });
      assert.equal((await jsonApi(`/v1/assets/${dupId}/commit`, { method: 'POST' })).status, 200);
      const dup = await jsonApi(`/v1/assets/${photo}/live`, { method: 'POST', body: JSON.stringify({ videoId: dupId }) });
      assert.equal(dup.status, 200, JSON.stringify(dup.body));
      assert.equal(dup.body.duplicate, true);
      assert.equal((await jsonApi(`/v1/assets/${dupId}`)).status, 404, 'the duplicate clip is gone');
      const stillPlays = Buffer.from(await (await fetch((await jsonApi(`/v1/assets/${photo}/original?paired=1`)).body.url)).arrayBuffer());
      assert.equal(createHash('sha256').update(stillPlays).digest('hex'), clip.sha256, 'the Live Photo keeps its own clip');
      const other = await backup(fakeFile(90_000), { kind: 'video', mime: 'video/mp4' });
      assert.equal((await jsonApi(`/v1/assets/${photo}/live`, { method: 'POST', body: JSON.stringify({ videoId: other.id }) })).status, 409,
                   'a different clip is never thrown away');
    });
  });
}
