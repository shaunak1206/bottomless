// Query-string presigning (AWS Signature Version 4). Google Cloud Storage's XML API accepts the same scheme with HMAC
// keys, either as AWS4-HMAC-SHA256 or as its own GOOG4-HMAC-SHA256 flavour (same math, different prefixes).

export type Flavor = 'aws' | 'goog';

export interface PresignOptions {
  method: string;
  url: string;                     // full URL including host and path; existing query params are kept
  accessKeyId: string;
  secretAccessKey: string;
  region: string;
  service?: string;                // 's3' for AWS flavour, 'storage' for GOOG flavour
  expiresSeconds: number;
  now?: Date;
  flavor?: Flavor;
  extraQuery?: Record<string, string>;
}

const enc = new TextEncoder();

function toHex(buf: ArrayBuffer): string {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

async function hmac(key: ArrayBuffer | Uint8Array, data: string): Promise<ArrayBuffer> {
  const k = await crypto.subtle.importKey('raw', key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return crypto.subtle.sign('HMAC', k, enc.encode(data));
}

async function sha256Hex(data: string): Promise<string> {
  return toHex(await crypto.subtle.digest('SHA-256', enc.encode(data)));
}

// RFC 3986 encoding as SigV4 requires: everything except unreserved characters.
export function uriEncode(s: string, encodeSlash = true): string {
  let out = '';
  for (const ch of s) {
    if (/[A-Za-z0-9\-_.~]/.test(ch)) out += ch;
    else if (ch === '/' && !encodeSlash) out += ch;
    else for (const b of enc.encode(ch)) out += '%' + b.toString(16).toUpperCase().padStart(2, '0');
  }
  return out;
}

function amzDate(d: Date): { datetime: string; date: string } {
  const datetime = d.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
  return { datetime, date: datetime.slice(0, 8) };
}

export async function presign(o: PresignOptions): Promise<string> {
  const flavor = o.flavor ?? 'aws';
  const p = flavor === 'aws'
    ? { alg: 'AWS4-HMAC-SHA256', keyPrefix: 'AWS4', term: 'aws4_request', q: 'X-Amz-', service: o.service ?? 's3' }
    : { alg: 'GOOG4-HMAC-SHA256', keyPrefix: 'GOOG4', term: 'goog4_request', q: 'X-Goog-', service: o.service ?? 'storage' };
  const url = new URL(o.url);
  const { datetime, date } = amzDate(o.now ?? new Date());
  const scope = `${date}/${o.region}/${p.service}/${p.term}`;

  const params: [string, string][] = [];
  url.searchParams.forEach((v, k) => params.push([k, v]));
  for (const [k, v] of Object.entries(o.extraQuery ?? {})) params.push([k, v]);
  params.push(
    [`${p.q}Algorithm`, p.alg],
    [`${p.q}Credential`, `${o.accessKeyId}/${scope}`],
    [`${p.q}Date`, datetime],
    [`${p.q}Expires`, String(o.expiresSeconds)],
    [`${p.q}SignedHeaders`, 'host'],
  );
  const canonicalQuery = params
    .map(([k, v]) => [uriEncode(k), uriEncode(v)] as const)
    .sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0))
    .map(([k, v]) => `${k}=${v}`)
    .join('&');
  // The path is already percent-encoded by URL(); decode and re-encode so it matches SigV4's rules exactly.
  const canonicalPath = uriEncode(decodeURIComponent(url.pathname), false);
  const host = url.host;
  const canonicalRequest = [o.method.toUpperCase(), canonicalPath, canonicalQuery, `host:${host}\n`, 'host', 'UNSIGNED-PAYLOAD'].join('\n');
  const stringToSign = [p.alg, datetime, scope, await sha256Hex(canonicalRequest)].join('\n');

  let key: ArrayBuffer = await hmac(enc.encode(p.keyPrefix + o.secretAccessKey), date);
  key = await hmac(key, o.region);
  key = await hmac(key, p.service);
  key = await hmac(key, p.term);
  const signature = toHex(await hmac(key, stringToSign));
  return `${url.protocol}//${host}${canonicalPath}?${canonicalQuery}&${p.q}Signature=${signature}`;
}
