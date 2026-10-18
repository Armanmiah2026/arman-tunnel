// Static legal pages served by the Worker (Play Console requires a public
// privacy-policy URL; the listing links here). Keep in sync with the actual
// Data-safety declarations — say ONLY what the app really does.

const SHELL = (title, body) => `<!DOCTYPE html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title} — Arman Tunnel</title>
<style>
 body{font-family:system-ui,-apple-system,sans-serif;background:#0B0F0C;color:#D7E3DA;
      max-width:720px;margin:0 auto;padding:32px 20px;line-height:1.6}
 h1,h2{color:#00E676} a{color:#C6FF00} li{margin:.4em 0}
 footer{margin-top:48px;font-size:.85em;color:#6d7d72;border-top:1px solid #223026;padding-top:16px}
</style></head><body>${body}
<footer>Arman Tunnel · contact via the in-app support screen</footer>
</body></html>`;

export const PRIVACY_HTML = SHELL('Privacy Policy', `
<h1>Privacy Policy</h1>
<p>Last updated: 2026-09-16</p>
<p>Arman Tunnel is a VPN client. We designed it to collect as little as
possible. In plain terms:</p>
<h2>What the app stores on your device only</h2>
<ul>
  <li><b>VPN configurations and credentials</b> you import — encrypted at rest
      with a device keystore key; never uploaded by us.</li>
  <li><b>Connection history and logs</b> — kept locally; you can clear them any
      time; they are never transmitted to our servers.</li>
  <li><b>A device identifier</b> computed locally. It is used only when YOU
      choose to protect a shared configuration with a device lock. It is not
      sent anywhere unless a config seller embeds it in a share they generate
      for you.</li>
</ul>
<h2>What is sent over the network</h2>
<ul>
  <li><b>Tunnel traffic</b> is encrypted to the VPN server you (or your
      provider) configured. We operate no middlebox and keep no connection
      logs, no DNS logs and no traffic logs.</li>
  <li>The app fetches an <b>encrypted configuration bundle</b> from
      GitHub- and Cloudflare-hosted endpoints (delivery only; the payload is
      end-encrypted). Basic request metadata (IP, user-agent) is handled by
      GitHub/Cloudflare per their policies.</li>
  <li>The in-app <b>speed test</b> loads fast.com in a WebView; the latency
    probe sends a small HEAD request through your tunnel to the target you
    choose.</li>
  <li><b>Fonts</b> are bundled with the app (no Google Fonts network fetch at
    runtime).</li>
</ul>
<h2>What we do NOT do</h2>
<ul>
  <li>No accounts, no email, no phone number, no contacts, no location.</li>
  <li>No advertising SDKs, no analytics SDKs, no third-party trackers.</li>
  <li>No sale or sharing of any personal data — there is none to share.</li>
</ul>
<h2>Children</h2>
<p>The app is not directed to children under 13 and collects no data from
anyone.</p>
<h2>Deleting your data</h2>
<p>All app data lives on your device: <b>Uninstalling the app deletes
everything</b> (settings, configs, history, device identifier). Server-side
there is no user record to delete.</p>
<h2>Changes</h2>
<p>Material changes will be posted on this page with a new date.</p>
`);

export const TERMS_HTML = SHELL('Terms of Service', `
<h1>Terms of Service</h1>
<p>Last updated: 2026-09-16</p>
<h2>1. What the app is</h2>
<p>Arman Tunnel is a general-purpose VPN <i>client</i>. It connects to servers
that you or your network provider configure. We do not operate VPN servers and
are not responsible for the availability, speed or policies of third-party
servers.</p>
<h2>2. Acceptable use</h2>
<p>You agree to use the app only in accordance with the laws that apply to
you. Do not use it for anything illegal — we do not monitor your traffic and
cannot police it, but misuse is entirely on you.</p>
<h2>3. No warranty / no liability</h2>
<p>The app is provided "as is", without warranty of any kind. VPN technology
can be blocked, degraded or disconnected at any time by networks or devices.
We are not liable for interruptions, data loss or any damages arising from
use.</p>
<h2>4. Configuration &amp; paid services</h2>
<p>Configuration bundles shared by resellers/sellers are agreements between
you and that seller (expiry, device limits, refunds). We provide the tooling;
we are not party to those sales.</p>
<h2>5. Termination</h2>
<p>You may stop using the app at any time by uninstalling it. These terms end
with the uninstall.</p>
<h2>6. Contact</h2>
<p>Reach us through the support screen inside the app.</p>
`);
