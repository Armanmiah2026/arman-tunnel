// Session + CSRF + rate limiting for the Arman Tunnel admin Worker.
//
// Why cookies instead of a Bearer token in localStorage: the panel is a
// single-origin SPA served by this same Worker, so an httpOnly + Secure +
// SameSite=Strict cookie is strictly better — it cannot be read by injected
// JS, and it survives a reload without the client persisting a credential.
//
// CSRF: SameSite=Strict already blocks cross-site form posts, but we also do a
// double-submit check (readable `sensei_csrf` cookie must equal the
// `X-CSRF-Token` header, and both must match the value bound into the session
// token) so a subdomain or a proxy quirk cannot bypass it.

import { createToken, verifyToken, randomToken, timingSafeEqual } from './crypto.js';

export const SESSION_COOKIE = 'sensei_sess';
export const CSRF_COOKIE = 'sensei_csrf';
export const CSRF_HEADER = 'x-csrf-token';

/** 8 hours. Short enough to limit a stolen cookie, long enough for real work. */
export const SESSION_TTL_SECONDS = 8 * 3600;

const LOGIN_WINDOW_SECONDS = 900; // 15 min
const LOGIN_MAX_ATTEMPTS = 8;

export function sessionSecret(env) {
  if (!env.JWT_SECRET) throw new Error('JWT_SECRET is not configured');
  return env.JWT_SECRET;
}

// ---------------------------------------------------------------------------
// Cookies
// ---------------------------------------------------------------------------

export function parseCookies(request) {
  const out = {};
  const raw = request.headers.get('Cookie') || '';
  for (const part of raw.split(';')) {
    const i = part.indexOf('=');
    if (i < 0) continue;
    const k = part.slice(0, i).trim();
    if (k) out[k] = part.slice(i + 1).trim();
  }
  return out;
}

/**
 * Cookie attributes. `Secure` is omitted on plain-HTTP localhost so
 * `wrangler dev` works; everything else (including the deployed Worker) is
 * HTTPS, where Secure is mandatory for SameSite=Strict to behave.
 */
function cookieAttrs(request, { httpOnly, maxAge }) {
  const url = new URL(request.url);
  const isLocal = url.protocol === 'http:' && /^(localhost|127\.0\.0\.1)$/.test(url.hostname);
  const bits = ['Path=/', 'SameSite=Strict', `Max-Age=${maxAge}`];
  if (httpOnly) bits.push('HttpOnly');
  if (!isLocal) bits.push('Secure');
  return bits.join('; ');
}

export function sessionCookies(request, token, csrf) {
  return [
    `${SESSION_COOKIE}=${token}; ${cookieAttrs(request, { httpOnly: true, maxAge: SESSION_TTL_SECONDS })}`,
    // Readable by the SPA on purpose: it echoes the value back in the header.
    `${CSRF_COOKIE}=${csrf}; ${cookieAttrs(request, { httpOnly: false, maxAge: SESSION_TTL_SECONDS })}`,
  ];
}

export function clearedCookies(request) {
  return [
    `${SESSION_COOKIE}=; ${cookieAttrs(request, { httpOnly: true, maxAge: 0 })}`,
    `${CSRF_COOKIE}=; ${cookieAttrs(request, { httpOnly: false, maxAge: 0 })}`,
  ];
}

// ---------------------------------------------------------------------------
// Issue / verify
// ---------------------------------------------------------------------------

/** Mint a session for `username`. Returns the cookie strings to set. */
export async function issueSession(request, env, username, role) {
  const csrf = randomToken(18);
  const token = await createToken({ u: username, r: role || 'admin', csrf }, sessionSecret(env), SESSION_TTL_SECONDS);
  return { token, csrf, cookies: sessionCookies(request, token, csrf) };
}

/**
 * Authenticate a request. State-changing methods additionally require a valid
 * CSRF double-submit. Returns `{ valid, username?, reason? }`.
 */
export async function authenticate(request, env) {
  const cookies = parseCookies(request);
  let token = cookies[SESSION_COOKIE];
  // Bearer is still accepted for scripted/CLI use, but it can never satisfy
  // the CSRF check below unless the caller sends the header explicitly, which
  // a browser cross-site request cannot do.
  const auth = request.headers.get('Authorization') || '';
  if (!token && auth.startsWith('Bearer ')) token = auth.slice(7).trim();
  if (!token) return { valid: false, reason: 'no-session' };

  const res = await verifyToken(token, sessionSecret(env));
  if (!res.valid) return { valid: false, reason: res.reason };

  const method = request.method.toUpperCase();
  const needsCsrf = method !== 'GET' && method !== 'HEAD' && method !== 'OPTIONS';
  if (needsCsrf) {
    const header = request.headers.get(CSRF_HEADER) || '';
    const bound = res.payload.csrf || '';
    if (!header || !bound || !timingSafeEqual(header, bound)) {
      return { valid: false, reason: 'csrf' };
    }
    // When the cookie is present it must agree too (blocks header-only replay
    // from a context that cannot read the cookie).
    const cookieCsrf = cookies[CSRF_COOKIE];
    if (cookieCsrf && !timingSafeEqual(cookieCsrf, header)) {
      return { valid: false, reason: 'csrf' };
    }
  }
  return { valid: true, username: res.payload.u, role: res.payload.r || 'admin', csrf: res.payload.csrf, exp: res.payload.exp };
}

// ---------------------------------------------------------------------------
// Login rate limiting (per IP, KV-backed, fixed window)
// ---------------------------------------------------------------------------

export function clientIp(request) {
  return (
    request.headers.get('CF-Connecting-IP') ||
    request.headers.get('X-Forwarded-For') ||
    'unknown'
  ).split(',')[0].trim();
}

function limitKey(ip) {
  const window = Math.floor(Date.now() / 1000 / LOGIN_WINDOW_SECONDS);
  return `login_attempts:${window}:${ip}`;
}

/** `{ allowed, remaining, retryAfter }` for a login attempt from this IP. */
export async function checkLoginRate(env, ip) {
  // Fail CLOSED: a deploy that lost the KV binding used to disable the only
  // brute-force defense silently, with no signal.
  if (!env.SENSEI_KV) {
    console.error('SENSEI_KV binding missing — login rate limiting cannot run; refusing login');
    return { allowed: false, remaining: 0, retryAfter: 60, noStore: true };
  }
  const key = limitKey(ip);
  const count = parseInt((await env.SENSEI_KV.get(key)) || '0', 10) || 0;
  if (count >= LOGIN_MAX_ATTEMPTS) {
    const elapsed = Math.floor(Date.now() / 1000) % LOGIN_WINDOW_SECONDS;
    return { allowed: false, remaining: 0, retryAfter: LOGIN_WINDOW_SECONDS - elapsed };
  }
  return { allowed: true, remaining: LOGIN_MAX_ATTEMPTS - count };
}

export async function recordLoginFailure(env, ip) {
  if (!env.SENSEI_KV) return;
  const key = limitKey(ip);
  const count = (parseInt((await env.SENSEI_KV.get(key)) || '0', 10) || 0) + 1;
  await env.SENSEI_KV.put(key, String(count), { expirationTtl: LOGIN_WINDOW_SECONDS + 60 });
}

export async function clearLoginFailures(env, ip) {
  if (!env.SENSEI_KV) return;
  await env.SENSEI_KV.delete(limitKey(ip));
}
