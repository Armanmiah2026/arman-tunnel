// GitHub Contents-API publishing for the Arman Tunnel admin Worker.
//
// The app never talks to this Worker: it downloads the encrypted bundles from
// the configs repo (served through your CONFIG_RAW_BASE host).
// So a publish that silently fails means the app keeps serving stale configs —
// which is exactly what used to happen, because every publish call was wrapped
// in `try {} catch (_) {}`. Nothing here swallows errors: callers get a
// structured result and the API surfaces it.

const API = 'https://api.github.com';

export function githubConfigured(env) {
  return !!(env.GITHUB_TOKEN && env.GITHUB_REPO);
}

export function repoInfo(env) {
  return {
    repo: String(env.GITHUB_REPO || ''),
    branch: String(env.GITHUB_BRANCH || 'master'),
    configFile: String(env.GITHUB_FILE || 'sensei_configs_2026_v2.enc'),
    settingsFile: String(env.GITHUB_SETTINGS_FILE || 'sensei_app_settings.enc'),
    manifestFile: String(env.GITHUB_MANIFEST_FILE || 'manifest.json'),
    // rawBase: public CDN/Pages base the app downloads the .enc files from.
    // Set CONFIG_RAW_BASE to your own host (GitHub Pages custom domain, jsDelivr
    // over the configs repo, etc.). Empty here on purpose — no default.
    rawBase: String(env.CONFIG_RAW_BASE || '').replace(/\/+$/, ''),
  };
}

/** Public URL the app downloads a published file from. */
export function rawUrlFor(env, file) {
  return `${repoInfo(env).rawBase}/${file}`;
}

/** Fallback URL straight off GitHub, useful when the custom domain is down. */
export function githubRawUrlFor(env, file) {
  const { repo, branch } = repoInfo(env);
  return `https://raw.githubusercontent.com/${repo}/${branch}/${file}`;
}

function headers(env, extra = {}) {
  return {
    Authorization: 'Bearer ' + env.GITHUB_TOKEN,
    Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'arman-tunnel-admin-worker',
    ...extra,
  };
}

function utf8ToBase64(text) {
  const bytes = new TextEncoder().encode(text);
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
}

async function readError(res) {
  try {
    const j = await res.json();
    return j.message || JSON.stringify(j);
  } catch {
    return 'HTTP ' + res.status;
  }
}

/** Current blob sha of a file, or null when it does not exist yet. */
async function currentSha(env, file) {
  const { repo, branch } = repoInfo(env);
  const url = `${API}/repos/${repo}/contents/${encodeURI(file)}?ref=${encodeURIComponent(branch)}`;
  const res = await fetch(url, { headers: headers(env) });
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`Could not read ${file}: ${await readError(res)}`);
  const j = await res.json();
  return j.sha || null;
}

/**
 * Write one file. Retries the 409/422 sha race (another publish landed between
 * our read and our write) instead of dropping the update on the floor.
 */
export async function putFile(env, file, content, message) {
  if (!githubConfigured(env)) {
    return { ok: false, file, error: 'GitHub is not configured (need GITHUB_TOKEN + GITHUB_REPO)' };
  }
  const { repo, branch } = repoInfo(env);
  const url = `${API}/repos/${repo}/contents/${encodeURI(file)}`;
  let lastError = '';

  for (let attempt = 0; attempt < 3; attempt++) {
    let sha;
    try {
      sha = await currentSha(env, file);
    } catch (e) {
      return { ok: false, file, error: String((e && e.message) || e) };
    }
    const res = await fetch(url, {
      method: 'PUT',
      headers: headers(env, { 'Content-Type': 'application/json' }),
      body: JSON.stringify({
        message: message || `chore(admin): update ${file}`,
        content: utf8ToBase64(content),
        branch,
        ...(sha ? { sha } : {}),
      }),
    });
    if (res.ok) {
      const j = await res.json().catch(() => ({}));
      return {
        ok: true,
        file,
        commit: (j.commit && j.commit.sha) || '',
        bytes: content.length,
        rawUrl: rawUrlFor(env, file),
      };
    }
    lastError = await readError(res);
    // 409 = sha conflict, 422 = stale sha. Both are worth one more round.
    if (res.status !== 409 && res.status !== 422) {
      return { ok: false, file, status: res.status, error: lastError };
    }
  }
  return { ok: false, file, error: `Gave up after 3 attempts: ${lastError}` };
}

/**
 * Fetch a published file back from the public CDN URL (not the API) so the
 * check exercises exactly the path the app uses. Falls back to raw.github when
 * the custom domain has not propagated.
 */
export async function fetchPublished(env, file) {
  const urls = [rawUrlFor(env, file), githubRawUrlFor(env, file)];
  const errors = [];
  for (const url of urls) {
    try {
      const res = await fetch(url, {
        headers: { 'User-Agent': 'arman-tunnel-admin-worker', 'Cache-Control': 'no-cache' },
        cf: { cacheTtl: 0, cacheEverything: false },
      });
      if (res.ok) return { ok: true, url, body: await res.text() };
      errors.push(`${url} → HTTP ${res.status}`);
    } catch (e) {
      errors.push(`${url} → ${String((e && e.message) || e)}`);
    }
  }
  return { ok: false, error: errors.join('; ') };
}
