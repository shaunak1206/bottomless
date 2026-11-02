import { presign, uriEncode, type Flavor } from './sigv4.ts';
import type { Env } from './env.ts';

export interface UploadTarget {
  url: string;
  method: 'PUT';
  headers: Record<string, string>;   // headers the client must send (e.g. Authorization for the r2 fallback)
}

export interface HeadResult {
  size: number;
  etag: string | null;               // MD5 hex for single-part uploads on S3, GCS and R2
}

// Where originals (full-resolution files) live. Production: Google Cloud Storage via presigned URLs.
export interface OriginalStore {
  uploadTarget(key: string, contentType: string, origin: string): Promise<UploadTarget>;
  downloadUrl(key: string, origin: string, filename?: string): Promise<string>;
  head(key: string): Promise<HeadResult | null>;
  delete(key: string): Promise<void>;
}

const UPLOAD_TTL = 6 * 3600;     // background uploads on the phone can start late
const DOWNLOAD_TTL = 3600;

export class S3Store implements OriginalStore {
  constructor(
    private endpoint: string,
    private bucket: string,
    private region: string,
    private accessKeyId: string,
    private secret: string,
    private flavor: Flavor = 'aws',
  ) {}

  private objectUrl(key: string): string {
    return `${this.endpoint.replace(/\/$/, '')}/${this.bucket}/${uriEncode(key, false)}`;
  }

  private sign(method: string, key: string, ttl: number, extraQuery?: Record<string, string>): Promise<string> {
    return presign({
      method, url: this.objectUrl(key), accessKeyId: this.accessKeyId, secretAccessKey: this.secret,
      region: this.region, expiresSeconds: ttl, flavor: this.flavor, extraQuery,
    });
  }

  async uploadTarget(key: string, contentType: string): Promise<UploadTarget> {
    return { url: await this.sign('PUT', key, UPLOAD_TTL), method: 'PUT', headers: { 'Content-Type': contentType } };
  }

  async downloadUrl(key: string, _origin: string, filename?: string): Promise<string> {
    const extra = filename ? { 'response-content-disposition': `attachment; filename="${filename.replace(/"/g, '')}"` } : undefined;
    return this.sign('GET', key, DOWNLOAD_TTL, extra);
  }

  async head(key: string): Promise<HeadResult | null> {
    const res = await fetch(await this.sign('HEAD', key, 300), { method: 'HEAD' });
    if (res.status === 404) return null;
    if (!res.ok) throw new Error(`HEAD ${key} -> ${res.status}`);
    return { size: Number(res.headers.get('content-length') ?? -1), etag: cleanEtag(res.headers.get('etag')) };
  }

  async delete(key: string): Promise<void> {
    const res = await fetch(await this.sign('DELETE', key, 300), { method: 'DELETE' });
    if (!res.ok && res.status !== 404) throw new Error(`DELETE ${key} -> ${res.status}`);
  }
}

// Fallback: originals in an R2 bucket, streamed through the Worker's /v1/blob routes.
export class R2Store implements OriginalStore {
  constructor(private bucket: R2Bucket, private token: string) {}

  async uploadTarget(key: string, contentType: string, origin: string): Promise<UploadTarget> {
    return { url: `${origin}/v1/blob/${uriEncode(key, false)}`, method: 'PUT',
             headers: { 'Content-Type': contentType, Authorization: `Bearer ${this.token}` } };
  }

  async downloadUrl(key: string, origin: string): Promise<string> {
    // Short-lived signed link so the app (or a share page) can hand the URL to AVPlayer / a download without headers.
    const exp = Date.now() + DOWNLOAD_TTL * 1000;
    const sig = await blobSignature(this.token, key, exp);
    return `${origin}/v1/blob/${uriEncode(key, false)}?exp=${exp}&sig=${sig}`;
  }

  async head(key: string): Promise<HeadResult | null> {
    const o = await this.bucket.head(key);
    return o ? { size: o.size, etag: cleanEtag(o.httpEtag) } : null;
  }

  async delete(key: string): Promise<void> {
    await this.bucket.delete(key);
  }
}

export async function blobSignature(token: string, key: string, exp: number): Promise<string> {
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(token), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(`${key}\n${exp}`));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function cleanEtag(e: string | null): string | null {
  if (!e) return null;
  return e.replace(/^W\//, '').replace(/"/g, '').toLowerCase();
}

export function originalStore(env: Env): OriginalStore {
  if (env.ORIGINALS_MODE === 'r2') return new R2Store(env.ORIGINALS_R2, env.APP_TOKEN);
  if (!env.ORIG_BUCKET || !env.ORIG_ACCESS_KEY_ID || !env.ORIG_SECRET_ACCESS_KEY) {
    throw new Error('originals store is not configured (ORIG_BUCKET / ORIG_ACCESS_KEY_ID / ORIG_SECRET_ACCESS_KEY)');
  }
  const flavor: Flavor = env.ORIG_FLAVOR === 'goog' ? 'goog' : 'aws';
  return new S3Store(env.ORIG_ENDPOINT, env.ORIG_BUCKET, env.ORIG_REGION || 'auto',
                     env.ORIG_ACCESS_KEY_ID, env.ORIG_SECRET_ACCESS_KEY, flavor);
}
