import { test } from 'node:test';
import assert from 'node:assert/strict';
import { presign, uriEncode } from '../src/sigv4.ts';

// The worked example from AWS's "Authenticating Requests: Using Query Parameters (SigV4)" documentation.
test('presign matches the AWS documentation example', async () => {
  const url = await presign({
    method: 'GET',
    url: 'https://examplebucket.s3.amazonaws.com/test.txt',
    accessKeyId: 'AKIAIOSFODNN7EXAMPLE',
    secretAccessKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
    region: 'us-east-1',
    expiresSeconds: 86400,
    now: new Date('2013-05-24T00:00:00Z'),
  });
  assert.equal(new URL(url).searchParams.get('X-Amz-Signature'),
    'aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404');
  assert.ok(url.includes('X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request'));
});

test('GOOG4 flavour uses Google prefixes', async () => {
  const url = await presign({
    method: 'PUT', url: 'https://storage.googleapis.com/bucket/o/abc', accessKeyId: 'GOOGKEY', secretAccessKey: 'secret',
    region: 'auto', expiresSeconds: 60, flavor: 'goog', now: new Date('2026-01-01T00:00:00Z'),
  });
  const q = new URL(url).searchParams;
  assert.equal(q.get('X-Goog-Algorithm'), 'GOOG4-HMAC-SHA256');
  assert.equal(q.get('X-Goog-Credential'), 'GOOGKEY/20260101/auto/storage/goog4_request');
  assert.match(q.get('X-Goog-Signature') ?? '', /^[0-9a-f]{64}$/);
});

test('uriEncode follows RFC 3986 and keeps slashes in paths', () => {
  assert.equal(uriEncode('a b/c~d'), 'a%20b%2Fc~d');
  assert.equal(uriEncode('o/a b.jpg', false), 'o/a%20b.jpg');
  assert.equal(uriEncode('é'), '%C3%A9');
});
