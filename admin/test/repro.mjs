// Local harness: run the admin Worker in-process with a fake KV + fake GitHub
// so we can reproduce the panel's "Request failed (HTTP 200)" without CF creds.
//
//   node admin/test/repro.mjs            # default: GitHub OK
//   node admin/test/repro.mjs githubFail # simulate GitHub push failure
//   node admin/test/repro.mjs noCsrf     # simulate CSRF mismatch
//
// NOTE: keep this file out of the deployed Worker bundle (it is not imported
// by src/index.js, so wrangler never ships it).

import worker from '../src/index.js';

// ---------------------------------------------------------------------------
// Fake KV
// ---------------------------------------------------------------------------
const kvStore = new Map();
const SENSEI_KV = {
  async get(key, type) {
    const v = kvStore.get(key);
    if (v === undefined) return null;
    if (type === 'json') return JSON.parse(v);
    return v;
  },
  async put(key, value) {
    kvStore.set(key, typeof value === 'string' ? value : JSON.stringify(value));
  },
  async delete(key) {
    kvStore.delete(key);
  },
  async list() {
    return { keys: [...kvStore.keys()].map((name) => ({ name })) };
  },
};

// ---------------------------------------------------------------------------
// Fake GitHub + CDN
// ---------------------------------------------------------------------------
const mode = process.argv[2] || 'ok';
const realFetch = globalThis.fetch;
globalThis.fetch = async (input, init) => {
  const url = typeof input === 'string' ? input : input.url;
  if (url.includes('api.github.com')) {
    if (mode === 'githubFail') {
      return new Response(JSON.stringify({ message: 'Bad credentials' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    if (url.includes('/releases')) {
      return new Response(
        JSON.stringify([
          {
            tag_name: 'v1.0.57-b8',
            name: 'SnapDark Tunnel 1.0.57 (build 8)',
            published_at: '2026-10-20T21:43:30Z',
            prerelease: false,
            html_url: 'https://github.com/Armanmiah2026/arman-tunnel-configs/releases/tag/v1.0.57-b8',
            assets: [
              {
                name: 'SnapDark-Tunnel-1.0.57-arm64-v8a.apk',
                size: 33979155,
                browser_download_url: 'https://github.com/x/SnapDark-Tunnel-1.0.57-arm64-v8a.apk',
              },
              {
                name: 'SnapDark-Tunnel-1.0.57-armeabi-v7a.apk',
                size: 33028299,
                browser_download_url: 'https://github.com/x/SnapDark-Tunnel-1.0.57-armeabi-v7a.apk',
              },
            ],
          },
        ]),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      );
    }
    if (url.includes('/contents/version.json')) {
      const payload = {
        versionName: '1.0.57',
        versionCode: 63,
        arm64VersionCode: 632,
        armv7VersionCode: 631,
        apkDownloadUrl: 'https://github.com/x/SnapDark-Tunnel-1.0.57-arm64-v8a.apk',
        publishedAt: '2026-10-20T21:43:30Z',
      };
      return new Response(
        JSON.stringify({
          content: btoa(JSON.stringify(payload)),
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      );
    }
    if (init && init.method === 'PUT') {
      return new Response(
        JSON.stringify({ commit: { sha: 'deadbeef'.repeat(5) }, content: { sha: 'x' } }),
        { status: 201, headers: { 'Content-Type': 'application/json' } },
      );
    }
    return new Response(JSON.stringify({ sha: 'sha-' + Math.random().toString(36).slice(2) }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  }
  // CDN / raw.githubusercontent fallback used by /api/verify
  return new Response('payload', { status: 200 });
};

// ---------------------------------------------------------------------------
// Env
// ---------------------------------------------------------------------------
const env = {
  SENSEI_KV,
  ADMIN_USER: 'admin',
  ADMIN_PASSWORD: 'hunter2hunter2',
  JWT_SECRET: 'test-secret-test-secret-test-secret-1234567890',
  GITHUB_TOKEN: 'ghp_test',
  GITHUB_REPO: 'test/configs',
  GITHUB_BRANCH: 'main',
  GITHUB_FILE: 'c.enc',
  GITHUB_SETTINGS_FILE: 's.enc',
  CONFIG_RAW_BASE: 'https://cdn.example.com',
  APP_CERT_SHA256: process.env.APP_CERT_SHA256 || '',
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
let cookie = '';
let csrf = '';

async function call(method, path, body, { withCsrf = true } = {}) {
  const headers = { 'Content-Type': 'application/json' };
  if (cookie) headers.Cookie = cookie;
  if (withCsrf && csrf && method !== 'GET') headers['X-CSRF-Token'] = csrf;
  const res = await worker.fetch(
    new Request('https://worker.test' + path, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    }),
    env,
    { waitUntil: () => {} },
  );
  const setCookie = res.headers.get('Set-Cookie');
  if (setCookie) {
    const parts = setCookie.split(/,(?=\s*\w+=)/);
    for (const p of parts) {
      const kv = p.split(';')[0];
      const [k, v] = kv.split('=');
      if (k === 'sensei_sess') cookie = `sensei_sess=${v}`;
    }
  }
  const text = await res.text();
  let data = null;
  try {
    data = JSON.parse(text);
  } catch {
    data = null;
  }
  return { status: res.status, data, text };
}

function show(label, r) {
  const body = r.text.length > 400 ? r.text.slice(0, 400) + '…' : r.text;
  console.log(`\n### ${label}`);
  console.log(`  status: ${r.status}`);
  console.log(`  body:   ${body}`);
  // Reproduce the UI client's error decision (admin/ui/src/api.ts)
  if (!r.status || r.status < 200 || r.status >= 300) {
    const msg = (r.data && (r.data.error || r.data.message)) || `Request failed (HTTP ${r.status})`;
    console.log(`  UI WOULD SHOW: ${msg}`);
  } else if (r.data && r.data.ok === false) {
    const msg = (r.data && (r.data.error || r.data.message)) || `Request failed (HTTP ${r.status})`;
    console.log(`  UI WOULD SHOW: ${msg}`);
  } else {
    console.log('  UI: success');
  }
}

// ---------------------------------------------------------------------------
// Scenario
// ---------------------------------------------------------------------------
console.log(`mode = ${mode}`);

const login = await call('POST', '/api/login', { username: 'admin', password: 'hunter2hunter2' });
csrf = login.data?.csrf || '';
show('POST /api/login', login);

const boot = await call('GET', '/api/bootstrap');
console.log(`\n### GET /api/bootstrap -> ${boot.status}`);

const releases = await call('GET', '/api/releases');
show('GET /api/releases', releases);

const build = await call('GET', '/api/latest-build');
show('GET /api/latest-build', build);

const server = await call('POST', '/api/servers', {
  name: 'Test Server',
  address: 'example.com',
  port: 443,
  protocol: 'vless',
  uuid: '11111111-2222-3333-4444-555555555555',
  username: 'u',
  password: 'p',
});
show('POST /api/servers', server);

const settings = await call('POST', '/api/settings', {
  payloadDefs: { '[TEST]': 'GET / HTTP/1.1\r\nHost: a\r\n\r\n' },
});
show('POST /api/settings', settings);

const publish = await call('POST', '/api/publish', {});
show('POST /api/publish', publish);

// CSRF mismatch case
const noCsrf = await call('POST', '/api/servers', { name: 'X' }, { withCsrf: false });
show('POST /api/servers (no CSRF header)', noCsrf);

// No session case
cookie = '';
const noSess = await call('POST', '/api/servers', { name: 'X' });
show('POST /api/servers (no session)', noSess);
