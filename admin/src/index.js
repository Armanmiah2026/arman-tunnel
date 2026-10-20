// Arman Tunnel Admin Panel — Cloudflare Worker entry point.
//
// Architecture:
//   config-schema.js  the ONLY wire format between panel and app
//   crypto.js         AES-GCM bundle envelopes (byte-compatible with the app),
//                     HS256 sessions, PBKDF2 password hashing
//   session.js        httpOnly-cookie sessions, CSRF double-submit, rate limit
//   github.js         Contents-API publishing with sha-race retry + CDN verify
//
// The app NEVER calls this Worker. It downloads two encrypted files from the
// configs repo through the config.* custom domain:
//   $GITHUB_FILE            → JSON array of active ServerConfig objects
//   $GITHUB_SETTINGS_FILE   → { api, settings, backend, categories, version, info }
// A third file, sensei_backup.enc, carries an encrypted full-panel snapshot
// (pushed on every publish) so the Dev can restore everything if KV is lost.
// Every mutation below re-publishes the files and reports per-file status, so
// "saved but never reached GitHub" can no longer happen silently.

import {
  normalizeConfig,
  validateConfig,
  parseAnyConfigText,
  splitSubscription,
  buildShareLink,
  toAppConfig,
  dedupeKey,
  protocolLabel,
  expandConfigPayloads,
  normalizeServer,
  validateServer,
  validateVariantConfig,
  joinServerIntoConfig,
  serverToAppConfig,
  isProxyNode,
  normalizeCategoryEntity,
  validateCategoryEntity,
  normalizeCapabilityType,
  validateCapabilityType,
  inferCapability,
  familyOf,
  DEFAULT_CAPABILITY_TYPES,
  DEFAULT_CAPABILITY_DESCRIPTIONS,
} from './config-schema.js';
import {
  encryptBundle,
  decryptBundle,
  bundleVersion,
  certHash,
  hashPassword,
  verifyPassword,
  timingSafeEqual,
  verifyVipTicket,
} from './crypto.js';
import {
  authenticate,
  clearedCookies,
  checkLoginRate,
  clearLoginFailures,
  recordLoginFailure,
  clientIp,
  issueSession,
  parseCookies,
  CSRF_COOKIE,
} from './session.js';
import { fetchPublished, githubConfigured, putFile, rawUrlFor, repoInfo } from './github.js';
import { uploadToImgbb, decodeBase64Image } from './imgbb.js';
import { PRIVACY_HTML, TERMS_HTML } from './legal.js';

const MAX_BODY_BYTES = 8 * 1024 * 1024; // .ovpn bodies can be chunky

// ---------------------------------------------------------------------------
// Dev accounts — set the `DEV_ACCOUNTS` secret to "user:pass[,user2:pass2]"
// (`wrangler secret put DEV_ACCOUNTS`). Unset → nobody has the dev role; the
// primary admin (ADMIN_USER + ADMIN_PASSWORD) still works, and more manager
// accounts can be added in the panel. Devs can add/remove admins and "Delete
// All Nodes"; admins cannot.
// ---------------------------------------------------------------------------

function devAccounts(env) {
  return String(env.DEV_ACCOUNTS || '')
    .split(',')
    .map((pair) => {
      const i = pair.indexOf(':');
      return i > 0
        ? { username: pair.slice(0, i).trim(), password: pair.slice(i + 1).trim() }
        : null;
    })
    .filter((a) => a && a.username);
}

function isDev(role) { return role === 'dev'; }

/** Require Dev role; returns a 403 Response if the caller is not a Dev, or null if OK. */
function requireDev(auth) {
  if (isDev(auth.role)) return null;
  return jsonResponse({ ok: false, error: 'Only Dev accounts can do this.' }, 403);
}

/** 400 response carrying a validator's {errors, warnings} payload. */
function validationError(v) {
  return jsonResponse(
    { ok: false, error: (v.errors && v.errors[0] && v.errors[0].message) || 'Validation failed', errors: v.errors || [], warnings: v.warnings || [] },
    400,
  );
}

/** Build the actor prefix for log entries: [Dev "X"] or [Admin "X"]. */
function logActor(auth) {
  return isDev(auth.role) ? `[Dev "${auth.username}"]` : `[Admin "${auth.username}"]`;
}

export default {
  async fetch(request, env, ctx) {
    try {
      return await handle(request, env, ctx);
    } catch (e) {
      // Structured, non-leaking error surface.
      const msg = String((e && e.message) || e);
      console.error('worker:', msg);
      if (String(request.url).includes('/api/')) {
        return jsonResponse({ ok: false, error: 'Internal error: ' + msg }, 500);
      }
      return new Response('Internal error', { status: 500 });
    }
  },
};

// NOTE: `ctx` MUST stay in the signature and stay threaded from fetch() — the
// device-route publishDeviceFile calls below use `ctx?.waitUntil`, and optional
// chaining does NOT guard an undeclared identifier: without this parameter the
// moment any of those routes ran (device register/redeem, admin grant/drop VIP,
// extend, revoke) the Worker threw "ctx is not defined" → 500.
async function handle(request, env, ctx) {
  const url = new URL(request.url);
  const path = url.pathname;
  const method = request.method.toUpperCase();

  if (path === '/privacy' || path === '/privacy.html') {
    return htmlResponse(PRIVACY_HTML);
  }
  if (path === '/terms' || path === '/terms.html') {
    return htmlResponse(TERMS_HTML);
  }
  if (!path.startsWith('/api/')) return serveAssets(env, request);
  if (method === 'OPTIONS') return new Response(null, { status: 204 });

  // ---- Public endpoints -------------------------------------------------

  if (path === '/api/health') {
    return jsonResponse({ ok: true, time: new Date().toISOString() });
  }

  // SPA boot: is there already a valid session cookie?
  if (path === '/api/session' && method === 'GET') {
    let auth;
    try {
      auth = await authenticate(request, env);
    } catch (e) {
      return jsonResponse({ authenticated: false, configured: false, error: String(e.message || e) }, 503);
    }
    if (!auth.valid) return noStore(jsonResponse({ authenticated: false }));
    return noStore(
      jsonResponse({
        authenticated: true,
        username: auth.username,
        role: auth.role,
        csrf: auth.csrf,
        exp: auth.exp,
      }),
    );
  }

  if (path === '/api/login' && method === 'POST') {
    return login(request, env);
  }

  // Encrypted fallback bundle for the app when the custom domain fails.
  if (path === '/api/configs.enc' && method === 'GET') {
    const active = await loadActiveConfigs(env);
    const enc = await encryptBundle(JSON.stringify(active), env);
    return cors(new Response(enc, { headers: { 'Content-Type': 'text/plain; charset=utf-8' } }));
  }

  // Server-side VIP endpoint vault. The app calls this (public, unauthenticated)
  // after a rewarded-ad unlock, presenting the native `sensei:vip:` ticket it
  // holds for `id`. The Worker verifies the ticket against the cert-bound key,
  // then returns the endpoint wrapped in the normal config envelope — so the
  // response is ciphertext that only the signed app can decrypt via
  // nativeDecrypt, and only an unlocked build gets a body at all. The vault id
  // is the config id; the real address/port never live in the public bundle.
  if (path === '/api/vip/resolve' && method === 'GET') {
    return resolveVipEndpoint(request, env);
  }

  // ---- BDIX device trial system (public, unauthenticated) ----------------
  // The app registers its stable hardware id and polls its trial status
  // before connecting to a BDIX server. Registration is idempotent and the
  // 1-day trial auto-starts on first sight; the device id survives an app
  // delete + reinstall, so a reinstall cannot farm a fresh trial.

  if (path === '/api/device/register' && method === 'POST') {
    let body;
    try {
      body = await readJson(request);
    } catch (e) {
      return cors(jsonResponse({ ok: false, error: String(e.message || e) }, 400));
    }
    // The connecting IP (CF-Connecting-IP) rides along for anti-farming: the
    // panel clusters devices registered from one IP so a farmer burning
    // device ids (factory reset loop) is visible, and the auto-trial is
    // capped per IP (see registerDevice).
    body.ip = (request.headers.get('cf-connecting-ip') || '').trim();
    const res = await registerDevice(body.deviceId, env, body);
    // Publish the status file on EVERY register — the app only calls this
    // endpoint when the CDN copy is missing, so this is effectively
    // "publish when missing" and self-heals devices that registered before
    // the publish feature existed.
    if (res.ok) ctx?.waitUntil(publishDeviceFile(env, body.deviceId));
    return cors(noStore(jsonResponse(res, res.ok ? 200 : 400)));
  }

  if (path === '/api/device/status' && method === 'GET') {
    const url = new URL(request.url);
    const id = (url.searchParams.get('deviceId') || '').trim();
    const meta = {
      appVersion: url.searchParams.get('appVersion') || '',
      platform: url.searchParams.get('platform') || '',
      ip: (request.headers.get('cf-connecting-ip') || '').trim(),
    };
    const res = await deviceStatusById(id, env, meta);
    return cors(noStore(jsonResponse(res, res.ok ? 200 : 400)));
  }

  if (path === '/api/device/connect' && method === 'POST') {
    let body;
    try {
      body = await readJson(request);
    } catch (e) {
      return cors(jsonResponse({ ok: false, error: String(e.message || e) }, 400));
    }
    const res = await recordConnect(body.deviceId, env);
    return cors(noStore(jsonResponse(res, res.ok ? 200 : 400)));
  }

  if (path === '/api/device/redeem' && method === 'POST') {
    let body;
    try {
      body = await readJson(request);
    } catch (e) {
      return cors(jsonResponse({ ok: false, error: String(e.message || e) }, 400));
    }
    const res = await redeemKey(body.deviceId, body.key, env);
    if (res.ok) ctx?.waitUntil(publishDeviceFile(env, body.deviceId));
    return cors(noStore(jsonResponse(res, res.ok ? 200 : 400)));
  }

  // Public bootstrap: what exists, where it lives, encryption mode.
  if (path === '/api/backend' && method === 'GET') {
    return publicBackendInfo(env, request);
  }

  // ---- Everything below needs a session (+ CSRF on mutations) -----------

  let auth;
  try {
    auth = await authenticate(request, env);
  } catch (e) {
    return jsonResponse({ ok: false, error: String(e.message || e), needSetup: true }, 503);
  }
  if (!auth.valid) {
    return noStore(
      jsonResponse({ ok: false, error: 'Unauthorized (' + auth.reason + ')' }, 401),
    );
  }

  // Logout sits INSIDE the auth gate (authenticate() enforces the CSRF
  // double-submit on POST): the old pre-gate handler let any page fire a
  // cookie-less POST and terminate the admin's session at will — a cheap
  // deny-service of the panel UI.
  if (path === '/api/logout' && method === 'POST') {
    const res = jsonResponse({ ok: true });
    for (const c of clearedCookies(request)) res.headers.append('Set-Cookie', c);
    return noStore(res);
  }

  switch (`${method} ${path}`) {
    case 'GET /api/bootstrap':
      return bootstrap(auth, env);
    case 'GET /api/configs':
      return jsonResponse({ ok: true, configs: await loadConfigs(env) });
    case 'GET /api/servers':
      return jsonResponse({ ok: true, servers: await loadServers(env) });
    case 'POST /api/servers':
      return createServer(auth, env, await readJson(request));
    case 'GET /api/categories':
      return jsonResponse({ ok: true, categories: await loadCategories(env) });
    case 'POST /api/categories':
      return createCategory(auth, env, await readJson(request));
    case 'GET /api/types':
      return jsonResponse({ ok: true, types: await loadCapabilityTypes(env) });
    case 'POST /api/types':
      return createCapabilityType(auth, env, await readJson(request));
    case 'DELETE /api/configs': {
      const denied = requireDev(auth);
      if (denied) return denied;
      return deleteAllConfigs(auth, env);
    }
    case 'POST /api/configs':
      return createConfig(auth, env, await readJson(request));
    case 'POST /api/bulk-upload':
      return bulkUpload(auth, env, await readJson(request));
    case 'POST /api/validate':
      return dryRunValidate(env, await readJson(request));
    case 'POST /api/import-subscription':
      return importSubscription(auth, env, await readJson(request));
    case 'POST /api/sub-info':
      return subscriptionInfo(await readJson(request));
    case 'POST /api/upload-image':
      return uploadImage(auth, env, await readJson(request));
    case 'GET /api/images':
      return jsonResponse({ ok: true, images: await loadImages(env) });
    case 'POST /api/images/forget':
      return forgetImage(auth, env, await readJson(request));
    case 'POST /api/publish':
      return publishNow(auth, env);
    case 'POST /api/verify':
      return verifyPublished(auth, env);
    case 'GET /api/export':
      return exportConfigs(env);
    case 'GET /api/backup':
      return downloadBackup(env);
    case 'POST /api/backup': {
      const denied = requireDev(auth);
      if (denied) return denied;
      return restoreBackup(auth, env, await readJson(request));
    }
    case 'POST /api/backup/restore-github': {
      const denied = requireDev(auth);
      if (denied) return denied;
      return restoreBackupFromGithub(auth, env);
    }
    case 'GET /api/settings':
      return jsonResponse({ ok: true, settings: await loadSettings(env) });
    case 'POST /api/settings':
      return saveSettings(auth, env, await readJson(request));
    case 'GET /api/logs': {
      const allLogs = await loadLogs(env);
      const logs = isDev(auth.role) ? allLogs : allLogs.filter((l) => !l._devOnly);
      return jsonResponse({ ok: true, logs });
    }
    case 'DELETE /api/logs':
      await env.SENSEI_KV.put('activity_logs', '[]');
      return jsonResponse({ ok: true });
    case 'GET /api/admins':
      return listAdmins(env);
    case 'POST /api/admins': {
      const denied = requireDev(auth);
      if (denied) return denied;
      return addAdmin(auth, env, await readJson(request));
    }
    case 'PUT /api/account/password':
      return changeOwnPassword(auth, env, await readJson(request));
    // ---- BDIX device trial admin ------------------------------------------
    case 'GET /api/devices': {
      const devices = await loadDevices(env);
      const keys = await loadKeys(env);
      const now = Date.now();
      // Per-IP device clusters — the trial-farming signal. Devices registered
      // from the same IP (CGNAT households count 2-3; a factory-reset loop
      // counts 10+) are flagged so the admin can spot and ban a farmer.
      const ipCounts = new Map();
      for (const rec of Object.values(devices)) {
        const ip = (rec?.regIp || '').trim();
        if (ip) ipCounts.set(ip, (ipCounts.get(ip) || 0) + 1);
      }
      const list = Object.entries(devices)
        .filter(([, rec]) => rec?.deleted !== true)
        .map(([id, rec]) => ({
          id,
          ...deviceStatus(rec, now),
          note: rec.note || '',
          ipCount: rec?.regIp ? ipCounts.get(rec.regIp) || 1 : 1,
        }))
        .sort((a, b) => (b.lastSeen || 0) - (a.lastSeen || 0));
      return jsonResponse({ ok: true, devices: list, keys });
    }
    case 'POST /api/devices/extend': {
      const body = await readJson(request);
      const res = await extendDevice(body.deviceId, body.days, env);
      if (res.ok) ctx?.waitUntil(publishDeviceFile(env, body.deviceId));
      return jsonResponse(res, res.ok ? 200 : 400);
    }
    case 'POST /api/devices/revoke': {
      const body = await readJson(request);
      const res = await revokeDevice(body.deviceId, env);
      if (res.ok) ctx?.waitUntil(publishDeviceFile(env, body.deviceId));
      return jsonResponse(res, res.ok ? 200 : 400);
    }
    case 'POST /api/devices/connect': {
      const body = await readJson(request);
      const res = await recordConnect(body.deviceId, env);
      return jsonResponse(res, res.ok ? 200 : 400);
    }
    case 'POST /api/devices/add': {
      const denied = requireDev(auth);
      if (denied) return denied;
      const body = await readJson(request);
      const res = await addDevice(body.deviceId, body, env);
      if (res.ok) ctx?.waitUntil(publishDeviceFile(env, body.deviceId));
      return jsonResponse(res, res.ok ? 201 : 400);
    }
    case 'POST /api/devices/vip': {
      const denied = requireDev(auth);
      if (denied) return denied;
      const body = await readJson(request);
      const res = await grantVip(body.deviceId, env);
      if (res.ok) ctx?.waitUntil(publishDeviceFile(env, body.deviceId));
      return jsonResponse(res, res.ok ? 200 : 400);
    }
    case 'POST /api/devices/unvip': {
      const denied = requireDev(auth);
      if (denied) return denied;
      const body = await readJson(request);
      const res = await ungrantVip(body.deviceId, env);
      if (res.ok) ctx?.waitUntil(publishDeviceFile(env, body.deviceId));
      return jsonResponse(res, res.ok ? 200 : 400);
    }
    case 'GET /api/devices/lookup': {
      const denied = requireDev(auth);
      if (denied) return denied;
      const id = (new URL(request.url).searchParams.get('deviceId') || '').trim();
      const res = await lookupDevice(id, env);
      return jsonResponse(res, res.ok ? 200 : 400);
    }
    case 'PUT /api/devices': {
      const denied = requireDev(auth);
      if (denied) return denied;
      const body = await readJson(request);
      const res = await updateDevice(body.deviceId, body, env);
      return jsonResponse(res, res.ok ? 200 : 400);
    }
    case 'DELETE /api/devices': {
      const denied = requireDev(auth);
      if (denied) return denied;
      const body = await readJson(request);
      const res = await deleteUser(body.deviceId, env);
      if (res.ok) ctx?.waitUntil(publishDeviceFile(env, body.deviceId));
      return jsonResponse(res, res.ok ? 200 : 400);
    }
    case 'POST /api/keys': {
      const denied = requireDev(auth);
      if (denied) return denied;
      const body = await readJson(request);
      const res = await createKey(body.days, body.deviceId, env);
      return jsonResponse(res, res.ok ? 201 : 400);
    }
    default:
      break;
  }

  // POST /api/backend doubles as "save branding" (admin) — distinct from the
  // public GET above.
  if (path === '/api/backend' && method === 'POST') {
    return saveBranding(auth, env, await readJson(request));
  }

  if (path.startsWith('/api/configs/')) {
    const id = decodeURIComponent(path.slice('/api/configs/'.length));
    if (method === 'GET') return getConfig(env, id);
    if (method === 'PUT') return updateConfig(auth, env, id, await readJson(request));
    if (method === 'PATCH') return patchConfig(auth, env, id, await readJson(request));
    if (method === 'DELETE') return deleteConfig(auth, env, id);
  }
  if (path.startsWith('/api/servers/')) {
    const id = decodeURIComponent(path.slice('/api/servers/'.length));
    if (method === 'PUT') return updateServer(auth, env, id, await readJson(request));
    if (method === 'DELETE') return deleteServer(auth, env, id);
  }
  if (path.startsWith('/api/types/')) {
    const id = decodeURIComponent(path.slice('/api/types/'.length));
    if (method === 'PUT') return updateCapabilityType(auth, env, id, await readJson(request));
    if (method === 'DELETE') return deleteCapabilityType(auth, env, id);
  }
  if (path.startsWith('/api/categories/')) {
    const id = decodeURIComponent(path.slice('/api/categories/'.length));
    if (method === 'PUT') return updateCategory(auth, env, id, await readJson(request));
    if (method === 'DELETE') return deleteCategory(auth, env, id);
  }
  if (path.startsWith('/api/admins/') && method === 'DELETE') {
    const denied = requireDev(auth);
    if (denied) return denied;
    const username = decodeURIComponent(path.slice('/api/admins/'.length));
    return removeAdmin(auth, env, username);
  }

  return jsonResponse({ ok: false, error: `No route: ${method} ${path}` }, 404);
}

// ---------------------------------------------------------------------------
// Auth endpoints
// ---------------------------------------------------------------------------

async function login(request, env) {
  if (!env.JWT_SECRET) {
    return jsonResponse({ ok: false, error: 'JWT_SECRET is not configured' }, 503);
  }
  const ip = clientIp(request);
  const rate = await checkLoginRate(env, ip);
  if (!rate.allowed) {
    return jsonResponse(
      { ok: false, error: `Too many failed attempts. Try again in ${Math.ceil(rate.retryAfter / 60)} min.` },
      429,
      { 'Retry-After': String(rate.retryAfter) },
    );
  }

  const body = await readJson(request);
  const username = String(body.username || '').trim();
  const password = String(body.password || '');

  let user = null;
  let role = 'admin';

  // 1. Dev accounts (hardcoded, highest priority).
  const devMatch = devAccounts(env).find((d) => d.username === username);
  if (devMatch && timingSafeEqual(password, devMatch.password)) {
    user = username;
    role = 'dev';
  }

  // 2. Primary admin — a KV-stored hash set via the panel's "change my
  //    password" action supersedes the ADMIN_PASSWORD secret (the UI cannot
  //    write secrets, so the rotated password lives in KV, PBKDF2-hashed
  //    exactly like extra admins).
  if (!user && username === (env.ADMIN_USER || 'admin')) {
    const override = await env.SENSEI_KV.get('primary_password_hash');
    if (override && (await verifyPassword(password, override)).ok) {
      user = username;
    } else if (env.ADMIN_PASSWORD && timingSafeEqual(password, env.ADMIN_PASSWORD)) {
      user = username;
    }
  }

  // 3. KV-stored admins.
  if (!user) {
    const admins = (await env.SENSEI_KV.get('admins', 'json')) || [];
    const match = admins.find((a) => a.username === username && a.passwordHash);
    if (match) {
      const res = await verifyPassword(password, match.passwordHash);
      if (res.ok) {
        user = username;
        if (res.legacy) {
          // Transparently migrate legacy SHA-256 entries to PBKDF2.
          match.passwordHash = await hashPassword(password);
          await env.SENSEI_KV.put('admins', JSON.stringify(admins));
        }
      }
    }
  }

  if (!user) {
    await recordLoginFailure(env, ip);
    // Uniform response: do not reveal whether the username exists.
    return jsonResponse({ ok: false, error: 'Invalid credentials' }, 401);
  }

  await clearLoginFailures(env, ip);
  const session = await issueSession(request, env, user, role);
  await saveLog(env, {
    action: `${role === 'dev' ? `[Dev "${user}"]` : `[Admin "${user}"]`} signed in`,
    type: 'settings',
    status: 'info',
    _devOnly: role === 'dev',
  });
  return noStore(withSetCookies(new Response(
    JSON.stringify({ ok: true, user, role, csrf: session.csrf }),
    {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    },
  ), session.cookies));
}

/** Multiple Set-Cookie values must be appended individually, not joined. */
function withSetCookies(res, cookies) {
  for (const c of cookies) res.headers.append('Set-Cookie', c);
  return res;
}

// ---------------------------------------------------------------------------
// Bootstrap — one round trip for the whole SPA
// ---------------------------------------------------------------------------

async function bootstrap(auth, env) {
  // Lazy migration: seeds default capability types and back-fills
  // capabilities/families from legacy serverId tweaks on first contact.
  const types = await loadCapabilityTypes(env, { migrate: true });
  const [configs, servers, categories, settings, backend, allLogs, lastPublish] = await Promise.all([
    loadConfigs(env),
    loadServers(env),
    loadCategories(env),
    loadSettings(env),
    loadBackendMeta(env),
    loadLogs(env),
    env.SENSEI_KV.get('last_publish', 'json'),
  ]);
  const stats = computeStats(configs);
  // Admins cannot see Dev login times or admin-management logs.
  const logs = isDev(auth.role) ? allLogs : allLogs.filter((l) => !l._devOnly);
  return noStore(
    jsonResponse({
      ok: true,
      me: auth.username,
      role: auth.role,
      csrf: auth.csrf,
      repo: repoInfoForUi(env),
      crypto: {
        version: bundleVersion(env),
        certBound: !!certHash(env),
        certSha256: certHash(env) ? mask(certHash(env)) : '',
      },
      github: { configured: githubConfigured(env) },
      configs,
      servers,
      categories,
      types,
      settings,
      backend,
      logs,
      lastPublish,
      stats,
    }),
  );
}

function mask(hash) {
  return hash.slice(0, 8) + '…' + hash.slice(-8);
}

export function repoInfoForUi(env) {
  const r = repoInfo(env);
  return { ...r, configFileUrl: rawUrlFor(env, r.configFile), settingsFileUrl: rawUrlFor(env, r.settingsFile) };
}

// ---------------------------------------------------------------------------
// Configs CRUD
// ---------------------------------------------------------------------------

function loadConfigs(env) {
  return env.SENSEI_KV.get('configs', 'json').then((v) => v || []);
}

function loadServers(env) {
  return env.SENSEI_KV.get('servers', 'json').then((v) => v || []);
}

// ---------------------------------------------------------------------------
// BDIX device trial system (key + device-id)
//
// A device is identified by the app's stable hardware hash (ANDROID_ID +
// build fingerprint + install cert — see ShareEnvelope.deviceHwid), which
// survives an app delete + reinstall, so a trial cannot be farmed by
// reinstalling. The FIRST time a device registers it gets a 1-day trial
// automatically; after that the admin extends the expiry from the panel (the
// "purchase") or the user redeems an admin-issued license key.
//
// KV layout:
//   devices  → { [deviceId]: {firstSeen, lastSeen, expiresAt, trial, extended, revoked, revokedAt, deleted, regIp, note, redeemedKeys[], appVersion, platform, connectCount, lastConnected} }
//   keys     → [ {key, days, deviceId?, created, redeemedBy, redeemedAt} ]
// ---------------------------------------------------------------------------

const TRIAL_DAYS = 1;

function loadDevices(env) {
  return env.SENSEI_KV.get('devices', 'json').then((v) => v || {});
}

function saveDevices(env, devices) {
  return env.SENSEI_KV.put('devices', JSON.stringify(devices));
}

function loadKeys(env) {
  return env.SENSEI_KV.get('keys', 'json').then((v) => v || []);
}

function saveKeys(env, keys) {
  return env.SENSEI_KV.put('keys', JSON.stringify(keys));
}

/** The PUBLIC per-device status file published to the configs repo
 *  (served under your CONFIG_RAW_BASE). The app reads
 *  its trial status from this CDN copy instead of hammering the Worker — the
 *  free tier's KV WRITE limit (1000/day) and Worker requests both stay safe.
 *  Only pseudonymous display fields ride it: regIp, the admin note, connect
 *  counts and lastSeen are private KV data and must NEVER be published. */
function devicePublicFile(rec, id, now) {
  const s = deviceStatus(rec, now);
  return JSON.stringify({
    deviceId: id,
    active: s.active,
    expiresAt: s.expiresAt,
    daysLeft: s.daysLeft,
    vip: s.vip,
    trial: s.trial,
    revoked: s.revoked,
    deviceKey: s.deviceKey,
    appVersion: s.appVersion,
    platform: s.platform,
    updatedAt: now,
  });
}

/** Publish one device's status file to the configs repo. Best-effort: the KV
 *  record is the source of truth, a failed publish only means the CDN copy
 *  stays stale until the next mutation (the app falls back to the Worker). */
async function publishDeviceFile(env, deviceId) {
  try {
    const id = normalizeDeviceId(deviceId);
    if (!id) return { ok: false, error: 'deviceId is required' };
    const devices = await loadDevices(env);
    const rec = devices[id];
    if (!rec) return { ok: false, error: 'unknown device' };
    const file = `${id}.json`;
    const res = await putFile(
      env,
      file,
      devicePublicFile(rec, id, Date.now()),
      `chore(devices): status update ${id}`,
    );
    if (!res.ok) console.log(`device file publish failed for ${id}: ${res.error}`);
    return res;
  } catch (e) {
    console.log(`device file publish threw for ${deviceId}: ${String((e && e.message) || e)}`);
    return { ok: false, error: String((e && e.message) || e) };
  }
}

/** Normalize a device id to a safe KV key / display token. */
function normalizeDeviceId(v) {
  return String(v || '').trim().toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 64);
}

/** Generate a unique device key (shown in the panel AND on the device). */
function generateDeviceKey() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const buf = new Uint8Array(8);
  crypto.getRandomValues(buf);
  return 'SENSEI-' + Array.from(buf).map((b) => alphabet[b % alphabet.length]).join('');
}

/** Trial status for a device. `active` = may connect to BDIX servers now.
 *  Revoked devices are inactive but keep their record (reactivatable). */
function deviceStatus(rec, now) {
  const expiresAt = rec?.expiresAt || 0;
  const revoked = rec?.revoked === true;
  const vip = rec?.vip === true;
  // VIP = permanent access (no expiry). A VIP device stays active even though
  // its expiresAt is 0 — omitting vip from `active` made every granted device
  // read as Expired and locked it out of BDIX entirely.
  const active = !revoked && (vip || expiresAt > now);
  const daysLeft = active && !vip ? Math.max(0, Math.ceil((expiresAt - now) / 86400000)) : 0;
  return {
    active,
    expiresAt,
    daysLeft,
    revoked,
    revokedAt: rec?.revokedAt || 0,
    vip,
    trial: rec?.trial === true,
    extended: rec?.extended === true,
    firstSeen: rec?.firstSeen || 0,
    lastSeen: rec?.lastSeen || 0,
    redeemedKeys: rec?.redeemedKeys || [],
    deviceKey: rec?.deviceKey || '',
    appVersion: rec?.appVersion || '',
    platform: rec?.platform || '',
    connectCount: rec?.connectCount || 0,
    lastConnected: rec?.lastConnected || 0,
    regIp: rec?.regIp || '',
    note: rec?.note || '',
  };
}

/** Register (or re-register) a device. First sight auto-starts the 1-day
 *  trial; returning devices keep their existing state. Idempotent — a
 *  reinstall or clear-data finds the existing record and does NOT get a
 *  fresh trial.
 *
 *  Anti-farming: a device id survives reinstall, but a factory reset mints a
 *  new one. So the auto-trial is capped per registration IP — once
 *  TRIAL_IP_LIMIT distinct devices have registered from one IP inside 24 h,
 *  new devices from that IP are still registered (so the admin SEES them in
 *  the Users list, clustered by ipCount) but WITHOUT the auto-trial; BDIX
 *  stays gated until the admin extends or grants VIP. The limit is far above
 *  any real shared-NAT household. */
const TRIAL_IP_LIMIT = 20;

async function registerDevice(deviceId, env, meta) {
  const id = normalizeDeviceId(deviceId);
  if (!id) return { ok: false, error: 'deviceId is required' };
  const devices = await loadDevices(env);
  const now = Date.now();
  const regIp = String(meta?.ip || '').slice(0, 64);
  const existing = devices[id];
  if (existing) {
    // Throttle the KV write (free tier = 1000 writes/day): returning devices
    // only persist when the meta actually changed or the last write is 30+
    // minutes old — an app relaunch does not burn a write.
    const metaChanged =
      (meta?.appVersion && existing.appVersion !== String(meta.appVersion)) ||
      (meta?.platform && existing.platform !== String(meta.platform)) ||
      (regIp && existing.regIp !== regIp);
    const stale = now - (existing.lastSeen || 0) > 30 * 60 * 1000;
    if (metaChanged || stale) {
      existing.lastSeen = now;
      if (meta?.appVersion) existing.appVersion = String(meta.appVersion);
      if (meta?.platform) existing.platform = String(meta.platform);
      if (regIp) existing.regIp = regIp;
      await saveDevices(env, devices);
    }
    return { ok: true, status: deviceStatus(existing, now), trialStarted: false };
  }
  const sameIpNew = regIp
    ? Object.values(devices).filter(
        (r) => (r?.regIp || '') === regIp && now - (r?.firstSeen || 0) < 86400000,
      ).length
    : 0;
  const allowTrial = sameIpNew < TRIAL_IP_LIMIT;
  const rec = {
    firstSeen: now,
    lastSeen: now,
    expiresAt: allowTrial ? now + TRIAL_DAYS * 86400000 : 0,
    trial: allowTrial,
    extended: false,
    revoked: false,
    note: '',
    redeemedKeys: [],
    deviceKey: generateDeviceKey(),
    appVersion: meta?.appVersion ? String(meta.appVersion) : '',
    platform: meta?.platform ? String(meta.platform) : '',
    connectCount: 0,
    lastConnected: 0,
    regIp,
  };
  devices[id] = rec;
  await saveDevices(env, devices);
  return { ok: true, status: deviceStatus(rec, now), trialStarted: allowTrial };
}

/** Fetch a device's trial status (public; the app polls this before BDIX). */
async function deviceStatusById(deviceId, env, meta) {
  const id = normalizeDeviceId(deviceId);
  if (!id) return { ok: false, error: 'deviceId is required' };
  const devices = await loadDevices(env);
  const rec = devices[id];
  if (!rec) return { ok: true, status: deviceStatus(null, Date.now()), registered: false };
  // Refresh mutable meta on every poll (app version, platform, reg ip) — but
  // throttle the KV write (free tier = 1000 writes/day): persist only when
  // the meta changed or the last write is 30+ minutes old.
  const metaChanged =
    (meta?.appVersion && rec.appVersion !== String(meta.appVersion)) ||
    (meta?.platform && rec.platform !== String(meta.platform)) ||
    (meta?.ip && rec.regIp !== String(meta.ip).slice(0, 64));
  const now2 = Date.now();
  if (metaChanged || now2 - (rec.lastSeen || 0) > 30 * 60 * 1000) {
    if (meta?.appVersion) rec.appVersion = String(meta.appVersion);
    if (meta?.platform) rec.platform = String(meta.platform);
    if (meta?.ip) rec.regIp = String(meta.ip).slice(0, 64);
    rec.lastSeen = now2;
    await saveDevices(env, devices);
  }
  return { ok: true, status: deviceStatus(rec, now2), registered: true };
}

/** Record a connection attempt (the app pings this on every connect). */
async function recordConnect(deviceId, env) {
  const id = normalizeDeviceId(deviceId);
  if (!id) return { ok: false, error: 'deviceId is required' };
  const devices = await loadDevices(env);
  const rec = devices[id];
  if (!rec) return { ok: false, error: 'unknown device' };
  // Dedupe rapid reconnect loops — a connect flood must not burn KV writes.
  const now = Date.now();
  if (now - (rec.lastConnected || 0) < 60 * 1000) return { ok: true, deduped: true };
  rec.connectCount = (rec.connectCount || 0) + 1;
  rec.lastConnected = now;
  await saveDevices(env, devices);
  return { ok: true };
}

/** Admin: update a device's note / meta. */
async function updateDevice(deviceId, fields, env) {
  const id = normalizeDeviceId(deviceId);
  if (!id) return { ok: false, error: 'deviceId is required' };
  const devices = await loadDevices(env);
  const rec = devices[id];
  if (!rec) return { ok: false, error: 'unknown device' };
  if (fields.note !== undefined) rec.note = String(fields.note).slice(0, 500);
  if (fields.appVersion) rec.appVersion = String(fields.appVersion);
  if (fields.platform) rec.platform = String(fields.platform);
  await saveDevices(env, devices);
  return { ok: true, status: deviceStatus(rec, Date.now()) };
}

/** Admin: delete a user from the Users list. The record is kept as a
 *  `deleted` tombstone (hidden from the list) so the same device can NEVER
 *  re-trial — a hard delete would let the user farm a fresh 1-day trial by
 *  simply asking to be removed and re-registering. */
async function deleteUser(deviceId, env) {
  const id = normalizeDeviceId(deviceId);
  if (!id) return { ok: false, error: 'deviceId is required' };
  const devices = await loadDevices(env);
  const rec = devices[id];
  if (!rec) return { ok: false, error: 'unknown device' };
  rec.revoked = true;
  rec.revokedAt = Date.now();
  rec.deleted = true;
  rec.vip = false;
  rec.trial = false;
  rec.extended = false;
  rec.expiresAt = 0;
  await saveDevices(env, devices);
  return { ok: true, deleted: true };
}

/** Redeem a license key. A key grants its `days` to the presenting device and
 *  is bound to it (one key → one device). Blank-deviceId keys are global. */
async function redeemKey(deviceId, key, env) {
  const id = normalizeDeviceId(deviceId);
  const k = String(key || '').trim().toUpperCase();
  if (!id || !k) return { ok: false, error: 'deviceId and key are required' };
  const keys = await loadKeys(env);
  const rec = keys.find((x) => x.key === k);
  if (!rec) return { ok: false, error: 'unknown key' };
  if (rec.redeemedBy) {
    return { ok: false, error: rec.redeemedBy === id ? 'key already redeemed on this device' : 'key already used on another device' };
  }
  if (rec.deviceId && rec.deviceId !== id) {
    return { ok: false, error: 'key is bound to a different device' };
  }
  const devices = await loadDevices(env);
  const now = Date.now();
  const dev = devices[id] || {
    firstSeen: now, lastSeen: now, expiresAt: 0, trial: false, extended: false, note: '', redeemedKeys: [],
  };
  // Extend from NOW if there is still time left, else from the expiry/now —
  // a key never shortens an active grant.
  const base = Math.max(now, dev.expiresAt || 0);
  dev.expiresAt = base + (rec.days || 1) * 86400000;
  dev.trial = false;
  dev.extended = true;
  dev.redeemedKeys = [...(dev.redeemedKeys || []), k];
  dev.lastSeen = now;
  devices[id] = dev;
  rec.redeemedBy = id;
  rec.redeemedAt = now;
  await saveDevices(env, devices);
  await saveKeys(env, keys);
  return { ok: true, status: deviceStatus(dev, now) };
}

/** Admin: extend a device's access by `days` (adds to the expiry — the
 *  device stays on trial/active, NOT VIP). Use addDevice/grantVip for
 *  permanent access. */
async function extendDevice(deviceId, days, env) {
  const id = normalizeDeviceId(deviceId);
  const d = Math.max(0, Math.min(3650, parseInt(days, 10) || 0));
  if (!id) return { ok: false, error: 'deviceId is required' };
  const devices = await loadDevices(env);
  const rec = devices[id];
  if (!rec) return { ok: false, error: 'unknown device' };
  const now = Date.now();
  const base = Math.max(now, rec.expiresAt || 0);
  rec.expiresAt = base + d * 86400000;
  rec.extended = true;
  // Extending a banned device reactivates it (the admin's unban path).
  rec.revoked = false;
  rec.lastSeen = now;
  await saveDevices(env, devices);
  return { ok: true, status: deviceStatus(rec, now) };
}

/** Admin: grant a device permanent VIP access (no expiry). Also the unban
 *  path for a revoked device. */
async function grantVip(deviceId, env) {
  const id = normalizeDeviceId(deviceId);
  if (!id) return { ok: false, error: 'deviceId is required' };
  const devices = await loadDevices(env);
  const rec = devices[id];
  if (!rec) return { ok: false, error: 'unknown device' };
  rec.vip = true;
  rec.trial = false;
  rec.extended = true;
  rec.revoked = false;
  rec.expiresAt = 0;
  rec.lastSeen = Date.now();
  await saveDevices(env, devices);
  return { ok: true, status: deviceStatus(rec, Date.now()) };
}

/** Admin: revoke the VIP grant WITHOUT banning. The device record survives
 *  (no trial re-award — that was the farming rule), access simply ends:
 *  vip=false + no expiry means `active` goes false, so the app shows the
 *  expired state and the ad/extend paths take over. Re-grant with Grant VIP,
 *  or hand out days with Extend. */
async function ungrantVip(deviceId, env) {
  const id = normalizeDeviceId(deviceId);
  if (!id) return { ok: false, error: 'deviceId is required' };
  const devices = await loadDevices(env);
  const rec = devices[id];
  if (!rec) return { ok: false, error: 'unknown device' };
  rec.vip = false;
  rec.trial = false;
  rec.extended = false;
  rec.expiresAt = 0;
  rec.lastSeen = Date.now();
  await saveDevices(env, devices);
  return { ok: true, status: deviceStatus(rec, Date.now()) };
}

/** True when the device id belongs to an admin-granted, non-banned VIP
 *  account — the "VIP server access" gate the panel controls. Used by
 *  /api/vip/resolve to admit paid devices without a rewarded-ad ticket. */
async function vipDeviceOk(deviceId, env) {
  const id = normalizeDeviceId(deviceId);
  if (!id) return false;
  const rec = (await loadDevices(env))[id];
  return !!rec && rec.vip === true && rec.revoked !== true;
}

/** Admin: add a device permanently (VIP access). The admin types the device id
 *  manually (e.g. the user sends it from the app's My Access screen). */
async function addDevice(deviceId, fields, env) {
  const id = normalizeDeviceId(deviceId);
  if (!id) return { ok: false, error: 'deviceId is required' };
  const devices = await loadDevices(env);
  const now = Date.now();
  const rec = devices[id] || {
    firstSeen: now,
    lastSeen: now,
    expiresAt: 0,
    trial: false,
    extended: true,
    vip: true,
    note: '',
    redeemedKeys: [],
    appVersion: fields?.appVersion ? String(fields.appVersion) : '',
    platform: fields?.platform ? String(fields.platform) : '',
    connectCount: 0,
    lastConnected: 0,
  };
  rec.vip = true;
  rec.trial = false;
  rec.extended = true;
  rec.expiresAt = 0;
  rec.lastSeen = now;
  if (fields?.note !== undefined) rec.note = String(fields.note).slice(0, 500);
  if (fields?.appVersion) rec.appVersion = String(fields.appVersion);
  if (fields?.platform) rec.platform = String(fields.platform);
  devices[id] = rec;
  await saveDevices(env, devices);
  return { ok: true, status: deviceStatus(rec, now) };
}

/** Admin: lookup a device by id — returns its status whether registered or not. */
async function lookupDevice(deviceId, env) {
  const id = normalizeDeviceId(deviceId);
  if (!id) return { ok: false, error: 'deviceId is required' };
  const devices = await loadDevices(env);
  const rec = devices[id];
  if (!rec) return { ok: true, registered: false, status: null };
  return { ok: true, registered: true, status: deviceStatus(rec, Date.now()) };
}

/** Admin: revoke a device — FULL delete (the record is removed, not expired). */
/** Admin: BAN a device. The record is kept as a tombstone — a banned device
 *  re-registering (reinstall, clear-data, factory-reset id churn aside) finds
 *  its existing record and does NOT get a fresh trial. Deleting the record
 *  outright was a farming hole: the next launch auto-started a new 1-day
 *  trial. Reactivate later with Extend or Grant VIP (both clear `revoked`). */
async function revokeDevice(deviceId, env) {
  const id = normalizeDeviceId(deviceId);
  if (!id) return { ok: false, error: 'deviceId is required' };
  const devices = await loadDevices(env);
  const rec = devices[id];
  if (!rec) return { ok: false, error: 'unknown device' };
  rec.revoked = true;
  rec.revokedAt = Date.now();
  rec.vip = false;
  rec.trial = false;
  rec.extended = false;
  rec.expiresAt = 0;
  rec.lastSeen = Date.now();
  await saveDevices(env, devices);
  return { ok: true, revoked: true, status: deviceStatus(rec, Date.now()) };
}

/** Admin: issue a license key. */
async function createKey(days, deviceId, env) {
  const d = Math.max(1, Math.min(3650, parseInt(days, 10) || 7));
  const id = normalizeDeviceId(deviceId);
  const keys = await loadKeys(env);
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const buf = new Uint8Array(8);
  crypto.getRandomValues(buf);
  const key = 'SENSEI-' + Array.from(buf).map((b) => alphabet[b % alphabet.length]).join('');
  keys.push({ key, days: d, deviceId: id, created: Date.now(), redeemedBy: '', redeemedAt: 0 });
  await saveKeys(env, keys);
  return { ok: true, key, days: d, deviceId: id };
}

function loadCategories(env) {
  return env.SENSEI_KV.get('categories', 'json').then((v) => v || []);
}

// ---------------------------------------------------------------------------
// Capability types (Server ↔ Tweak compatibility system) — admin-managed
// ---------------------------------------------------------------------------

/**
 * Load the capability types, seeding the defaults on first run and lazily
 * migrating legacy data: every existing tweak's inferred capability and
 * every server referenced by legacy tweaks gains its capability marker, so
 * old data keeps working under the new Server→Capabilities / Tweak→Type
 * model without any manual re-entry.
 */
async function loadCapabilityTypes(env, { migrate = false } = {}) {
  let types = (await env.SENSEI_KV.get('types', 'json')) || [];
  let seeded = false;
  if (!types.length) {
    types = DEFAULT_CAPABILITY_TYPES.map((name) =>
      normalizeCapabilityType({
        name,
        description: DEFAULT_CAPABILITY_DESCRIPTIONS[name] || 'Built-in type',
      }));
    seeded = true;
  }
  if (migrate) {
    const [servers, configs] = await Promise.all([loadServers(env), loadConfigs(env)]);
    let serversChanged = false;
    const byId = new Map(servers.map((s) => [s.id, s]));
    for (const c of configs) {
      if (!c.serverId) continue;
      const s = byId.get(c.serverId);
      if (!s) continue;
      const cap = String(c.capability || '').toUpperCase() || inferCapability(c);
      // Legacy tweak: give it its capability + family, drop nothing.
      if (!c.capability || !c.family) {
        c.capability = cap;
        c.family = familyOf(String(s.protocol));
        await null; // marker — configs persisted below
      }
      if (!Array.isArray(s.capabilities) || !s.capabilities.map((x) => String(x).toUpperCase()).includes(cap)) {
        s.capabilities = [...(s.capabilities || []), cap];
        serversChanged = true;
      }
      if (!types.some((t) => t.name === cap)) {
        types.push(normalizeCapabilityType({ name: cap, description: 'Migrated from a legacy tweak' }));
        seeded = true;
      }
    }
    if (serversChanged) await env.SENSEI_KV.put('servers', JSON.stringify(servers));
    await env.SENSEI_KV.put('configs', JSON.stringify(configs));
  }
  if (seeded) await env.SENSEI_KV.put('types', JSON.stringify(types));
  return types;
}

async function createCapabilityType(auth, env, body) {
  const type = normalizeCapabilityType(body, { keepId: false });
  const v = validateCapabilityType(type);
  if (!v.ok) return validationError(v);
  const types = await loadCapabilityTypes(env);
  if (types.some((t) => t.name === type.name)) {
    return jsonResponse({ ok: false, error: `Type [${type.name}] already exists.` }, 409);
  }
  types.push(type);
  await env.SENSEI_KV.put('types', JSON.stringify(types));
  await saveLog(env, {
    action: `${logActor(auth)} Created tweak type [${type.name}]`,
    type: 'update',
    status: 'success',
  });
  return jsonResponse({ ok: true, type }, 201);
}

async function updateCapabilityType(auth, env, id, body) {
  const types = await loadCapabilityTypes(env);
  const i = types.findIndex((t) => t.id === id);
  if (i < 0) return jsonResponse({ ok: false, error: 'Type not found' }, 404);
  const prev = types[i];
  const merged = normalizeCapabilityType({ ...prev, ...body, id });
  const v = validateCapabilityType(merged);
  if (!v.ok) return validationError(v);
  if (merged.name !== prev.name &&
      types.some((t, idx) => idx !== i && t.name === merged.name)) {
    return jsonResponse({ ok: false, error: `Type [${merged.name}] already exists.` }, 409);
  }
  const renamed = merged.name !== prev.name;
  types[i] = merged;
  await env.SENSEI_KV.put('types', JSON.stringify(types));
  let pub = null;
  if (renamed) {
    // A rename must follow every server capability + tweak that used it.
    const [servers, configs] = await Promise.all([loadServers(env), loadConfigs(env)]);
    for (const s of servers) {
      s.capabilities = (s.capabilities || []).map((c) => (String(c).toUpperCase() === prev.name ? merged.name : c));
    }
    for (const c of configs) {
      if (String(c.capability || '').toUpperCase() === prev.name) c.capability = merged.name;
    }
    await Promise.all([
      env.SENSEI_KV.put('servers', JSON.stringify(servers)),
      env.SENSEI_KV.put('configs', JSON.stringify(configs)),
    ]);
    pub = await publishBoth(env);
  }
  await saveLog(env, {
    action: `${logActor(auth)} Updated tweak type [${merged.name}]${merged.enabled === false ? ' (disabled)' : ''}`,
    type: 'update',
    status: 'success',
  });
  return publishAware(jsonResponse({ ok: true, type: merged, publish: pub }), pub);
}

async function deleteCapabilityType(auth, env, id) {
  const types = await loadCapabilityTypes(env);
  const i = types.findIndex((t) => t.id === id);
  if (i < 0) return jsonResponse({ ok: false, error: 'Type not found' }, 404);
  const [removed] = types.splice(i, 1);
  // [DIRECT] is the fallback every tweak degrades to — it must exist.
  const direct = types.find((t) => t.name === 'DIRECT');
  if (!direct) types.push(normalizeCapabilityType({ name: 'DIRECT', description: 'Plain connection (fallback)' }));

  const [servers, configs] = await Promise.all([loadServers(env), loadConfigs(env)]);
  // Strip the capability from servers.
  for (const s of servers) {
    s.capabilities = (s.capabilities || []).filter((c) => String(c).toUpperCase() !== removed.name);
  }
  // Migrate tweaks of the deleted type to [DIRECT] so they keep riding
  // plain-connection servers (never orphaned).
  let migrated = 0;
  for (const c of configs) {
    if (String(c.capability || '').toUpperCase() === removed.name) {
      c.capability = 'DIRECT';
      migrated++;
    }
  }
  await Promise.all([
    env.SENSEI_KV.put('types', JSON.stringify(types)),
    env.SENSEI_KV.put('servers', JSON.stringify(servers)),
    env.SENSEI_KV.put('configs', JSON.stringify(configs)),
  ]);
  const pub = await publishBoth(env);
  await saveLog(env, {
    action: `${logActor(auth)} Deleted tweak type [${removed.name}] — ${migrated} tweak(s) moved to [DIRECT]`,
    type: 'update',
    status: pub.ok ? 'success' : 'error',
  });
  return publishAware(
    jsonResponse({ ok: true, migrated, publish: pub }), pub);
}

async function loadActiveConfigs(env) {
  const joined = await loadJoinedActiveConfigs(env);
  return joined.map((c) => toAppConfig(c));
}

/** Active configs, server-joined and payload-expanded, but NOT redacted —
 * the shape the server (not the app) needs, e.g. /api/vip/resolve. */
async function loadJoinedActiveConfigs(env) {
  const [configs, servers, settings] = await Promise.all([
    loadConfigs(env),
    loadServers(env),
    loadSettings(env),
  ]);
  const defs = settings.payloadDefs || {};
  const tweaks = sortForPublish(configs.filter((c) => c.active !== false))
    .map((c) => joinServerIntoConfig(c, servers))
    .map((c) => expandConfigPayloads(c, defs));
  // A PROXY is its own node: every active PROXY-protocol server (socks /
  // http_proxy / psiphon) also publishes standalone, so it reaches the app
  // without anyone having to author a tweak that rides it. Tunnel ENDPOINT
  // servers (ssh/vless/openvpn/…) do NOT publish standalone — they are the
  // anchors tweaks ride; publishing them put a bare server copy into every
  // Configs section and flooded old app versions with nodes they cannot
  // group. Tuned variants (the tweaks) publish separately above and keep
  // their failover pool.
  const proxies = sortForPublish((servers || []).filter((s) => s.active !== false))
    .filter((s) => isProxyNode(s))
    .map((s) => serverToAppConfig(s));
  return [...tweaks, ...proxies];
}

function sortForPublish(configs) {
  return [...configs].sort(
    (a, b) => (b.priority || 0) - (a.priority || 0) || naturalNameCompare(a.name, b.name),
  );
}

// Numeric-aware name compare: plain localeCompare sorted the serial-prefixed
// tweak names 1, 10, 11, 2, 3… (the user saw the serials jump from 1 to 10).
// Numeric collation compares digit runs as numbers — 2 < 10 — and names
// without a leading number keep their locale order.
function naturalNameCompare(a, b) {
  return String(a).localeCompare(String(b), undefined, { numeric: true });
}

/**
 * GET /api/vip/resolve?id=<configId>[&ticket=<sensei:vip:...>]
 *
 * Verifies the presented unlock ticket, then returns the real endpoint for
 * that vaulted VIP config as an encrypted envelope (same scheme as the config
 * bundle). Only fields the client cannot dial without are released; the ticket
 * is bound to this exact configId, so a ticket for one VIP config cannot fetch
 * another. Everything here is response body, never a log line.
 *
 * When the panel's ads gate is OPEN (`adsEnabled !== true` — the pre-Play-Store
 * default), the ticket is OPTIONAL: the rewarded-ad gate cannot run, so a
 * ticket-less request resolves the same envelope — otherwise BDIX/VIP servers
 * would be un-connectable AND un-pingable until the ads turn on. The response
 * is still encrypted (only the signed app decrypts it), so the leak surface is
 * the same as the ticketed path.
 */
async function resolveVipEndpoint(request, env) {
  const url = new URL(request.url);
  const id = (url.searchParams.get('id') || '').trim();
  const ticket = (url.searchParams.get('ticket') || '').trim();
  const device = (url.searchParams.get('device') || '').trim();
  if (!id) {
    return cors(jsonResponse({ ok: false, error: 'id is required' }, 400));
  }

  let verified = null;
  let viaDevice = false;
  if (ticket) {
    verified = await verifyVipTicket(ticket, id, env);
    if (!verified.ok) {
      // An EXPIRED ticket from an admin-granted VIP device still proves the
      // app went through the flow — fall through to the device check instead
      // of hard-403ing a paying user.
      if (!device || !(await vipDeviceOk(device, env))) {
        return cors(noStore(jsonResponse({ ok: false, error: verified.error }, 403)));
      }
      viaDevice = true;
      verified = null;
    }
  } else if (device && (await vipDeviceOk(device, env))) {
    // Admin-granted VIP device: access was PAID for in the panel — never put
    // it behind the rewarded-ad wall. Not a bearer credential (ids are
    // published), but the response stays cert-encrypted: only the signed app
    // can read the endpoint, so a leaked id alone yields nothing.
    viaDevice = true;
  } else {
    // Ticket-less: only allowed while the ads gate is open. A request that
    // arrives after the panel flips adsEnabled=true gets a hard 403.
    const settings = await loadSettings(env);
    if (settings.adsEnabled === true) {
      return cors(noStore(jsonResponse({ ok: false, error: 'ticket required' }, 403)));
    }
  }

  const active = await loadJoinedActiveConfigs(env);
  const cfg = active.find((c) => c.id === id);
  if (!cfg) {
    return cors(noStore(jsonResponse({ ok: false, error: 'unknown vault id' }, 404)));
  }
  if (cfg.vip !== true) {
    // Only VIP endpoints are vault-resolved; a non-VIP id must not be used as
    // a generic "fetch any config's endpoint" oracle.
    return cors(noStore(jsonResponse({ ok: false, error: 'not a vaulted VIP config' }, 403)));
  }

  // This is the raw joined config, so address/port are the real ones (the
  // public bundle redacts them for vaulted VIP via toAppConfig, which also
  // blanks injectHost/injectPort/serverPool — those are endpoints too, so they
  // are released here behind the same verified ticket).
  const endpoint = {
    id: cfg.id,
    address: cfg.address,
    port: cfg.port,
    sni: cfg.sni,
    host: cfg.host,
    path: cfg.path,
    injectHost: cfg.injectHost,
    injectPort: cfg.injectPort,
    serverPool: Array.isArray(cfg.serverPool) ? cfg.serverPool : [],
  };

  // Audit: who resolved a vaulted endpoint, and did it work. Records the
  // config id, the country and the outcome ONLY — never the ticket (it is a
  // bearer credential) and never the endpoint. query is read and then dropped
  // so the ticket cannot reach a log line through a request dump. A
  // ticket-less resolve (ads gate open) logs "gate-open" — verified is null
  // there and dereferencing it would throw.
  await saveLog(env, {
    action: 'vip.resolve',
    detail:
      `${id} (${cfg.country || cfg.region || '?'}) ok — ` +
      (verified
        ? `ticket expires ${new Date(verified.expiresAt).toISOString()}`
        : viaDevice
          ? `vip device ${device.slice(0, 8)}… (no ad)`
          : 'ads gate open (no ticket)'),
  }).catch(() => {});

  const enc = await encryptBundle(JSON.stringify(endpoint), env);
  return cors(noStore(new Response(enc, {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  })));
}

async function persistConfigs(auth, env, configs, logAction) {
  await env.SENSEI_KV.put('configs', JSON.stringify(configs));
  if (logAction) await saveLog(env, logAction);
  // Publish immediately; the result is surfaced to the caller so a failed
  // GitHub push shows up as an error, not as silent staleness.
  const pub = await publishBoth(env);
  return pub;
}

// ---------------------------------------------------------------------------
// Servers CRUD (endpoint + credentials entity)
// ---------------------------------------------------------------------------

async function createServer(auth, env, body) {
  const server = normalizeServer(body, { keepId: false });
  const v = validateServer(server);
  if (!v.ok) return validationError(v);
  const servers = await loadServers(env);
  if (servers.some((s) => s.address === server.address && s.port === server.port && s.name === server.name)) {
    return jsonResponse({ ok: false, error: 'A server with the same name and endpoint already exists.' }, 409);
  }
  servers.push(server);
  await env.SENSEI_KV.put('servers', JSON.stringify(servers));
  // Republish so the encrypted panel backup (sensei_backup.enc) carries the
  // new server AND the app feed picks it up: a proxy is published as its own
  // node now, so it needs no tweak to reach users.
  const pub = await publishBoth(env);
  await saveLog(env, {
    action: `${logActor(auth)} Added server "${server.name}" (${protocolLabel(server.protocol)} ${server.address}:${server.port})`,
    type: 'update',
    status: pub.ok ? 'success' : 'error',
  });
  return publishAware(jsonResponse({ ok: true, server, publish: pub }, 201), pub);
}

async function updateServer(auth, env, id, body) {
  const servers = await loadServers(env);
  const i = servers.findIndex((s) => s.id === id);
  if (i < 0) return jsonResponse({ ok: false, error: 'Server not found' }, 404);
  const merged = normalizeServer({ ...servers[i], ...body, id });
  const v = validateServer(merged);
  if (!v.ok) return validationError(v);
  servers[i] = merged;
  await env.SENSEI_KV.put('servers', JSON.stringify(servers));
  // Server credentials/endpoints feed every published variant — and the proxy
  // itself is a node — so republish on any server edit.
  const pub = await publishBoth(env);
  await saveLog(env, {
    action: pub.ok ? `${logActor(auth)} Updated server "${merged.name}" & republished` : `${logActor(auth)} Updated server "${merged.name}" — publish FAILED`,
    type: 'update',
    status: pub.ok ? 'success' : 'error',
  });
  return publishAware(jsonResponse({ ok: true, server: merged, publish: pub }), pub);
}

async function deleteServer(auth, env, id) {
  const [servers, configs] = await Promise.all([loadServers(env), loadConfigs(env)]);
  const victim = servers.find((s) => s.id === id);
  if (!victim) return jsonResponse({ ok: false, error: 'Server not found' }, 404);
  // A method config has NO endpoint of its own — deleting its server would
  // leave it un-publishable. Refuse until the methods are deleted first.
  const linked = configs.filter((c) => c.serverId === id).length;
  if (linked > 0) {
    return jsonResponse(
      { ok: false, error: `"${victim.name}" still has ${linked} method(s). Delete them first.` },
      409,
    );
  }
  const next = servers.filter((s) => s.id !== id);
  await env.SENSEI_KV.put('servers', JSON.stringify(next));
  const pub = await publishBoth(env);
  await saveLog(env, {
    action: `${logActor(auth)} Deleted server "${victim.name}"`,
    type: 'delete',
    status: pub.ok ? 'success' : 'error',
  });
  return publishAware(jsonResponse({ ok: true, publish: pub }), pub);
}

// ---------------------------------------------------------------------------
// Categories CRUD (Tweaks categories — the app's Configs menu sections)
// ---------------------------------------------------------------------------

async function createCategory(auth, env, body) {
  const category = normalizeCategoryEntity(body, { keepId: false });
  const v = validateCategoryEntity(category);
  if (!v.ok) return validationError(v);
  const categories = await loadCategories(env);
  if (categories.some((c) => String(c.name).toLowerCase() === category.name.toLowerCase())) {
    return jsonResponse({ ok: false, error: `Category "${category.name}" already exists.` }, 409);
  }
  categories.push(category);
  await env.SENSEI_KV.put('categories', JSON.stringify(categories));
  // Categories ride the settings bundle — republish so the app sees the new
  // section (even with zero tweaks in it).
  const pub = await publishBoth(env);
  await saveLog(env, {
    action: `${logActor(auth)} Created category "${category.name}"${category.country ? ` (${category.country})` : ''}`,
    type: 'update',
    status: pub.ok ? 'success' : 'error',
  });
  return publishAware(jsonResponse({ ok: true, category, publish: pub }, 201), pub);
}

async function updateCategory(auth, env, id, body) {
  const [categories, configs] = await Promise.all([loadCategories(env), loadConfigs(env)]);
  const i = categories.findIndex((c) => c.id === id);
  if (i < 0) return jsonResponse({ ok: false, error: 'Category not found' }, 404);
  const prev = categories[i];
  const merged = normalizeCategoryEntity({ ...prev, ...body, id });
  const v = validateCategoryEntity(merged);
  if (!v.ok) return validationError(v);
  const nameChanged = merged.name !== prev.name;
  if (nameChanged &&
      categories.some((c, idx) => idx !== i && String(c.name).toLowerCase() === merged.name.toLowerCase())) {
    return jsonResponse({ ok: false, error: `Category "${merged.name}" already exists.` }, 409);
  }
  categories[i] = merged;
  await env.SENSEI_KV.put('categories', JSON.stringify(categories));
  // A rename must follow its tweaks: configs store the category NAME.
  let migrated = 0;
  if (nameChanged) {
    for (let k = 0; k < configs.length; k++) {
      if (String(configs[k].category || '') === prev.name) {
        configs[k] = { ...configs[k], category: merged.name };
        migrated++;
      }
    }
    if (migrated > 0) await env.SENSEI_KV.put('configs', JSON.stringify(configs));
  }
  const pub = await publishBoth(env);
  await saveLog(env, {
    action: `${logActor(auth)} Updated category "${prev.name}"${nameChanged ? ` → "${merged.name}" (${migrated} tweak(s) moved)` : ''}`,
    type: 'update',
    status: pub.ok ? 'success' : 'error',
  });
  return publishAware(
    jsonResponse({ ok: true, category: merged, migrated, publish: pub }),
    pub,
  );
}

async function deleteCategory(auth, env, id) {
  const [categories, configs] = await Promise.all([loadCategories(env), loadConfigs(env)]);
  const victim = categories.find((c) => c.id === id);
  if (!victim) return jsonResponse({ ok: false, error: 'Category not found' }, 404);
  const linked = configs.filter(
    (c) => String(c.category || '').toLowerCase() === String(victim.name).toLowerCase(),
  ).length;
  if (linked > 0) {
    return jsonResponse(
      { ok: false, error: `"${victim.name}" still has ${linked} tweak(s). Delete or move them first.` },
      409,
    );
  }
  const next = categories.filter((c) => c.id !== id);
  await env.SENSEI_KV.put('categories', JSON.stringify(next));
  const pub = await publishBoth(env);
  await saveLog(env, {
    action: `${logActor(auth)} Deleted category "${victim.name}"`,
    type: 'delete',
    status: pub.ok ? 'success' : 'error',
  });
  return publishAware(jsonResponse({ ok: true, publish: pub }), pub);
}

async function createConfig(auth, env, body) {
  const config = normalizeConfig(body, { keepId: false });
  // Method configs (serverId set) skip endpoint validation — the endpoint
  // comes from their server at publish time.
  const v = (config.serverId || String(config.capability || '').trim()) ? validateVariantConfig(config, await loadServers(env)) : validateConfig(config);
  if (!v.ok) return validationError(v);

  const configs = await loadConfigs(env);
  const key = config.serverId
    ? [config.serverId, config.name, config.injectMode || '', config.payload || '', config.sni || '']
        .join('|')
        .toLowerCase()
    : dedupeKey(config);
  if (configs.some((c) => (c.serverId
    ? [c.serverId, c.name, c.injectMode || '', c.payload || '', c.sni || ''].join('|').toLowerCase()
    : dedupeKey(c)) === key)) {
    return jsonResponse(
      { ok: false, error: 'An identical node (same protocol/address/port/credential) already exists.' },
      409,
    );
  }
  configs.push(config);
  const pub = await persistConfigs(auth, env, configs, {
    action: `${logActor(auth)} Added "${config.name}" (${protocolLabel(config.protocol)})`,
    type: 'update',
    status: 'success',
  });
  return publishAware(jsonResponse({ ok: true, config, publish: pub }, 201), pub);
}

async function updateConfig(auth, env, id, body) {
  const configs = await loadConfigs(env);
  const i = configs.findIndex((c) => c.id === id);
  if (i < 0) return jsonResponse({ ok: false, error: 'Config not found' }, 404);

  // Normalize against the FULL existing object so untouched fields survive —
  // this is what used to silently drop uuid/reality keys/inject payloads.
  const merged = normalizeConfig({ ...configs[i], ...body, id });
  const isVariant = !!merged.serverId || !!String(merged.capability || '').trim();
  const v = isVariant ? validateVariantConfig(merged, await loadServers(env)) : validateConfig(merged);
  if (!v.ok) return validationError(v);

  configs[i] = merged;
  const pub = await persistConfigs(auth, env, configs, {
    action: `${logActor(auth)} Updated "${merged.name}"`,
    type: 'update',
    status: 'success',
  });
  return publishAware(jsonResponse({ ok: true, config: merged, publish: pub }), pub);
}

const PATCHABLE = new Set([
  'active',
  'locked',
  'lockMessage',
  'expiresAt',
  'category',
  'country',
  'priority',
  'note',
  'name',
]);

async function patchConfig(auth, env, id, body) {
  const configs = await loadConfigs(env);
  const i = configs.findIndex((c) => c.id === id);
  if (i < 0) return jsonResponse({ ok: false, error: 'Config not found' }, 404);
  const patch = {};
  for (const k of Object.keys(body || {})) {
    if (PATCHABLE.has(k)) patch[k] = body[k];
  }
  if (!Object.keys(patch).length) {
    return jsonResponse({ ok: false, error: 'Nothing patchable in request' }, 400);
  }
  const merged = normalizeConfig({ ...configs[i], ...patch, id });
  configs[i] = merged;
  const pub = await persistConfigs(auth, env, configs, {
    action: `${logActor(auth)} Toggled/patched "${merged.name}"`,
    type: 'update',
    status: 'success',
  });
  return publishAware(jsonResponse({ ok: true, config: merged, publish: pub }), pub);
}

async function deleteConfig(auth, env, id) {
  const configs = await loadConfigs(env);
  const victim = configs.find((c) => c.id === id);
  if (!victim) return jsonResponse({ ok: false, error: 'Config not found' }, 404);
  const next = configs.filter((c) => c.id !== id);
  const pub = await persistConfigs(auth, env, next, {
    action: `${logActor(auth)} Deleted "${victim.name}"`,
    type: 'delete',
    status: 'success',
  });
  return publishAware(jsonResponse({ ok: true, publish: pub }), pub);
}

async function deleteAllConfigs(auth, env) {
  const pub = await persistConfigs(auth, env, [], {
    action: `${logActor(auth)} Deleted ALL configs`,
    type: 'delete',
    status: 'warning',
  });
  return publishAware(jsonResponse({ ok: true, publish: pub }), pub);
}

async function bulkUpload(auth, env, body) {
  const items = Array.isArray(body && body.configs) ? body.configs : [];
  if (!items.length) return jsonResponse({ ok: false, error: 'configs[] is empty' }, 400);

  const configs = await loadConfigs(env);
  const seen = new Set(configs.map(dedupeKey));
  const added = [];
  const skipped = [];
  const invalid = [];

  for (const raw of items) {
    const config = normalizeConfig(raw, { keepId: false });
    const v = validateConfig(config);
    if (!v.ok) {
      invalid.push({ name: config.name, errors: v.errors.map((e) => `${e.field}: ${e.message}`) });
      continue;
    }
    const key = dedupeKey(config);
    if (seen.has(key)) {
      skipped.push(config.name);
      continue;
    }
    seen.add(key);
    configs.push(config);
    added.push(config.name);
  }

  const pub = added.length ? await persistConfigs(auth, env, configs, {
    action: `${logActor(auth)} Bulk import: ${added.length} added, ${skipped.length} duplicates, ${invalid.length} invalid`,
    type: 'update',
    status: invalid.length ? 'warning' : 'success',
  }) : null;

  return publishAware(
    jsonResponse({ ok: true, added: added.length, names: added, skipped, invalid, publish: pub }, 201),
    pub,
  );
}

/// Dry-run normalize+validate for the editor's live feedback. A body carrying
/// a serverId (a TWEAK) is JOINED with its server first, so the form sees the
/// exact config the app would receive — a broken server credential or an
/// invalid payload surfaces as a real error in the Tweaks editor.
async function dryRunValidate(env, body) {
  const d = body && typeof body === 'object' ? body : {};
  // A tweak joins with its compatible servers when it carries a capability
  // (the new model) OR a legacy serverId — either way the dry-run must
  // validate the JOINED config, never the bare method fields.
  if (d.serverId || String(d.capability || '').trim()) {
    const [servers, categories] = await Promise.all([loadServers(env), loadCategories(env)]);
    const variant = normalizeConfig(d);
    const joined = joinServerIntoConfig(variant, servers);
    // Category display info for the form (flag lives on the category).
    const cat = categories.find(
      (c) => String(c.name).toLowerCase() === String(joined.category || '').toLowerCase(),
    );
    // Mirror the SAVE path exactly: the variant rules (server pool +
    // inject-front gate) AND the joined endpoint/credential checks — the
    // form must show the same errors createConfig/updateConfig would
    // reject with, never a cleaner dry-run than reality.
    const vv = validateVariantConfig(variant, servers);
    const vj = validateConfig(joined);
    const dedupe = (list) => {
      const seen = new Set();
      return list.filter((e) => {
        const k = `${e.field}|${e.message}`;
        if (seen.has(k)) return false;
        seen.add(k);
        return true;
      });
    };
    const errors = dedupe([...vv.errors, ...vj.errors]);
    const warnings = dedupe([...vv.warnings, ...vj.warnings]);
    return jsonResponse({
      ok: true,
      valid: errors.length === 0,
      errors,
      warnings,
      normalized: joined,
      appPayload: toAppConfig(joined),
      shareLink: buildShareLink(joined),
      categoryCountry: cat ? cat.country : '',
    });
  }
  const config = normalizeConfig(d);
  const v = validateConfig(config);
  return jsonResponse({
    ok: true,
    valid: v.ok,
    errors: v.errors,
    warnings: v.warnings,
    normalized: config,
    appPayload: toAppConfig(config),
    shareLink: buildShareLink(config),
  });
}

async function getConfig(env, id) {
  const [configs, servers] = await Promise.all([loadConfigs(env), loadServers(env)]);
  const c = configs.find((x) => x.id === id);
  if (!c) return jsonResponse({ ok: false, error: 'Config not found' }, 404);
  // Share links describe the JOINED node — a method config carries no endpoint.
  return jsonResponse({ ok: true, config: c, shareLink: buildShareLink(joinServerIntoConfig(c, servers)) });
}

// ---------------------------------------------------------------------------
// Subscription / share-text import
// ---------------------------------------------------------------------------

async function importSubscription(auth, env, body) {
  let text = String(body.text || '');
  if (body.url) {
    try {
      const res = await fetch(String(body.url), {
        headers: { 'User-Agent': 'ArmanTunnel-Sub/1.0' },
      });
      if (!res.ok) return jsonResponse({ ok: false, error: `Subscription fetch failed: HTTP ${res.status}` }, 400);
      text = await res.text();
    } catch (e) {
      return jsonResponse({ ok: false, error: 'Subscription fetch error: ' + String(e.message || e) }, 400);
    }
  }
  const links = splitSubscription(text);
  if (!links.length) return jsonResponse({ ok: false, error: 'No vless/vmess/trojan/ss/darktunnel links found' }, 400);

  const configs = body.replace === true ? [] : await loadConfigs(env);
  const seen = new Set(configs.map(dedupeKey));
  const addedNames = [];
  const invalid = [];
  for (const link of links) {
    const config = normalizeConfig(
      {
        ...parseAnyConfigText(link),
        category: body.category,
        country: body.country,
        isOfficial: body.isOfficial !== false,
        author: body.author || undefined,
      },
      { keepId: false },
    );
    const v = validateConfig(config);
    if (!v.ok) {
      invalid.push({ link: link.slice(0, 48), errors: v.errors.map((e) => e.field) });
      continue;
    }
    if (seen.has(dedupeKey(config))) continue;
    seen.add(dedupeKey(config));
    configs.push(config);
    addedNames.push(config.name);
  }
  if (!addedNames.length) {
    return jsonResponse({ ok: false, error: 'Nothing new imported', invalid }, 400);
  }
  const pub = await persistConfigs(auth, env, configs, {
    action: `${logActor(auth)} Imported ${addedNames.length} nodes from ${body.url ? 'subscription URL' : 'pasted links'}`,
    type: 'update',
    status: 'success',
  });
  return publishAware(
    jsonResponse({ ok: true, added: addedNames.length, names: addedNames, invalid, publish: pub }, 201),
    pub,
  );
}

async function subscriptionInfo(body) {
  const url = String(body.url || '');
  if (!url) return jsonResponse({ ok: false, error: 'url required' }, 400);
  try {
    const resp = await fetch(url, { headers: { 'User-Agent': 'ArmanTunnel-Sub/1.0' } });
    const h = resp.headers.get('subscription-userinfo') || resp.headers.get('Subscription-Userinfo');
    if (!h) return jsonResponse({ ok: false, error: 'No Subscription-Userinfo header' }, 400);
    const o = {};
    for (const part of h.split(/[;,]/)) {
      const eq = part.indexOf('=');
      if (eq < 0) continue;
      o[part.slice(0, eq).trim().toLowerCase()] = Number(part.slice(eq + 1).trim()) || 0;
    }
    const GiB = 1073741824;
    const total = o.total || 0;
    const used = (o.upload || 0) + (o.download || 0);
    const expire = (o.expire || 0) > 1e11 ? Math.floor((o.expire || 0) / 1000) : o.expire || 0;
    const nowSec = Math.floor(Date.now() / 1000);
    return jsonResponse({
      ok: true,
      info: {
        usedGB: +(used / GiB).toFixed(2),
        totalGB: total ? +(total / GiB).toFixed(2) : 0,
        percent: total ? +(used / total * 100).toFixed(1) : 0,
        unlimited: total === 0,
        daysLeft: expire ? Math.max(0, Math.round((expire - nowSec) / 86400)) : null,
        expired: expire > 0 && expire < nowSec,
      },
    });
  } catch (e) {
    return jsonResponse({ ok: false, error: String(e.message || e) }, 400);
  }
}

// ---------------------------------------------------------------------------
// Publish + verify
// ---------------------------------------------------------------------------

/**
 * Build + push both encrypted bundles. Returns per-file results; throws only
 * on unexpected internal errors so API callers always get a structured answer.
 */
async function publishBoth(env) {
  if (!githubConfigured(env)) {
    return {
      attempted: false,
      ok: false,
      error: 'GitHub not configured (GITHUB_TOKEN + GITHUB_REPO)',
      files: [],
    };
  }
  const r = repoInfo(env);
  const configs = await loadActiveConfigs(env);
  const settingsBundle = await buildSettingsBundle(env);

  const [configsEnc, settingsEnc] = await Promise.all([
    encryptBundle(JSON.stringify(configs), env),
    encryptBundle(JSON.stringify(settingsBundle), env),
  ]);
  // Off-site backup: the full panel state, encrypted with the same envelope,
  // pushed on every publish. If KV is ever wiped, the Dev can restore the
  // whole panel from this file (POST /api/backup/restore-github).
  const backupEnc = await encryptBundle(JSON.stringify(await buildBackupSnapshot(env)), env);
  const results = await Promise.all([
    putFile(env, r.configFile, configsEnc, `publish ${r.configFile} (${configs.length} nodes)`),
    putFile(env, r.settingsFile, settingsEnc, `publish ${r.settingsFile}`),
    putFile(env, backupFile(), backupEnc, `publish ${backupFile()} (panel backup)`),
  ]);

  const okAll = results.every((x) => x.ok);
  const record = {
    time: new Date().toISOString(),
    ok: okAll,
    files: results,
    nodes: configs.length,
    envelope: bundleVersion(env),
  };
  await env.SENSEI_KV.put('last_publish', JSON.stringify(record));
  await saveLog(env, {
    action: okAll
      ? `Published ${r.configFile} + ${r.settingsFile} + ${backupFile()} (${configs.length} nodes)`
      : `Publish FAILED: ${results.filter((x) => !x.ok).map((x) => x.file + ': ' + x.error).join('; ')}`,
    type: 'encrypt',
    status: okAll ? 'success' : 'error',
  });
  return { ...record, attempted: true };
}

function backupFile() {
  return 'sensei_backup.enc';
}

/** Full panel-state snapshot for backup/restore. Logs are excluded (churn);
 *  everything else the panel needs to rebuild itself is included. */
async function buildBackupSnapshot(env) {
  const [configs, servers, categories, settings, backend, admins, images, types] = await Promise.all([
    loadConfigs(env),
    loadServers(env),
    loadCategories(env),
    loadSettings(env),
    loadBackendMeta(env),
    env.SENSEI_KV.get('admins', 'json'),
    loadImages(env),
    loadCapabilityTypes(env),
  ]);
  return {
    kind: 'sensei-panel-backup',
    version: 1,
    exportedAt: new Date().toISOString(),
    configs: configs || [],
    servers: servers || [],
    categories: categories || [],
    types: types || [],
    settings: settings || null,
    backend: backend || null,
    admins: admins || [],
    images: images || [],
  };
}

/** Dev-only: download the full snapshot as JSON (manual off-site backup). */
async function downloadBackup(env) {
  const snap = await buildBackupSnapshot(env);
  return new Response(JSON.stringify(snap, null, 2), {
    headers: {
      'Content-Type': 'application/json',
      'Content-Disposition': `attachment; filename="arman-backup-${new Date().toISOString().slice(0, 10)}.json"`,
      'Cache-Control': 'no-store',
    },
  });
}

/** Dev-only: restore a snapshot (uploaded JSON or fetched from the repo's
 *  encrypted backup file). Rewrites every KV key and republishes. */
async function restoreBackup(auth, env, body) {
  const snap = body && typeof body === 'object' ? body.snapshot || body : null;
  const err = validateSnapshot(snap);
  if (err) return jsonResponse({ ok: false, error: err }, 400);

  await writeSnapshotToKv(env, snap);
  const pub = await publishBoth(env);
  await saveLog(env, {
    action: `${logActor(auth)} Restored panel backup (${snap.configs.length} configs, ${snap.servers.length} servers, ${snap.categories.length} categories)`,
    type: 'update',
    status: pub.ok ? 'success' : 'error',
  });
  return publishAware(
    jsonResponse({
      ok: true,
      restored: {
        configs: snap.configs.length,
        servers: snap.servers.length,
        categories: snap.categories.length,
      },
      publish: pub,
    }),
    pub,
  );
}

/** Dev-only: pull the encrypted backup file from the configs repo (the one
 *  publishBoth writes on every publish), decrypt it and restore. This is the
 *  recovery path when KV itself was wiped. */
async function restoreBackupFromGithub(auth, env) {
  if (!githubConfigured(env)) {
    return jsonResponse({ ok: false, error: 'GitHub not configured' }, 503);
  }
  const fetchRes = await fetchPublished(env, backupFile());
  if (!fetchRes.ok) {
    return jsonResponse({ ok: false, error: `Backup fetch failed: ${fetchRes.error}` }, 400);
  }
  const dec = await decryptBundle(fetchRes.body, env);
  if (!dec.ok) {
    return jsonResponse({ ok: false, error: `Backup decrypt failed: ${dec.error}` }, 400);
  }
  let snap;
  try {
    snap = JSON.parse(dec.plaintext);
  } catch {
    return jsonResponse({ ok: false, error: 'Backup file is not valid JSON' }, 400);
  }
  const err = validateSnapshot(snap);
  if (err) return jsonResponse({ ok: false, error: err }, 400);
  await writeSnapshotToKv(env, snap);
  const pub = await publishBoth(env);
  await saveLog(env, {
    action: `${logActor(auth)} Restored panel backup from GitHub (${snap.configs.length} configs)`,
    type: 'update',
    status: pub.ok ? 'success' : 'error',
  });
  return publishAware(
    jsonResponse({
      ok: true,
      restored: {
        configs: snap.configs.length,
        servers: snap.servers.length,
        categories: snap.categories.length,
      },
      publish: pub,
    }),
    pub,
  );
}

function validateSnapshot(snap) {
  if (!snap || typeof snap !== 'object') return 'Snapshot object required';
  if (snap.kind !== 'sensei-panel-backup') return 'Not a Sensei panel backup (kind mismatch)';
  if (!Array.isArray(snap.configs)) return 'Snapshot has no configs[] array';
  if (!Array.isArray(snap.servers)) return 'Snapshot has no servers[] array';
  if (!Array.isArray(snap.categories)) return 'Snapshot has no categories[] array';
  return null;
}

async function writeSnapshotToKv(env, snap) {
  await Promise.all([
    env.SENSEI_KV.put('configs', JSON.stringify(snap.configs)),
    env.SENSEI_KV.put('servers', JSON.stringify(snap.servers)),
    env.SENSEI_KV.put('categories', JSON.stringify(snap.categories)),
    Array.isArray(snap.types)
      ? env.SENSEI_KV.put('types', JSON.stringify(snap.types))
      : Promise.resolve(),
    snap.settings ? env.SENSEI_KV.put('settings', JSON.stringify(snap.settings)) : Promise.resolve(),
    snap.backend ? env.SENSEI_KV.put('backend', JSON.stringify(snap.backend)) : Promise.resolve(),
    Array.isArray(snap.admins) && snap.admins.length
      ? env.SENSEI_KV.put('admins', JSON.stringify(snap.admins))
      : Promise.resolve(),
    Array.isArray(snap.images)
      ? env.SENSEI_KV.put('images', JSON.stringify(snap.images))
      : Promise.resolve(),
  ]);
}

async function publishNow(auth, env) {
  void auth;
  const pub = await publishBoth(env);
  return publishAware(jsonResponse({ ok: pub.ok, publish: pub }), pub);
}

/**
 * End-to-end proof: download both published files exactly like the app does
 * (public CDN URL), decrypt with the same key derivation AppSecurity.kt uses,
 * and compare against what KV holds right now.
 */
async function verifyPublished(auth, env) {
  void auth;
  const r = repoInfo(env);
  const expectedNodes = await loadActiveConfigs(env);
  const out = {};

  const cfgFetch = await fetchPublished(env, r.configFile);
  if (!cfgFetch.ok) {
    out.configFile = { file: r.configFile, fetched: false, error: cfgFetch.error };
  } else {
    const dec = await decryptBundle(cfgFetch.body, env);
    if (!dec.ok) {
      out.configFile = { file: r.configFile, fetched: true, decrypted: false, error: dec.error };
    } else {
      let published = [];
      try { published = JSON.parse(dec.plaintext); } catch { /* reported below */ }
      const matches =
        Array.isArray(published) &&
        JSON.stringify(sortById(published)) === JSON.stringify(sortById(expectedNodes));
      out.configFile = {
        file: r.configFile,
        fetched: true,
        decrypted: true,
        url: cfgFetch.url,
        nodes: Array.isArray(published) ? published.length : -1,
        matchesKv: matches,
        error: Array.isArray(published) ? undefined : 'Published file is not a JSON array',
      };
    }
  }

  const setFetch = await fetchPublished(env, r.settingsFile);
  if (!setFetch.ok) {
    out.settingsFile = { file: r.settingsFile, fetched: false, error: setFetch.error };
  } else {
    const dec2 = await decryptBundle(setFetch.body, env);
    out.settingsFile = dec2.ok
      ? { file: r.settingsFile, fetched: true, decrypted: true, url: setFetch.url }
      : { file: r.settingsFile, fetched: true, decrypted: false, error: dec2.error };
  }

  // The backup file only needs to fetch + decrypt (content differs from KV on
  // purpose — it also carries servers/categories/settings).
  const bakFetch = await fetchPublished(env, backupFile());
  if (!bakFetch.ok) {
    out.backupFile = { file: backupFile(), fetched: false, error: bakFetch.error };
  } else {
    const dec3 = await decryptBundle(bakFetch.body, env);
    out.backupFile = dec3.ok
      ? { file: backupFile(), fetched: true, decrypted: true, url: bakFetch.url }
      : { file: backupFile(), fetched: true, decrypted: false, error: dec3.error };
  }

  const ok =
    out.configFile &&
    out.configFile.decrypted &&
    out.configFile.matchesKv !== false &&
    out.settingsFile &&
    out.settingsFile.decrypted &&
    out.backupFile &&
    out.backupFile.decrypted;
  return noStore(jsonResponse({ ok, ...out }));
}

function sortById(arr) {
  return [...arr].sort((a, b) => String(a.id).localeCompare(String(b.id)));
}

// ---------------------------------------------------------------------------
// Settings (app lock / force update / version payload)
// ---------------------------------------------------------------------------

function defaultSettings() {
  return {
    appLocked: false,
    lockedMessage: 'Arman Tunnel is temporarily locked. Please try again later.',
    forceUpdate: false,
    latestVersion: '',
    updateUrl: '',
    updateMessage: 'New Arman Tunnel update available.',
    // Ads are OFF until the Play Store launch (matches the app's
    // AdConfig.adsEnabled). When false, the VIP resolve endpoint allows a
    // ticket-less request — the rewarded-ad gate cannot run, so vaulted
    // configs resolve + connect + ping without one. Flip true when the
    // store listing is ready and the ticket gate returns.
    adsEnabled: false,
    payloadDefs: {},
    vers: null,
    updatedAt: '',
  };
}

function loadSettings(env) {
  return env.SENSEI_KV.get('settings', 'json').then((v) => ({ ...defaultSettings(), ...(v || {}) }));
}

/// Keep only string-string payload entries; drop anything non-string so a
/// malformed body can't poison the token library used at publish time.
function sanitizePayloadDefs(defs) {
  const out = {};
  for (const [k, v] of Object.entries(defs)) {
    if (typeof v === 'string') out[k] = v;
  }
  return out;
}

async function buildSettingsBundle(env) {
  const [settings, backend, categories, types] = await Promise.all([
    loadSettings(env),
    loadBackendMeta(env),
    loadCategories(env),
    loadCapabilityTypes(env),
  ]);
  return {
    api: 2,
    settings,
    backend,
    // Tweaks categories — the app's Configs menu sections, in panel order.
    // Old app builds ignore this key; new builds render one section per
    // category (earth-flag when country is blank).
    categories: (categories || []).map((c) => ({ name: c.name, country: c.country || '' })),
    // Capability types — the Server↔Tweak compatibility markers. The app
    // uses them for the Custom Tweak picker; disabled types are excluded.
    types: (types || [])
      .filter((t) => t.enabled !== false)
      .map((t) => ({ name: t.name, description: t.description || '' })),
    version: settings.vers || null,
    info: backend.info || null,
    updatedAt: new Date().toISOString(),
  };
}

async function saveSettings(auth, env, body) {
  const prev = await loadSettings(env);
  const settings = {
    ...prev,
    appLocked: body.appLocked === true,
    lockedMessage: String(body.lockedMessage ?? prev.lockedMessage ?? ''),
    forceUpdate: body.forceUpdate === true,
    latestVersion: String(body.latestVersion ?? ''),
    updateUrl: String(body.updateUrl ?? ''),
    updateMessage: String(body.updateMessage ?? prev.updateMessage ?? ''),
    vers: body.vers && typeof body.vers === 'object' ? body.vers : prev.vers,
    payloadDefs:
      body.payloadDefs && typeof body.payloadDefs === 'object'
        ? sanitizePayloadDefs(body.payloadDefs)
        : prev.payloadDefs || {},
    updatedAt: new Date().toISOString(),
  };
  await env.SENSEI_KV.put('settings', JSON.stringify(settings));
  const pub = await publishBoth(env);
  await saveLog(env, {
    action: `${logActor(auth)} Saved app controls${settings.appLocked ? ' (app LOCKED)' : ''}${settings.forceUpdate ? ` (force update → ${settings.latestVersion || '?'})` : ''}`,
    type: 'version',
    status: 'success',
  });
  return publishAware(jsonResponse({ ok: true, settings, publish: pub }), pub);
}

// ---------------------------------------------------------------------------
// Backend branding / broadcast payload
// ---------------------------------------------------------------------------

function defaultBackendMeta() {
  return {
    name: 'Arman Tunnel',
    contact: '',
    whatsapp: '',
    description: 'Encrypted config delivery from GitHub.',
    info: null,
    wallpaper: '',
    wallpapers: [],
  };
}

function loadBackendMeta(env) {
  return env.SENSEI_KV.get('backend', 'json').then((v) => {
    const meta = { ...defaultBackendMeta(), ...(v || {}) };
    // Wallpapers are {url,title} entries. Legacy shapes — plain URL strings
    // or the old single `wallpaper` field — migrate in (untitled entries
    // are numbered by the app and the save path below).
    let wallpapers = Array.isArray(meta.wallpapers) ? meta.wallpapers : [];
    wallpapers = wallpapers
      .map((w) =>
        typeof w === 'string'
          ? { url: w.trim(), title: '' }
          : { url: String(w && w.url || '').trim(), title: String(w && w.title || '').trim() },
      )
      .filter((w) => w.url);
    const single = String(meta.wallpaper || '').trim();
    if (single && !wallpapers.some((w) => w.url === single)) {
      wallpapers = [{ url: single, title: '' }, ...wallpapers];
    }
    // Dedup on url, then auto-number untitled entries by position.
    const seen = new Set();
    wallpapers = wallpapers.filter((w) => (seen.has(w.url) ? false : seen.add(w.url)));
    meta.wallpapers = wallpapers.map((w, i) => ({
      url: w.url,
      title: w.title || `Wallpaper ${i + 1}`,
    }));
    // Legacy single field stays = the first url, so OLD app builds (which
    // read backend.wallpaper) keep working.
    meta.wallpaper = meta.wallpapers[0] ? meta.wallpapers[0].url : '';
    return meta;
  });
}

async function saveBranding(auth, env, body) {
  const prev = await loadBackendMeta(env);
  // The wallpaper list: {url,title} entries (plain strings accepted too).
  // Untitled entries are auto-numbered by position; the legacy single
  // `wallpaper` field keeps pointing at the first url for old app builds.
  let wallpapers = prev.wallpapers;
  if (Array.isArray(body.wallpapers)) {
    const seen = new Set();
    wallpapers = [];
    for (const w of body.wallpapers) {
      const url = typeof w === 'string' ? w.trim() : String(w && w.url || '').trim();
      if (!url || seen.has(url)) continue;
      seen.add(url);
      const title = typeof w === 'string' ? '' : String(w && w.title || '').trim().slice(0, 60);
      wallpapers.push({ url, title });
    }
  } else if (body.wallpaper !== undefined) {
    const single = String(body.wallpaper || '').trim();
    wallpapers = single ? [{ url: single, title: '' }] : [];
  }
  wallpapers = wallpapers.map((w, i) => ({
    url: w.url,
    title: w.title || `Wallpaper ${i + 1}`,
  }));
  const meta = {
    ...prev,
    name: String(body.name || '').trim() || defaultBackendMeta().name,
    contact: String(body.contact || '').trim(),
    whatsapp: String(body.whatsapp || '').trim(),
    description: String(body.description || '').trim() || defaultBackendMeta().description,
    info: body.info && typeof body.info === 'object' ? body.info : prev.info,
    wallpaper: wallpapers[0] ? wallpapers[0].url : '',
    wallpapers,
    updatedAt: new Date().toISOString(),
  };
  await env.SENSEI_KV.put('backend', JSON.stringify(meta));
  const pub = await publishBoth(env);
  await saveLog(env, {
    action: `${logActor(auth)} Saved branding/broadcast payload`,
    type: 'broadcast',
    status: 'success',
  });
  return publishAware(jsonResponse({ ok: true, backend: meta, publish: pub }), pub);
}

/**
 * POST /api/upload-image — the panel's image "DB" write path.
 * Body: { dataBase64, filename, contentType } (JSON, no multipart — Workers
 * don't parse multipart natively and the SPA can base64 a File trivially).
 * Uploads to imgbb.com and returns the hosted URL; the caller stores that
 * URL in whatever field it belongs to (server logo, tweak logo, backend
 * wallpaper…). Every successful upload is also recorded in the image
 * library (KV `images`) so forms can re-select it later.
 */
async function uploadImage(auth, env, body) {
  let bytes;
  try {
    bytes = decodeBase64Image(body.dataBase64);
  } catch {
    return jsonResponse({ ok: false, error: 'Invalid base64 image data' }, 400);
  }
  const res = await uploadToImgbb(bytes, String(body.filename || ''), String(body.contentType || ''));
  if (!res.ok || !res.url) {
    return jsonResponse({ ok: false, error: res.error || 'Upload failed' }, 502);
  }
  await saveImageEntry(env, {
    url: res.url,
    filename: String(body.filename || ''),
    time: new Date().toISOString(),
  });
  await saveLog(env, {
    action: `${logActor(auth)} Uploaded image ${String(body.filename || '')} → ${res.url}`,
    type: 'image',
    status: 'success',
  });
  return jsonResponse({ ok: true, url: res.url, deleteUrl: res.deleteUrl || null });
}

// ---------------------------------------------------------------------------
// Image library — the readable half of the image DB
// ---------------------------------------------------------------------------

/** Every imgbb URL ever uploaded through the panel, newest first. */
async function loadImages(env) {
  const v = await env.SENSEI_KV.get('images', 'json');
  return Array.isArray(v) ? v : [];
}

async function saveImageEntry(env, entry) {
  const list = await loadImages(env);
  // Dedup on URL (re-uploads just move to front); cap so KV stays small.
  const next = [entry, ...list.filter((e) => e && e.url !== entry.url)].slice(0, 200);
  await env.SENSEI_KV.put('images', JSON.stringify(next));
}

/** Remove an entry from the library (the imgbb copy itself stays hosted). */
async function forgetImage(auth, env, body) {
  const url = String((body && body.url) || '').trim();
  if (!url) return jsonResponse({ ok: false, error: 'url required' }, 400);
  const list = await loadImages(env);
  const next = list.filter((e) => e && e.url !== url);
  await env.SENSEI_KV.put('images', JSON.stringify(next));
  await saveLog(env, {
    action: `${logActor(auth)} Removed image from library (${url})`,
    type: 'image',
    status: 'success',
  });
  return jsonResponse({ ok: true, images: next });
}

async function publicBackendInfo(env, request) {
  const [configs, settings, meta, lastPublish] = await Promise.all([
    loadConfigs(env),
    loadSettings(env),
    loadBackendMeta(env),
    env.SENSEI_KV.get('last_publish', 'json'),
  ]);
  const r = repoInfo(env);
  const activeCount = configs.filter((c) => c.active !== false).length;
  // Absolute URLs: the APP consumes this endpoint for source discovery, so a
  // relative fallback would be useless to it.
  const origin = new URL(request.url).origin;
  return cors(
    jsonResponse({
      ok: true,
      backend: {
        name: meta.name,
        contact: meta.contact,
        whatsapp: meta.whatsapp,
        description: meta.description,
        // Wallpaper GALLERY only (public imgbb URLs + titles — nothing that
        // isn't already visible in the app once a user opens the sheet). The
        // encrypted bundle stays the primary feed; this endpoint is the
        // fallback for builds that cannot open v3 (debug certs) and for a
        // stale GitHub CDN, so "Admin" wallpapers never look unpublished.
        wallpapers: meta.wallpapers,
        wallpaper: meta.wallpaper,
      },
      configSource: {
        type: 'github-encrypted',
        githubUrl: githubConfigured(env) ? rawUrlFor(env, r.configFile) : null,
        settingsUrl: githubConfigured(env) ? rawUrlFor(env, r.settingsFile) : null,
        fallbackUrl: `${origin}/api/configs.enc`,
        encryption: bundleVersion(env) === 'v3' ? 'v3 (signature-bound)' : 'v2 (shared key)',
        activeConfigs: activeCount,
        updatedAt: lastPublish && lastPublish.time ? lastPublish.time : null,
      },
      appControls: {
        appLocked: settings.appLocked === true,
        lockedMessage: settings.lockedMessage || '',
        forceUpdate: settings.forceUpdate === true,
        latestVersion: settings.latestVersion || '',
        updateUrl: settings.updateUrl || '',
        updateMessage: settings.updateMessage || '',
        updatedAt: settings.updatedAt || '',
      },
      crypto: { version: bundleVersion(env), certBound: !!certHash(env) },
      time: new Date().toISOString(),
    }),
  );
}

// ---------------------------------------------------------------------------
// Admin accounts
// ---------------------------------------------------------------------------

async function listAdmins(env) {
  const admins = ((await env.SENSEI_KV.get('admins', 'json')) || []).map((a) => ({
    username: a.username,
    createdAt: a.createdAt,
  }));
  return jsonResponse({ ok: true, admins, primary: env.ADMIN_USER || 'admin' });
}

async function addAdmin(auth, env, body) {
  const username = String(body.username || '').trim();
  const password = String(body.password || '');
  if (!username || !password) return jsonResponse({ ok: false, error: 'Username and password required' }, 400);
  if (!/^[a-zA-Z0-9_.-]{3,32}$/.test(username)) {
    return jsonResponse({ ok: false, error: 'Username must be 3–32 chars (letters/digits/._-)' }, 400);
  }
  if (password.length < 8) return jsonResponse({ ok: false, error: 'Password must be at least 8 characters' }, 400);
  if (username === (env.ADMIN_USER || 'admin')) {
    return jsonResponse({ ok: false, error: 'That is the primary admin already' }, 400);
  }
  // Dev usernames are reserved.
  if (devAccounts(env).some((d) => d.username === username)) {
    return jsonResponse({ ok: false, error: 'That username is reserved' }, 400);
  }
  const admins = (await env.SENSEI_KV.get('admins', 'json')) || [];
  if (admins.some((a) => a.username === username)) {
    return jsonResponse({ ok: false, error: 'Username already exists' }, 409);
  }
  admins.push({
    username,
    passwordHash: await hashPassword(password),
    createdAt: new Date().toISOString(),
  });
  await env.SENSEI_KV.put('admins', JSON.stringify(admins));
  await saveLog(env, {
    action: `${logActor(auth)} Created admin "${username}"`,
    type: 'settings',
    status: 'success',
    _devOnly: true,
  });
  return jsonResponse({ ok: true, username });
}

async function removeAdmin(auth, env, username) {
  const admins = (await env.SENSEI_KV.get('admins', 'json')) || [];
  const next = admins.filter((a) => a.username !== username);
  if (next.length === admins.length) return jsonResponse({ ok: false, error: 'Admin not found' }, 404);
  await env.SENSEI_KV.put('admins', JSON.stringify(next));
  await saveLog(env, {
    action: `${logActor(auth)} Removed admin "${username}"`,
    type: 'settings',
    status: 'success',
    _devOnly: true,
  });
  return jsonResponse({ ok: true });
}

/**
 * Change the SIGNED-IN account's own password (Settings → Change password).
 * The primary admin's new password is stored as a PBKDF2 hash in KV
 * (`primary_password_hash`) and supersedes the ADMIN_PASSWORD secret at login;
 * extra admins have their KV entry updated in place. Never returns the old
 * password and always verifies it first.
 */
async function changeOwnPassword(auth, env, body) {
  const current = String(body.current || '');
  const next = String(body.next || '');
  if (!next || next.length < 8) {
    return jsonResponse({ ok: false, error: 'New password must be at least 8 characters' }, 400);
  }
  if (timingSafeEqual(current, next)) {
    return jsonResponse({ ok: false, error: 'New password must differ from the current one' }, 400);
  }
  const username = auth.username;
  let okNow = false;
  if (username === (env.ADMIN_USER || 'admin')) {
    const override = await env.SENSEI_KV.get('primary_password_hash');
    if (override) okNow = (await verifyPassword(current, override)).ok;
    if (!okNow && env.ADMIN_PASSWORD) okNow = timingSafeEqual(current, env.ADMIN_PASSWORD);
  } else {
    const admins = (await env.SENSEI_KV.get('admins', 'json')) || [];
    const match = admins.find((a) => a.username === username && a.passwordHash);
    if (match) okNow = (await verifyPassword(current, match.passwordHash)).ok;
  }
  if (!okNow) return jsonResponse({ ok: false, error: 'Current password is incorrect' }, 401);

  if (username === (env.ADMIN_USER || 'admin')) {
    await env.SENSEI_KV.put('primary_password_hash', await hashPassword(next));
  } else {
    const admins = (await env.SENSEI_KV.get('admins', 'json')) || [];
    const match = admins.find((a) => a.username === username);
    if (!match) return jsonResponse({ ok: false, error: 'Admin not found' }, 404);
    match.passwordHash = await hashPassword(next);
    await env.SENSEI_KV.put('admins', JSON.stringify(admins));
  }
  await saveLog(env, {
    action: `${logActor(auth)} Changed own password`,
    type: 'settings',
    status: 'success',
  });
  return jsonResponse({ ok: true });
}

// ---------------------------------------------------------------------------
// Stats / logs / export
// ---------------------------------------------------------------------------

function computeStats(configs) {
  const protocols = {};
  const categories = {};
  const countries = {};
  const now = Date.now();
  for (const c of configs) {
    const p = c.protocol || 'vless';
    const cat = c.category || 'global';
    const co = c.country || '';
    protocols[p] = (protocols[p] || 0) + 1;
    categories[cat] = (categories[cat] || 0) + 1;
    if (co) countries[co] = (countries[co] || 0) + 1;
  }
  return {
    total: configs.length,
    active: configs.filter((c) => c.active !== false).length,
    inactive: configs.filter((c) => c.active === false).length,
    locked: configs.filter((c) => c.locked === true).length,
    expired: configs.filter((c) => c.expiresAt > 0 && c.expiresAt < now).length,
    official: configs.filter((c) => c.isOfficial !== false).length,
    custom: configs.filter((c) => c.isOfficial === false).length,
    protocols,
    categories,
    countries,
  };
}

function loadLogs(env) {
  return env.SENSEI_KV.get('activity_logs', 'json').then((v) => v || []);
}

async function saveLog(env, entry) {
  try {
    const logs = await loadLogs(env);
    const now = new Date();
    const record = {
      id: 'log_' + now.getTime() + Math.random().toString(36).slice(2, 6),
      time: now.toISOString(),
      actor: entry.actor || '',
      action: entry.action || 'Admin action',
      type: entry.type || 'update',
      status: entry.status || 'info',
    };
    // _devOnly logs are hidden from Admin-role users.
    if (entry._devOnly) record._devOnly = true;
    logs.unshift(record);
    await env.SENSEI_KV.put('activity_logs', JSON.stringify(logs.slice(0, 200)));
  } catch {
    /* logging must never break an admin action */
  }
}

async function exportConfigs(env) {
  const configs = await loadConfigs(env);
  return new Response(JSON.stringify(configs, null, 2), {
    headers: {
      'Content-Type': 'application/json',
      'Content-Disposition': `attachment; filename="arman-configs-${new Date().toISOString().slice(0, 10)}.json"`,
    },
  });
}

// ---------------------------------------------------------------------------
// Static assets + plumbing
// ---------------------------------------------------------------------------

/**
 * Admin UI path gate. The React panel is served ONLY under /Arman-tunnel/admin
 * (a "web-based patch" identity: the same worker that powers /api/* no longer
 * exposes the login page at the bare domain root — a probe that fetches
 * the bare origin root gets a clean 404 instead of the panel).
 * /api/* keeps working for the app exactly as before.
 */
const ADMIN_BASE = '/Arman-tunnel/admin';

async function serveAssets(env, request) {
  const url = new URL(request.url);
  const path = url.pathname;

  if (path === ADMIN_BASE) {
    url.pathname = ADMIN_BASE + '/';
    return serveAssets(env, new Request(url.href, request));
  }
  if (!path.startsWith(ADMIN_BASE + '/')) {
    // Everything outside the gated path is a dead end for visitors. If you
    // want the bare Worker URL to bounce to your site, set the SITE_REDIRECT
    // var (e.g. "https://yourdomain.com/"); otherwise a plain 404 is returned.
    if (env.SITE_REDIRECT) return Response.redirect(env.SITE_REDIRECT, 302);
    return new Response('Not found', { status: 404 });
  }

  // Strip the gate prefix and let the ASSETS binding resolve the file by its
  // real dist path. The built UI uses base=/Arman-tunnel/admin/, so its own
  // asset URLs (/Arman-tunnel/admin/assets/*.js) round-trip through here.
  url.pathname = path.slice(ADMIN_BASE.length) || '/';
  const stripped = new Request(url.href, request);

  if (env.ASSETS) {
    const res = await env.ASSETS.fetch(stripped);
    const headers = new Headers(res.headers);
    headers.set('X-Content-Type-Options', 'nosniff');
    headers.set('Referrer-Policy', 'no-referrer');
    headers.set('X-Frame-Options', 'DENY');
    return new Response(res.body, { status: res.status, headers });
  }
  // The built React panel was not deployed (ui/dist missing).
  return new Response(
    `<!doctype html><meta charset="utf-8"><title>Arman Admin</title>
     <body style="font-family:sans-serif;background:#0b0f0c;color:#e6ffe6;display:grid;place-items:center;height:100vh">
     <div style="text-align:center">
       <h1>Arman Tunnel Admin</h1>
       <p>The web UI bundle is not deployed.</p>
       <p style="color:#9bb0a2">Build it: <code>cd admin-panel/ui &amp;&amp; npm install &amp;&amp; npm run build</code>, then redeploy the Worker.</p>
     </div></body>`,
    { headers: { 'Content-Type': 'text/html; charset=utf-8' } },
  );
}

async function readJson(request) {
  const raw = await request.arrayBuffer();
  if (raw.byteLength > MAX_BODY_BYTES) {
    throw new Error(`Body too large (${Math.round(raw.byteLength / 1048576)} MB)`);
  }
  const text = new TextDecoder().decode(raw);
  if (!text.trim()) return {};
  try {
    return JSON.parse(text);
  } catch {
    throw new Error('Request body is not valid JSON');
  }
}

function jsonResponse(data, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', ...extraHeaders },
  });
}

function htmlResponse(html, status = 200) {
  return new Response(html, {
    status,
    headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'public, max-age=3600' },
  });
}

/** No-store wrapper for anything session-related. */
function noStore(res) {
  res.headers.set('Cache-Control', 'no-store');
  return res;
}

function cors(res) {
  res.headers.set('Access-Control-Allow-Origin', '*');
  return res;
}

/**
 * Human-readable summary of a failed publish.
 *
 * WHY this exists: the SPA treats a response body with `ok:false` but no
 * `error` field as an opaque failure and prints "Request failed (HTTP 200)"
 * — because the HTTP status is 200 (the change WAS saved to KV) while the
 * GitHub push failed. That message tells the admin nothing, so every
 * publish-aware response must carry the real reason.
 */
function publishErrorMessage(pub) {
  if (!pub || pub.ok) return '';
  if (pub.error) return String(pub.error);
  const failed = (pub.files || []).filter((f) => f && f.ok === false);
  if (failed.length) {
    return (
      'GitHub push failed: ' +
      failed
        .map((f) => `${f.file} — ${f.error || (f.status ? 'HTTP ' + f.status : 'unknown error')}`)
        .join('; ')
    );
  }
  return 'GitHub push failed';
}

/**
 * Attach a machine-readable publish outcome AND make the HTTP status reflect
 * reality: data persisted but publish failed → the response keeps its 2xx
 * status (the data IS in KV) but carries `publish.ok:false` plus a top-level
 * `error` string, so the UI says "saved locally, GitHub push FAILED: <why>"
 * instead of the useless "Request failed (HTTP 200)".
 */
async function publishAware(res, pub) {
  if (!pub || pub.ok) return res;
  res.headers.set('X-Arman-Publish', pub.attempted ? 'failed' : 'not-configured');
  const msg = publishErrorMessage(pub);
  if (!msg) return res;
  // Re-send the body with the publish reason attached. The original body is
  // consumed here, so a fresh Response is built from it.
  let body;
  try {
    body = await res.json();
  } catch {
    return res;
  }
  if (!body || typeof body !== 'object' || body.error) return res;
  body.error = msg;
  const out = jsonResponse(body, res.status);
  for (const [k, v] of res.headers.entries()) {
    const key = k.toLowerCase();
    if (key === 'content-type' || key === 'content-length') continue;
    out.headers.set(k, v);
  }
  out.headers.set('X-Arman-Publish', pub.attempted ? 'failed' : 'not-configured');
  return out;
}
