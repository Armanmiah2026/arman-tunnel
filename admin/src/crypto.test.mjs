// Regression tests for the Worker's bundle/session crypto helpers.
// Run: node admin-panel/src/crypto.test.mjs

import assert from 'node:assert/strict';
import {
  encryptBundle,
  decryptBundle,
  bundleVersion,
  hashPassword,
  verifyPassword,
  verifyVipTicket,
} from './crypto.js';

let failures = 0;
async function test(name, fn) {
  try {
    await fn();
  } catch (e) {
    failures++;
    console.error('FAIL:', name, '\n', e.message);
  }
}

const env = (extra) => ({ ...extra });

await test('empty plaintext round-trips (off-by-one at exactly IV+tag)', async () => {
  const enc = await encryptBundle('', env({ APP_CERT_SHA256: 'a'.repeat(64) }));
  assert.ok(enc.startsWith('sensei:v3:'), 'v3 when a cert is configured');
  const dec = await decryptBundle(enc, env({ APP_CERT_SHA256: 'a'.repeat(64) }));
  assert.equal(dec.ok, true, 'must decrypt its own empty envelope: ' + dec.error);
  assert.equal(dec.plaintext, '');
});

await test('colon-formatted APP_CERT_SHA256 normalizes to the same key', async () => {
  const hex = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  const colon = hex.replace(/../g, '$&:').replace(/:$/, '').toUpperCase();
  const a = await encryptBundle('{"x":1}', env({ APP_CERT_SHA256: hex }));
  const b = await encryptBundle('{"x":1}', env({ APP_CERT_SHA256: colon }));
  const key = env({ APP_CERT_SHA256: hex });
  const decA = await decryptBundle(a, key);
  const decB = await decryptBundle(b, key);
  assert.ok(decA.ok && decB.ok, 'both spellings must produce app-derivable v3 keys');
  assert.equal(decA.plaintext, '{"x":1}');
  assert.equal(decB.plaintext, '{"x":1}');
});

await test('a typo-short APP_CERT_SHA256 degrades to v2 instead of poison-v3', async () => {
  const bad = env({ APP_CERT_SHA256: 'a9e4:0f07:deadbeef' }); // not 64 hex
  assert.equal(bundleVersion(bad), 'v2', 'malformed cert var must NOT flip to v3');
  const enc = await encryptBundle('{"x":1}', bad);
  assert.ok(enc.startsWith('sensei:v2:'));
});

await test('verifyPassword never throws on hostile stored hashes', async () => {
  // iterations=0 used to make WebCrypto throw → login 500 with the crypto
  // message echoed to the caller; huge iterations burned CPU until kill.
  for (const stored of [
    'pbkdf2$0$00$00',
    'pbkdf2$1$00$00',
    'pbkdf2$99999999999999$00$00',
    'pbkdf2$abc$00$00',
    'pbkdf2$200000', // truncated fields
    'not-a-hash-at-all',
    '',
  ]) {
    const r = await verifyPassword('whatever', stored);
    assert.equal(r.ok, false, `must reject, not throw: ${stored}`);
    assert.equal(typeof r.legacy, 'boolean', 'caller contract keeps `legacy`');
  }
});

await test('verifyPassword accepts a real pbkdf2 hash and flags legacy sha256', async () => {
  const h = await hashPassword('S3cret!');
  const good = await verifyPassword('S3cret!', h);
  assert.equal(good.ok, true);
  assert.equal(good.legacy, false);
  const bad = await verifyPassword('wrong', h);
  assert.equal(bad.ok, false);

  const { sha256Hex } = await import('./crypto.js');
  const legacy = await sha256Hex('S3cret!');
  const r = await verifyPassword('S3cret!', legacy);
  assert.equal(r.ok, true);
  assert.equal(r.legacy, true, 'login() migrates legacy entries on this flag');
});

// --- VIP unlock tickets -----------------------------------------------------
// Mint a ticket EXACTLY as libsenseicrypto.so does: key = SHA256(cert + ":" +
// VIP_SEED), envelope "sensei:vip:" + base64(iv|ct|tag), body
// "vip1|<configId>|<issuedMs>|<expiresMs>". This is the contract the Worker's
// /api/vip/resolve relies on, so the two sides must stay byte-compatible.

async function mintVipTicket(cert, configId, expiresMs) {
  const { VIP_SEED, sha256Bytes, b64encode } = await import('./crypto.js');
  const enc = new TextEncoder();
  const keyBytes = await sha256Bytes(cert + ':' + VIP_SEED);
  const key = await crypto.subtle.importKey('raw', keyBytes, { name: 'AES-GCM' }, false, ['encrypt']);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const now = Date.now();
  const ct = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv },
      key,
      enc.encode(`vip1|${configId}|${now}|${expiresMs}`),
    ),
  );
  const out = new Uint8Array(iv.length + ct.length);
  out.set(iv, 0);
  out.set(ct, iv.length);
  return 'sensei:vip:' + b64encode(out);
}

await test('a native-minted VIP ticket verifies for its own config', async () => {
  const cert = 'b'.repeat(64);
  const e = env({ APP_CERT_SHA256: cert });
  const ticket = await mintVipTicket(cert, 'cfg-1', Date.now() + 3600_000);
  const r = await verifyVipTicket(ticket, 'cfg-1', e);
  assert.equal(r.ok, true, 'must accept: ' + r.error);
  assert.equal(r.configId, 'cfg-1');
});

await test('a VIP ticket is rejected for a different configId', async () => {
  const cert = 'c'.repeat(64);
  const e = env({ APP_CERT_SHA256: cert });
  const ticket = await mintVipTicket(cert, 'cfg-1', Date.now() + 3600_000);
  const r = await verifyVipTicket(ticket, 'cfg-2', e);
  assert.equal(r.ok, false, 'one config\'s ticket must not unlock another');
});

await test('a VIP ticket does not verify under a different cert', async () => {
  const mint = 'd'.repeat(64);
  const e = env({ APP_CERT_SHA256: 'e'.repeat(64) });
  const ticket = await mintVipTicket(mint, 'cfg-1', Date.now() + 3600_000);
  const r = await verifyVipTicket(ticket, 'cfg-1', e);
  assert.equal(r.ok, false, 're-signed clones cannot reuse the release ticket');
});

await test('an expired VIP ticket is rejected', async () => {
  const cert = 'f'.repeat(64);
  const e = env({ APP_CERT_SHA256: cert });
  const ticket = await mintVipTicket(cert, 'cfg-1', Date.now() - 1000);
  const r = await verifyVipTicket(ticket, 'cfg-1', e);
  assert.equal(r.ok, false, 'expiry must be enforced server-side too');
});

await test('a tampered VIP ticket fails the GCM tag', async () => {
  const cert = '9'.repeat(64);
  const e = env({ APP_CERT_SHA256: cert });
  const ticket = await mintVipTicket(cert, 'cfg-1', Date.now() + 3600_000);
  const body = ticket.slice(11);
  const flipped = body.slice(0, 4) + (body[4] === 'A' ? 'B' : 'A') + body.slice(5);
  const r = await verifyVipTicket('sensei:vip:' + flipped, 'cfg-1', e);
  assert.equal(r.ok, false, 'edited bytes must not verify');
});

await test('VIP ticket verification needs APP_CERT_SHA256', async () => {
  const r = await verifyVipTicket('sensei:vip:whatever', 'cfg-1', env({}));
  assert.equal(r.ok, false, 'a Worker without the cert hash cannot verify');
});

if (failures) {
  console.error(`crypto: ${failures} FAILED`);
  process.exit(1);
}
console.log('crypto: all tests passed');
