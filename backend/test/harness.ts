// Starts a local S3 imitation (moto) and the Worker under `wrangler dev --local` for integration tests.
import { spawn, type ChildProcess } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir, homedir } from 'node:os';
import { join } from 'node:path';
import { createHash, randomBytes } from 'node:crypto';

export const TOKEN = 'test-token-' + randomBytes(8).toString('hex');
const MOTO = process.env.MOTO_SERVER ?? join(homedir(), 'freeraid/.venv/bin/moto_server');
const ROOT = new URL('..', import.meta.url).pathname;

async function waitFor(url: string, timeoutMs = 60000): Promise<void> {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    try { const r = await fetch(url); if (r.status < 500) return; } catch { /* not up yet */ }
    await new Promise((r) => setTimeout(r, 300));
  }
  throw new Error(`timed out waiting for ${url}`);
}

function run(cmd: string, args: string[], env: Record<string, string> = {}): Promise<void> {
  return new Promise((resolve, reject) => {
    const p = spawn(cmd, args, { cwd: ROOT, env: { ...process.env, CI: '1', WRANGLER_SEND_METRICS: 'false', ...env }, stdio: 'pipe' });
    let out = '';
    p.stdout.on('data', (d) => (out += d));
    p.stderr.on('data', (d) => (out += d));
    p.on('exit', (code) => (code === 0 ? resolve() : reject(new Error(`${cmd} ${args.join(' ')} failed:\n${out}`))));
  });
}

export interface Stack { base: string; mode: 's3' | 'r2'; motoBase: string; stop(): Promise<void> }

export async function startStack(mode: 's3' | 'r2', port: number, motoPort: number, extraVars: Record<string, string> = {}): Promise<Stack> {
  const persist = mkdtempSync(join(tmpdir(), 'bottomless-test-'));
  const procs: ChildProcess[] = [];
  const motoBase = `http://127.0.0.1:${motoPort}`;
  if (mode === 's3') {
    procs.push(spawn(MOTO, ['-H', '127.0.0.1', '-p', String(motoPort)], { stdio: 'ignore' }));
    await waitFor(motoBase);
    const r = await fetch(`${motoBase}/test-originals`, { method: 'PUT' });
    if (!r.ok) throw new Error(`could not create bucket in moto: ${r.status}`);
  }
  await run('npx', ['wrangler', 'd1', 'migrations', 'apply', 'bottomless-catalog', '--local', '--persist-to', persist]);
  const vars: Record<string, string> = {
    APP_TOKEN: TOKEN, ORIGINALS_MODE: mode, ORIG_ENDPOINT: motoBase, ORIG_BUCKET: 'test-originals',
    ORIG_REGION: 'us-east-1', ORIG_ACCESS_KEY_ID: 'test', ORIG_SECRET_ACCESS_KEY: 'test', ...extraVars,
  };
  const args = ['wrangler', 'dev', '--local', '--ip', '127.0.0.1', '--port', String(port), '--persist-to', persist,
                '--show-interactive-dev-session=false', '--test-scheduled',
                ...Object.entries(vars).flatMap(([k, v]) => ['--var', `${k}:${v}`])];
  const w = spawn('npx', args, { cwd: ROOT, env: { ...process.env, CI: '1', WRANGLER_SEND_METRICS: 'false' }, stdio: 'pipe', detached: true });
  let log = '';
  w.stdout!.on('data', (d) => (log += d));
  w.stderr!.on('data', (d) => (log += d));
  procs.push(w);
  const base = `http://127.0.0.1:${port}`;
  try { await waitFor(`${base}/v1/health`, 90000); } catch (e) { throw new Error(`${(e as Error).message}\n${log}`); }
  return {
    base, mode, motoBase,
    async stop() {
      for (const p of procs) {
        try { if (p === w && p.pid) process.kill(-p.pid, 'SIGTERM'); else p.kill('SIGTERM'); } catch { /* already gone */ }
      }
      await new Promise((r) => setTimeout(r, 500));
      rmSync(persist, { recursive: true, force: true });
    },
  };
}

export function fakeFile(bytes: number, seed = randomBytes(4).toString('hex')) {
  const data = Buffer.concat([Buffer.from(seed), randomBytes(bytes)]);
  return {
    data,
    sha256: createHash('sha256').update(data).digest('hex'),
    md5: createHash('md5').update(data).digest('hex'),
  };
}
