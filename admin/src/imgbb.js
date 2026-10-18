// imgbb.com image hosting for the admin panel (the image "DB").
//
// No API key: imgbb's own web uploader is used — the CSRF auth_token is
// scraped from the homepage and the file POSTed to /json, exactly like the
// reference implementation in dtunnel_pannel. Returned URLs are public,
// permanent and hot-linkable, which is all the app and the panel need:
// the "database" is the URL string stored in the config/backend fields.
//
// Runs inside the Cloudflare Worker (fetch + FormData are native there).

const MAX_IMAGE_BYTES = 5 * 1024 * 1024; // 5 MB decoded

/** Upload raw image bytes; returns { ok, url, deleteUrl } or { ok:false, error }. */
export async function uploadToImgbb(bytes, filename, contentType) {
  try {
    if (!(bytes instanceof Uint8Array) || bytes.byteLength === 0) {
      return { ok: false, error: 'Empty image' };
    }
    if (bytes.byteLength > MAX_IMAGE_BYTES) {
      return { ok: false, error: `Image too large (${Math.round(bytes.byteLength / 1048576)} MB, max 5 MB)` };
    }
    const type = String(contentType || '').toLowerCase();
    if (type && !type.startsWith('image/')) {
      return { ok: false, error: 'Only image files are allowed' };
    }

    // 1) Scrape the session's CSRF token off the homepage.
    const home = await fetch('https://imgbb.com', {
      headers: { 'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 ArmanPanel/1.0' },
    });
    const html = await home.text();
    const m = html.match(/auth_token="([^"]+)"/);
    if (!m) return { ok: false, error: 'imgbb did not provide an auth token (page changed?)' };

    // 2) POST the file exactly like the site's own uploader.
    const form = new FormData();
    form.append(
      'source',
      new Blob([bytes], { type: type || 'image/png' }),
      filename || 'logo.png',
    );
    form.append('type', 'file');
    form.append('action', 'upload');
    form.append('timestamp', String(Date.now()));
    form.append('auth_token', m[1]);

    const up = await fetch('https://imgbb.com/json', { method: 'POST', body: form });
    const res = await up.json();
    if (res && res.success && String(res.success.code) === '200') {
      return {
        ok: true,
        url: res.image && (res.image.display_url || res.image.url),
        deleteUrl: res.image ? res.image.delete_url : undefined,
      };
    }
    return { ok: false, error: (res && res.error && res.error.message) || 'imgbb rejected the upload' };
  } catch (e) {
    return { ok: false, error: 'imgbb upload failed: ' + (e && e.message ? e.message : String(e)) };
  }
}

/** Decode a base64 payload (raw or data-URL) into bytes. Throws on garbage. */
export function decodeBase64Image(dataBase64) {
  let b64 = String(dataBase64 || '').trim();
  const comma = b64.indexOf(',');
  if (b64.startsWith('data:')) {
    b64 = b64.slice(comma + 1);
  } else if (comma >= 0 && /^data:/i.test(b64.slice(0, 5))) {
    b64 = b64.slice(comma + 1);
  }
  // Normalize URL-safe base64 to standard.
  b64 = b64.replace(/-/g, '+').replace(/_/g, '/').replace(/\s+/g, '');
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
