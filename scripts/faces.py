#!/opt/anaconda3/bin/python3
"""People for Bottomless: finds the faces in every backed-up photo and groups them by who they are.

The phone has no public face recognition API, so this runs elsewhere: on GitHub Actions every 6 hours (see
scripts/faces_cloud.sh), or on a Mac. It downloads each photo's 2048 px preview from the Worker, finds faces with
InsightFace's SCRFD detector, turns each into an ArcFace embedding, and groups the embeddings. Only the face boxes and
the grouping go to the D1 catalog; the embeddings live in .faces/index.sqlite, which the Actions runner keeps in R2
(/v1/faces/state) between runs.

    scripts/faces.py                    index new photos, then group (run it again any time; it only does what is new)
    scripts/faces.py index [--shard 2/4] only find and embed faces (a quarter of them, for parallel jobs)
    scripts/faces.py merge a.sqlite …   add what shard jobs found
    scripts/faces.py group              only group faces and upload
    scripts/faces.py status             counts

The server address and token come from BOTTOMLESS_API_URL / BOTTOMLESS_TOKEN, or from .secrets/ on the Mac.

Grouping respects the phone: a person's faces never move once they are uploaded (names, merges and "Not this person"
happen in the app). New faces join the person they look most like, and faces that match nobody are grouped among
themselves; groups of 3 or more become new people. Models: .faces/models/det_10g.onnx and w600k_r50.onnx (from
InsightFace's buffalo_l release).
"""
import concurrent.futures as cf
import os
import sqlite3
import sys
import time
import uuid

import cv2
import numpy as np
import onnxruntime as ort
import requests

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE = os.environ.get('FACES_STATE') or os.path.join(ROOT, '.faces')
MODELS = os.path.join(STATE, 'models')

MIN_SCORE = 0.7        # detector confidence
MIN_FACE_PX = 48       # smaller faces (crowds, background) are skipped
EDGE_SIM = 0.45        # two faces this similar are linked when grouping
JOIN_SIM = 0.45        # a new face joins an existing person this similar (centroid)
MERGE_SIM = 0.55       # two groups whose average faces are this similar are one person
MIN_PERSON = 3         # faces needed before a group becomes a person
UPLOAD_CHUNK = 24      # faces per request: keeps each D1 batch under the free plan's query limit

ARCFACE_DST = np.array([[38.2946, 51.6963], [73.5318, 51.5014], [56.0252, 71.7366],
                        [41.5493, 92.3655], [70.7299, 92.2041]], dtype=np.float32)


def log(*a):
    print(time.strftime('%H:%M:%S'), *a, flush=True)


# MARK: cloud

class Cloud:
    def __init__(self):
        # GitHub Actions passes these as secrets; on the Mac they come from .secrets/.
        self.base, token = os.environ.get('BOTTOMLESS_API_URL', '').strip(), os.environ.get('BOTTOMLESS_TOKEN', '').strip()
        if not (self.base and token):
            with open(os.path.join(ROOT, '.secrets/api_url')) as f: self.base = f.read().strip()
            with open(os.path.join(ROOT, '.secrets/app_token')) as f: token = f.read().strip()
        self.base = self.base.rstrip('/')
        self.s = requests.Session()
        self.s.headers['Authorization'] = f'Bearer {token}'
        adapter = requests.adapters.HTTPAdapter(pool_maxsize=16, max_retries=3)
        self.s.mount('https://', adapter)
        self.s.mount('http://', adapter)

    def get(self, path, **params):
        for attempt in range(5):
            r = self.s.get(self.base + path, params=params, timeout=60)
            if r.status_code < 500 and r.status_code != 429: break
            time.sleep(2 * (attempt + 1))
        if r.status_code == 429: raise SystemExit(f'cloud cap reached: {r.text[:200]}')
        r.raise_for_status()
        return r

    def post(self, path, body):
        for attempt in range(5):
            r = self.s.post(self.base + path, json=body, timeout=60)
            if r.status_code < 500: break
            time.sleep(2 * (attempt + 1))
        if r.status_code == 429: raise SystemExit(f'cloud cap reached: {r.text[:200]}')
        if not r.ok: raise RuntimeError(f'{path}: HTTP {r.status_code} {r.text[:300]}')
        return r.json()

    def assets(self):
        """Every asset in the library (the change feed from the start; the last row per id wins)."""
        out, since = {}, 0
        while True:
            page = self.get('/v1/changes', since=since, limit=1000).json()
            for a in page['assets']: out[a['id']] = a
            if not page.get('hasMore'): return out
            since = page['cursor']

    def faces(self):
        out, after = {}, ''
        while True:
            page = self.get('/v1/faces', after=after, limit=2000).json()
            for f in page['faces']: out[f['id']] = f
            if not page.get('next'): return out
            after = page['next']


# MARK: local state

def open_db():
    os.makedirs(STATE, exist_ok=True)
    db = sqlite3.connect(os.path.join(STATE, 'index.sqlite'))
    db.executescript('''
      CREATE TABLE IF NOT EXISTS assets (id TEXT PRIMARY KEY, faces INTEGER NOT NULL, error TEXT, at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS faces (id TEXT PRIMARY KEY, asset_id TEXT NOT NULL, x REAL, y REAL, w REAL, h REAL,
        score REAL, emb BLOB NOT NULL, person_id TEXT, rejected TEXT, sent_person TEXT, sent INTEGER NOT NULL DEFAULT 0);
    ''')
    return db


# MARK: models

def session(name):
    opts = ort.SessionOptions()
    opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    ort.set_default_logger_severity(3)
    # Core ML runs these about 2× (detector) and 25× (ArcFace) faster than the CPU, with the same embeddings (cos 0.9998).
    # Compiling for the Neural Engine takes ~30 s, so the compiled models are cached between runs.
    providers = ['CPUExecutionProvider']           # Linux (GitHub Actions): CPU; same embeddings to 4 decimals
    if 'CoreMLExecutionProvider' in ort.get_available_providers():
        cache = os.path.join(STATE, 'coreml-cache')
        os.makedirs(cache, exist_ok=True)
        providers.insert(0, ('CoreMLExecutionProvider', {'ModelCacheDirectory': cache}))
    return ort.InferenceSession(os.path.join(MODELS, name), opts, providers=providers)


class Detector:
    """SCRFD (det_10g): 3 strides, 2 anchors per cell, boxes and 5 landmarks as distances from the anchor center."""
    size = 640

    def __init__(self):
        self.s = session('det_10g.onnx')
        self.input = self.s.get_inputs()[0].name
        self.centers = {}

    def __call__(self, img):
        h, w = img.shape[:2]
        scale = min(self.size / h, self.size / w)
        nh, nw = int(round(h * scale)), int(round(w * scale))
        canvas = np.zeros((self.size, self.size, 3), dtype=np.uint8)
        canvas[:nh, :nw] = cv2.resize(img, (nw, nh))
        blob = cv2.dnn.blobFromImage(canvas, 1 / 128, (self.size, self.size), (127.5, 127.5, 127.5), swapRB=True)
        outs = [o[0] if o.ndim == 3 else o for o in self.s.run(None, {self.input: blob})]
        boxes, scores, kpss = [], [], []
        for i, stride in enumerate((8, 16, 32)):
            score, bbox, kps = outs[i].reshape(-1), outs[i + 3] * stride, outs[i + 6] * stride
            n = self.size // stride
            if n not in self.centers:
                c = np.stack(np.mgrid[:n, :n][::-1], axis=-1).astype(np.float32).reshape(-1, 2) * stride
                self.centers[n] = np.repeat(c, 2, axis=0)
            c = self.centers[n]
            keep = np.where(score >= MIN_SCORE)[0]
            if not len(keep): continue
            cc, b, k = c[keep], bbox[keep], kps[keep].reshape(len(keep), 5, 2)
            boxes.append(np.concatenate([cc - b[:, :2], cc + b[:, 2:]], axis=1))
            kpss.append(cc[:, None, :] + k)
            scores.append(score[keep])
        if not boxes: return []
        boxes, scores, kpss = np.concatenate(boxes) / scale, np.concatenate(scores), np.concatenate(kpss) / scale
        order = nms(boxes, scores, 0.4)
        return [(boxes[i], float(scores[i]), kpss[i]) for i in order]


def nms(boxes, scores, iou):
    x1, y1, x2, y2 = boxes.T
    area = (x2 - x1) * (y2 - y1)
    order, keep = scores.argsort()[::-1], []
    while len(order):
        i = order[0]
        keep.append(i)
        xx1, yy1 = np.maximum(x1[i], x1[order[1:]]), np.maximum(y1[i], y1[order[1:]])
        xx2, yy2 = np.minimum(x2[i], x2[order[1:]]), np.minimum(y2[i], y2[order[1:]])
        inter = np.maximum(0, xx2 - xx1) * np.maximum(0, yy2 - yy1)
        order = order[1:][inter / (area[i] + area[order[1:]] - inter) <= iou]
    return keep


class Embedder:
    """ArcFace (w600k_r50): a 112×112 face aligned on its 5 landmarks → a unit 512-d vector."""
    def __init__(self):
        self.s = session('w600k_r50.onnx')
        self.input = self.s.get_inputs()[0].name

    def __call__(self, img, kps_list):
        out = []
        for kps in kps_list:
            m, _ = cv2.estimateAffinePartial2D(kps.astype(np.float32), ARCFACE_DST, method=cv2.LMEDS)
            crop = cv2.warpAffine(img, m, (112, 112), borderValue=0.0)
            # One face per run: Core ML recompiles whenever the batch size changes (that made it ~20× slower).
            blob = cv2.dnn.blobFromImage(crop, 1 / 127.5, (112, 112), (127.5, 127.5, 127.5), swapRB=True)
            out.append(self.s.run(None, {self.input: blob})[0][0])
        e = np.array(out)
        return e / np.linalg.norm(e, axis=1, keepdims=True)


# MARK: index

def index(db, cloud, limit=None, shard=0, shards=1):
    assets = cloud.assets()
    ready = [a for a in assets.values() if a['status'] == 'ready' and a.get('hasPreview')]
    done = {r[0] for r in db.execute('SELECT id FROM assets WHERE error IS NULL')}
    todo = sorted((a for a in ready if a['id'] not in done and int(a['id'][:8], 16) % shards == shard), key=lambda a: -a['takenAt'])
    if limit: todo = todo[:limit]
    log(f'{len(ready)} photos in the library, {len(done)} indexed before, {len(todo)} to index'
        + (f' (shard {shard + 1} of {shards})' if shards > 1 else ''))
    if not todo: return
    det, emb = Detector(), Embedder()

    def fetch(a):
        try:
            return a, cloud.get(f"/v1/assets/{a['id']}/preview").content, None
        except Exception as e:
            return a, None, e

    def prefetched(pool, ahead=24):
        """Downloads run ahead of the models by at most `ahead` photos (unbounded, they outran them and the queued
        images filled memory until macOS killed the process)."""
        it, pending = iter(todo), set()
        while True:
            while len(pending) < ahead:
                a = next(it, None)
                if a is None: break
                pending.add(pool.submit(fetch, a))
            if not pending: return
            done, pending = cf.wait(pending, return_when=cf.FIRST_COMPLETED)
            for fut in done: yield fut.result()

    start, found = time.time(), 0
    with cf.ThreadPoolExecutor(6) as pool:
        for n, (a, data, err) in enumerate(prefetched(pool), 1):
            try:
                if err: raise err
                img = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
                if img is None: raise ValueError('preview is not an image')
                h, w = img.shape[:2]
                faces = [(b, s, k) for b, s, k in det(img) if min(b[2] - b[0], b[3] - b[1]) >= MIN_FACE_PX]
                vecs = emb(img, [k for _, _, k in faces]) if faces else []
                with db:
                    db.execute('DELETE FROM faces WHERE asset_id = ? AND sent = 0', (a['id'],))
                    for i, ((b, s, _), v) in enumerate(zip(faces, vecs)):
                        db.execute('''INSERT INTO faces (id, asset_id, x, y, w, h, score, emb) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                                      ON CONFLICT(id) DO NOTHING''',
                                   (f"{a['id']}-{i}", a['id'], max(0.0, b[0] / w), max(0.0, b[1] / h),
                                    (b[2] - b[0]) / w, (b[3] - b[1]) / h, s, v.astype(np.float32).tobytes()))
                    db.execute('INSERT OR REPLACE INTO assets (id, faces, error, at) VALUES (?, ?, NULL, ?)', (a['id'], len(faces), int(time.time())))
                found += len(faces)
            except Exception as e:
                with db: db.execute('INSERT OR REPLACE INTO assets (id, faces, error, at) VALUES (?, 0, ?, ?)', (a['id'], str(e)[:200], int(time.time())))
            if n % 200 == 0 or n == len(todo):
                rate = n / (time.time() - start)
                log(f'{n}/{len(todo)} photos, {found} faces, {rate:.1f} photos/s, ~{(len(todo) - n) / rate / 60:.0f} min left')


# MARK: group

def chinese_whispers(emb, edge_sim, k=30, rounds=25, seed=0):
    """Graph clustering: faces are nodes, the k most similar faces above `edge_sim` are weighted edges, and each node
    repeatedly takes the label its neighbors carry the most weight for."""
    n = len(emb)
    nbrs = [[] for _ in range(n)]
    for s in range(0, n, 2048):
        sims = emb[s:s + 2048] @ emb.T
        top = np.argpartition(-sims, min(k, n - 1), axis=1)[:, :k + 1]
        for r, row in enumerate(top):
            i = s + r
            for j in row:
                if j != i and sims[r, j] >= edge_sim: nbrs[i].append((int(j), float(sims[r, j])))
    labels = np.arange(n)
    rng = np.random.default_rng(seed)
    for _ in range(rounds):
        changed = 0
        for i in rng.permutation(n):
            if not nbrs[i]: continue
            w = {}
            for j, s in nbrs[i]: w[labels[j]] = w.get(labels[j], 0.0) + s
            best = max(w, key=w.get)
            if best != labels[i]: labels[i] = best; changed += 1
        if not changed: break
    return labels


def merge_close_groups(emb, labels, sim):
    """Chinese whispers splits one person by look (glasses, sunglasses, years apart). Groups whose average faces are
    this similar are the same person: on this library, same-person groups scored 0.89 and different people under 0.4."""
    ids = sorted(set(labels.tolist()))
    cent = np.stack([emb[labels == l].mean(0) for l in ids])
    cent /= np.linalg.norm(cent, axis=1, keepdims=True)
    parent = list(range(len(ids)))
    def root(i):
        while parent[i] != i: parent[i] = parent[parent[i]]; i = parent[i]
        return i
    s = cent @ cent.T
    for a, b in zip(*np.where(np.triu(s, 1) >= sim)): parent[root(a)] = root(b)
    remap = {l: ids[root(i)] for i, l in enumerate(ids)}
    return np.array([remap[l] for l in labels.tolist()])


def group(db, cloud):
    # The cloud is the truth for who each uploaded face belongs to (the phone merges and corrects people).
    remote = cloud.faces()
    with db:
        for fid, f in remote.items():
            db.execute('UPDATE faces SET person_id = ?, rejected = ?, sent_person = ?, sent = 1 WHERE id = ?',
                       (f['personId'], f['rejected'], f['personId'], fid))
    rows = db.execute('SELECT id, emb, person_id, rejected FROM faces').fetchall()
    if not rows: log('no faces yet'); return
    ids = [r[0] for r in rows]
    emb = np.stack([np.frombuffer(r[1], dtype=np.float32) for r in rows])
    person = [r[2] for r in rows]
    rejected = [r[3] for r in rows]

    # 1. Unassigned faces join the person they are closest to.
    people = sorted({p for p in person if p})
    joined = 0
    pool = [i for i, p in enumerate(person) if not p]
    if people and pool:
        cent = np.stack([emb[[i for i, p in enumerate(person) if p == q]].mean(0) for q in people])
        cent /= np.linalg.norm(cent, axis=1, keepdims=True)
        sims = emb[pool] @ cent.T
        for row, i in enumerate(pool):
            order = np.argsort(-sims[row])
            for c in order[:2]:
                if sims[row, c] < JOIN_SIM: break
                if people[c] != rejected[i]:
                    person[i] = people[c]; joined += 1; break
    # 2. The rest are grouped among themselves; big enough groups become new people.
    pool = [i for i, p in enumerate(person) if not p]
    created = 0
    if len(pool) >= MIN_PERSON:
        labels = merge_close_groups(emb[pool], chinese_whispers(emb[pool], EDGE_SIM), MERGE_SIM)
        groups = {}
        for row, l in enumerate(labels): groups.setdefault(l, []).append(pool[row])
        for members in groups.values():
            if len(members) < MIN_PERSON: continue
            pid = 'p' + uuid.uuid4().hex[:12]
            for i in members: person[i] = pid
            created += 1
    with db:
        for i, fid in enumerate(ids): db.execute('UPDATE faces SET person_id = ? WHERE id = ?', (person[i], fid))
    log(f'{len(ids)} faces: {joined} joined existing people, {created} new people, '
        f'{sum(1 for p in person if not p)} not grouped yet')
    upload(db, cloud)


def upload(db, cloud):
    rows = db.execute('''SELECT id, asset_id, person_id, x, y, w, h, score FROM faces
                         WHERE sent = 0 OR IFNULL(person_id, '') != IFNULL(sent_person, '')''').fetchall()
    log(f'uploading {len(rows)} faces')
    chunks = [rows[i:i + UPLOAD_CHUNK] for i in range(0, len(rows), UPLOAD_CHUNK)]

    def send(chunk):
        cloud.post('/v1/faces', {'faces': [{'id': r[0], 'assetId': r[1], 'personId': r[2], 'x': r[3], 'y': r[4],
                                            'w': r[5], 'h': r[6], 'score': r[7]} for r in chunk]})
        return chunk

    with cf.ThreadPoolExecutor(4) as pool:
        for n, fut in enumerate(cf.as_completed([pool.submit(send, c) for c in chunks]), 1):
            chunk = fut.result()
            with db:
                for r in chunk: db.execute('UPDATE faces SET sent = 1, sent_person = person_id WHERE id = ?', (r[0],))
            if n % 100 == 0: log(f'{n}/{len(chunks)} batches')
    log('done')


def merge(db, paths):
    """Adds what parallel index jobs (shards) found to this index."""
    for p in paths:
        db.execute('ATTACH DATABASE ? AS part', (p,))
        with db:
            db.execute('INSERT OR REPLACE INTO assets SELECT * FROM part.assets WHERE error IS NULL OR id NOT IN (SELECT id FROM assets)')
            db.execute('INSERT OR IGNORE INTO faces SELECT * FROM part.faces')
        db.execute('DETACH DATABASE part')
        log(f'merged {p}')


def status(db):
    a = db.execute('SELECT COUNT(*), SUM(error IS NOT NULL) FROM assets').fetchone()
    f = db.execute('SELECT COUNT(*), COUNT(DISTINCT person_id), SUM(person_id IS NULL), SUM(sent = 0) FROM faces').fetchone()
    print(f'photos indexed: {a[0]} ({a[1] or 0} failed) | faces: {f[0]} in {f[1]} people, {f[2] or 0} not grouped, {f[3] or 0} not uploaded')


def main():
    import argparse
    ap = argparse.ArgumentParser(description='Find and group the faces in Bottomless photos.')
    ap.add_argument('cmd', nargs='?', default='run', choices=['run', 'index', 'group', 'status', 'merge'])
    ap.add_argument('files', nargs='*', help='merge: index files from shard jobs')
    ap.add_argument('--limit', type=int, help='index at most this many photos')
    ap.add_argument('--shard', default='1/1', help='index only this part of the photos, e.g. 2/4 (for parallel jobs)')
    args = ap.parse_args()
    cmd, limit = args.cmd, args.limit
    shard, shards = (int(x) for x in args.shard.split('/'))
    db = open_db()
    if cmd == 'status': return status(db)
    if cmd == 'merge': merge(db, args.files); return status(db)
    import fcntl
    lock = open(os.path.join(STATE, 'run.lock'), 'a+')
    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: return log('another run is going (the 30-minute agent or a manual run); nothing to do')
    cloud = Cloud()
    if cmd in ('run', 'index'): index(db, cloud, limit, shard - 1, shards)
    if cmd in ('run', 'group'): group(db, cloud)
    status(db)


if __name__ == '__main__':
    main()
