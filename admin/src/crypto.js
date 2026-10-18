// Crypto primitives for the Arman Tunnel admin Worker.
//
// Two independent concerns live here:
//
//  1. CONFIG BUNDLE ENCRYPTION — must stay byte-compatible with
//     `android/app/src/main/kotlin/com/sensei/tunnel/AppSecurity.kt`:
//       sensei:v3:<base64(iv‖ct‖tag)>  AES-256-GCM, key = SHA256(certHash + ":" + pepper)
//       sensei:v2:<base64(iv‖ct‖tag)>  AES-256-GCM, key = SHA256(fixed seed)
//     v1 (XOR) is decrypt-only legacy and is never produced here.
//
//  2. ADMIN SESSIONS — HS256 tokens delivered in an httpOnly cookie, plus a
//     PBKDF2 password hash for KV-stored extra admins. Everything is
//     constant-time compared.

export const V2_SEED = 'ArmanTunnel:Armanmiah2026:v2';
export const V3_PEPPER_DEFAULT = 'arman::cfg::v3::2026';

// VIP unlock ticket (mirrors OB_VIP_SEED in libsenseicrypto.so). A ticket is
// `sensei:vip:<base64(iv‖ct‖tag)>`, AES-256-GCM, key = SHA256(certHash + ":" +
// VIP_SEED), plaintext `vip1|<configId>|<issuedMs>|<expiresMs>`. The app mints
// and verifies them natively; the Worker can verify a presented ticket here so
// /api/vip/resolve only hands a VIP endpoint to an unlocked build.
export const VIP_SEED = 'ArmanTunnel:Armanmiah2026:vip';

const enc = new TextEncoder();
const dec = new TextDecoder();

// ---------------------------------------------------------------------------
// Byte helpers
// ---------------------------------------------------------------------------

export async function sha256Bytes(input) {
  const data = typeof input === 'string' ? enc.encode(input) : input;
  return new Uint8Array(await crypto.subtle.digest('SHA-256', data));
}

export async function sha256Hex(input) {
  return toHex(await sha256Bytes(input));
}

export function toHex(bytes) {
  let s = '';
  for (const b of bytes) s += b.toString(16).padStart(2, '0');
  return s;
}

export function fromHex(hex) {
  const clean = String(hex || '').trim().toLowerCase();
  const out = new Uint8Array(Math.floor(clean.length / 2));
  for (let i = 0; i < out.length; i++) out[i] = parseInt(clean.substr(i * 2, 2), 16);
  return out;
}

export function b64encode(bytes) {
  let s = '';
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s);
}

export function b64decode(str) {
  const bin = atob(String(str || ''));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function b64urlEncode(bytes) {
  return b64encode(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function b64urlDecode(str) {
  let s = String(str || '').replace(/-/g, '+').replace(/_/g, '/');
  while (s.length % 4) s += '=';
  return b64decode(s);
}

/** Constant-time comparison of two strings (length leak only). */
export function timingSafeEqual(a, b) {
  const x = String(a ?? '');
  const y = String(b ?? '');
  if (x.length !== y.length) return false;
  let r = 0;
  for (let i = 0; i < x.length; i++) r |= x.charCodeAt(i) ^ y.charCodeAt(i);
  return r === 0;
}

/** Constant-time comparison of two byte arrays. */
export function timingSafeEqualBytes(a, b) {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a[i] ^ b[i];
  return r === 0;
}

// ---------------------------------------------------------------------------
// Config bundle encryption (app-compatible)
// ---------------------------------------------------------------------------

/** Which envelope version this Worker will produce, given its bindings. */
export function bundleVersion(env) {
  return certHash(env) ? 'v3' : 'v2';
}

export function certHash(env) {
  // Accept the openssl colon-spaced fingerprint form too, but treat anything
  // that is not 64 hex as UNSET: a typo'd APP_CERT_SHA256 used to flip the
  // worker into v3 with a key no app can ever derive, while the panel's own
  // encrypt→decrypt round-trip (same env, same key) "verified" happily —
  // a silent total outage of the config feed.
  const raw = String(env.APP_CERT_SHA256 || '').trim().toLowerCase().replace(/[^0-9a-f]/g, '');
  if (raw && raw.length !== 64) {
    console.error('APP_CERT_SHA256 is not 64 hex chars — falling back to v2 bundles');
    return '';
  }
  return raw;
}

async function bundleKey(env, usage) {
  const cert = certHash(env);
  const seed = cert ? cert + ':' + (env.CONFIG_V3_PEPPER || V3_PEPPER_DEFAULT) : V2_SEED;
  const keyBytes = await sha256Bytes(seed);
  return crypto.subtle.importKey('raw', keyBytes, { name: 'AES-GCM' }, false, usage);
}

/**
 * Encrypt a plaintext string into the app's envelope format.
 * Returns `sensei:v3:<base64>` when a cert hash is configured, else `sensei:v2:`.
 */
export async function encryptBundle(plaintext, env) {
  const key = await bundleKey(env, ['encrypt']);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(
    await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, enc.encode(plaintext)),
  );
  const out = new Uint8Array(iv.length + ct.length);
  out.set(iv, 0);
  out.set(ct, iv.length);
  return `sensei:${bundleVersion(env)}:` + b64encode(out);
}

/**
 * Decrypt an envelope this Worker could have produced. Used by the panel's
 * verify step so an admin can prove the published file really opens — with the
 * SAME key the app will use, not a base64 stand-in.
 */
export async function decryptBundle(body, env) {
  const trimmed = String(body || '').trim();
  const expected = `sensei:${bundleVersion(env)}:`;
  if (!trimmed.startsWith('sensei:')) {
    return { ok: false, error: 'Not a sensei envelope (missing "sensei:vN:" prefix)' };
  }
  const version = trimmed.slice(7, 9);
  if (!trimmed.startsWith(expected)) {
    return {
      ok: false,
      error: `Envelope is ${version} but this Worker is configured for ${bundleVersion(env)} — ` +
        (version === 'v3'
          ? 'set APP_CERT_SHA256 to the signing cert of the build that produced it'
          : 'clear APP_CERT_SHA256 to read v2 bundles'),
    };
  }
  try {
    const raw = b64decode(trimmed.slice(expected.length));
    // IV(12) + tag(16) = 28 is a LEGITIMATE empty-plaintext envelope that
    // encryptBundle itself produces — the old `<= 28` rejected its own output.
    if (raw.length < 28) return { ok: false, error: 'Envelope too short to contain IV + tag' };
    const key = await bundleKey(env, ['decrypt']);
    const plain = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: raw.slice(0, 12) },
      key,
      raw.slice(12),
    );
    return { ok: true, version, plaintext: dec.decode(plain) };
  } catch (e) {
    return { ok: false, error: 'AES-GCM authentication failed — wrong key or corrupt file' };
  }
}

// ---------------------------------------------------------------------------
// VIP unlock tickets (server-side verification for /api/vip/resolve)
// ---------------------------------------------------------------------------

const VIP_TICKET_PREFIX = 'sensei:vip:';

/**
 * Verify a native-minted VIP unlock ticket.
 *
 * Returns { ok: true, configId, expiresAt } when the envelope authenticates
 * under the cert-bound key, names `configId`, and is still valid. Requires
 * APP_CERT_SHA256: the ticket key is derived from the app's signing cert, so
 * a Worker without the cert hash cannot verify tickets (returns ok:false).
 */
export async function verifyVipTicket(ticket, configId, env) {
  const cert = certHash(env);
  if (!cert) return { ok: false, error: 'no APP_CERT_SHA256 — cannot verify VIP tickets' };
  const trimmed = String(ticket || '').trim();
  if (!trimmed.startsWith(VIP_TICKET_PREFIX)) return { ok: false, error: 'not a VIP ticket' };
  const now = Date.now();
  try {
    const raw = b64decode(trimmed.slice(VIP_TICKET_PREFIX.length));
    if (raw.length < 28) return { ok: false, error: 'ticket too short' };
    const keyBytes = await sha256Bytes(cert + ':' + VIP_SEED);
    const key = await crypto.subtle.importKey('raw', keyBytes, { name: 'AES-GCM' }, false, ['decrypt']);
    const plain = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: raw.slice(0, 12) },
      key,
      raw.slice(12),
    );
    const parts = dec.decode(plain).split('|');
    if (parts.length !== 4 || parts[0] !== 'vip1') return { ok: false, error: 'malformed ticket body' };
    const [, tConfigId, issued, expires] = parts;
    const issuedMs = Number(issued);
    const expiresMs = Number(expires);
    if (!Number.isFinite(issuedMs) || !Number.isFinite(expiresMs)) {
      return { ok: false, error: 'bad ticket timestamps' };
    }
    if (expiresMs <= issuedMs) return { ok: false, error: 'ticket lifetime invalid' };
    if (now >= expiresMs) return { ok: false, error: 'ticket expired' };
    if (configId != null && String(configId) !== tConfigId) {
      return { ok: false, error: 'ticket is for a different config' };
    }
    return { ok: true, configId: tConfigId, expiresAt: expiresMs };
  } catch (e) {
    return { ok: false, error: 'VIP ticket authentication failed' };
  }
}

// ---------------------------------------------------------------------------
// Admin password hashing (PBKDF2-SHA256)
// ---------------------------------------------------------------------------

const PBKDF2_ITERATIONS = 100000;

/** Hash a password for KV storage. Format: `pbkdf2$<iter>$<saltHex>$<hashHex>`. */
export async function hashPassword(password, iterations = PBKDF2_ITERATIONS) {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const hash = await pbkdf2(password, salt, iterations);
  return `pbkdf2$${iterations}$${toHex(salt)}$${toHex(hash)}`;
}

/**
 * Verify a password against a stored hash. Accepts the legacy bare
 * SHA-256 hex format so existing admins keep working; `legacy: true` in the
 * result tells the caller to re-hash and store the modern format.
 */
export async function verifyPassword(password, stored) {
  const s = String(stored || '');
  if (s.startsWith('pbkdf2$')) {
    const [, iterStr, saltHex, hashHex] = s.split('$');
    const iterations = parseInt(iterStr, 10);
    // The stored `iterations` is attacker-influenced the moment KV leaks:
    // 0 → WebCrypto throws (every login 500s with the crypto message echoed);
    // 1 → work-factor downgrade; 1e12 → CPU burn. Bound it, never throw.
    if (!Number.isInteger(iterations) || iterations < 1000 || iterations > 1000000) {
      return { ok: false, legacy: false };
    }
    if (!saltHex || !hashHex) return { ok: false, legacy: false };
    try {
      const hash = await pbkdf2(password, fromHex(saltHex), iterations);
      return { ok: timingSafeEqualBytes(hash, fromHex(hashHex)), legacy: false };
    } catch {
      return { ok: false, legacy: false };
    }
  }
  // Legacy: plain SHA-256 hex of the password. Accepted for compatibility —
  // login() migrates such an entry to PBKDF2 right after a `legacy` success.
  if (/^[0-9a-f]{64}$/i.test(s)) {
    const hex = await sha256Hex(password);
    return { ok: timingSafeEqual(hex, s.toLowerCase()), legacy: true };
  }
  return { ok: false, legacy: false };
}

async function pbkdf2(password, salt, iterations) {
  const key = await crypto.subtle.importKey('raw', enc.encode(password), 'PBKDF2', false, [
    'deriveBits',
  ]);
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', salt, iterations, hash: 'SHA-256' },
    key,
    256,
  );
  return new Uint8Array(bits);
}

// ---------------------------------------------------------------------------
// Session tokens (HS256, base64url, seconds-based exp)
// ---------------------------------------------------------------------------

async function hmacKey(secret, usage) {
  return crypto.subtle.importKey(
    'raw',
    enc.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    usage,
  );
}

/**
 * Mint a session token. `csrf` is embedded so the double-submit cookie check
 * can be verified without another KV read.
 */
export async function createToken(payload, secret, ttlSeconds) {
  const now = Math.floor(Date.now() / 1000);
  const header = b64urlEncode(enc.encode(JSON.stringify({ alg: 'HS256', typ: 'JWT' })));
  const body = b64urlEncode(
    enc.encode(JSON.stringify({ ...payload, iat: now, exp: now + ttlSeconds })),
  );
  const key = await hmacKey(secret, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, enc.encode(`${header}.${body}`));
  return `${header}.${body}.${b64urlEncode(new Uint8Array(sig))}`;
}

/** Verify a session token. Returns `{ valid, payload?, reason? }`. */
export async function verifyToken(token, secret) {
  const parts = String(token || '').split('.');
  if (parts.length !== 3) return { valid: false, reason: 'malformed' };
  const [h, p, s] = parts;
  try {
    const key = await hmacKey(secret, ['verify']);
    const ok = await crypto.subtle.verify('HMAC', key, b64urlDecode(s), enc.encode(`${h}.${p}`));
    if (!ok) return { valid: false, reason: 'signature' };
    const payload = JSON.parse(dec.decode(b64urlDecode(p)));
    const now = Math.floor(Date.now() / 1000);
    if (typeof payload.exp !== 'number' || payload.exp <= now) {
      return { valid: false, reason: 'expired' };
    }
    return { valid: true, payload };
  } catch {
    return { valid: false, reason: 'malformed' };
  }
}

export function randomToken(bytes = 24) {
  return b64urlEncode(crypto.getRandomValues(new Uint8Array(bytes)));
}
