// Round-trip tests for the canonical config schema.
// Run: node admin-panel/src/config-schema.test.mjs
//
// These guard the exact bug this schema exists to prevent: a config that loses
// fields (uuid, reality keys, inject payload, ovpn body, ...) somewhere between
// the admin panel form and the encrypted bundle the app downloads.

import assert from 'node:assert/strict';
import {
  normalizeConfig,
  validateConfig,
  parseAnyConfigText,
  splitSubscription,
  buildShareLink,
  toAppConfig,
  dedupeKey,
  normalizeInjectMode,
  expandPayload,
  expandConfigPayloads,
  normalizeServer,
  validateServer,
  joinServerIntoConfig,
  serverToAppConfig,
  validateVariantConfig,
  normalizeCategoryEntity,
  validateCategoryEntity,
  normalizeCategoryName,
  normalizeCategoryValue,
  inferCapability,
  normalizeCapabilityType,
  validateCapabilityType,
  DEFAULT_CAPABILITY_DESCRIPTIONS,
} from './config-schema.js';

let passed = 0;
function test(name, fn) {
  try {
    fn();
    passed++;
  } catch (e) {
    console.error('FAIL: ' + name);
    console.error(e.message);
    process.exitCode = 1;
  }
}

// ---------------------------------------------------------------------------

test('vless link keeps reality + ws fields through normalize', () => {
  const link =
    'vless://11111111-2222-3333-4444-555555555555@example.com:8443' +
    '?type=ws&security=reality&path=%2Fvless&host=cdn.example.com&sni=fake.host' +
    '&pbk=PUBKEY123&sid=ab12&fp=firefox&flow=xtls-rprx-vision#My%20Node';
  const c = normalizeConfig({ rawContent: link });
  assert.equal(c.protocol, 'vless');
  assert.equal(c.address, 'example.com');
  assert.equal(c.port, 8443);
  assert.equal(c.uuid, '11111111-2222-3333-4444-555555555555');
  assert.equal(c.transport, 'ws');
  assert.equal(c.security, 'reality');
  assert.equal(c.path, '/vless');
  assert.equal(c.host, 'cdn.example.com');
  assert.equal(c.sni, 'fake.host');
  assert.equal(c.publicKey, 'PUBKEY123');
  assert.equal(c.shortId, 'ab12');
  assert.equal(c.fingerprint, 'firefox');
  assert.equal(c.flow, 'xtls-rprx-vision');
  assert.equal(c.name, 'My Node');
});

test('vless link with xhttp/httpupgrade/kcp transports', () => {
  const cases = [
    ['xhttp', 'xhttp'],
    ['splithttp', 'xhttp'],
    ['httpupgrade', 'httpupgrade'],
    ['http-upgrade', 'httpupgrade'],
    ['kcp', 'kcp'],
    ['mkcp', 'kcp'],
  ];
  for (const [wire, canonical] of cases) {
    const link =
      'vless://11111111-2222-3333-4444-555555555555@example.com:443' +
      `?type=${wire}&security=none#T`;
    const c = normalizeConfig({ rawContent: link });
    assert.equal(c.transport, canonical, `type=${wire} should normalize to ${canonical}`);
  }
});

test('vmess grpc service name does not land in path', () => {
  const payload = {
    ps: 'GRPC Node',
    add: 'g.example.com',
    port: '2053',
    id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
    aid: '4',
    net: 'grpc',
    path: 'GunService',
    tls: 'tls',
    sni: 'g.example.com',
    scy: 'zero',
  };
  const link = 'vmess://' + Buffer.from(JSON.stringify(payload)).toString('base64');
  const c = normalizeConfig({ rawContent: link });
  assert.equal(c.transport, 'grpc');
  assert.equal(c.serviceName, 'GunService');
  assert.equal(c.path, '');
  assert.equal(c.alterId, '4');
  assert.equal(c.encryption, 'zero');
  assert.equal(validateConfig(c).ok, true, 'grpc config should validate');
});

test('trojan link fills both password and uuid', () => {
  const c = normalizeConfig({
    rawContent: 'trojan://s3cret@t.example.com:443?type=ws&path=/tj&sni=t.example.com#TJ',
  });
  assert.equal(c.protocol, 'trojan');
  assert.equal(c.password, 's3cret');
  assert.equal(c.uuid, 's3cret');
  assert.equal(c.transport, 'ws');
  assert.equal(validateConfig(c).ok, true);
});

test('ss link with v2ray-plugin keeps ws transport', () => {
  const creds = Buffer.from('aes-256-gcm:hunter2').toString('base64');
  const link = `ss://${creds}@ss.example.com:8080?plugin=v2ray-plugin;tls;host=cdn.io;path=/ws#SS%20Node`;
  const c = normalizeConfig({ rawContent: link });
  assert.equal(c.protocol, 'shadowsocks');
  assert.equal(c.encryption, 'aes-256-gcm');
  assert.equal(c.password, 'hunter2');
  assert.equal(c.address, 'ss.example.com');
  assert.equal(c.port, 8080);
  assert.equal(c.transport, 'ws');
  assert.equal(c.path, '/ws');
  assert.equal(c.host, 'cdn.io');
  assert.equal(c.security, 'tls');
  assert.equal(validateConfig(c).ok, true);
});

test('ovpn body supplies address and port when the form left them blank', () => {
  const ovpn = ['client', 'dev tun', 'proto tcp', 'remote vpn.example.com 8443', '<ca>', 'x', '</ca>'].join('\n');
  const c = normalizeConfig({ name: 'OVPN', protocol: 'openvpn', ovpnConfig: ovpn });
  assert.equal(c.address, 'vpn.example.com');
  assert.equal(c.port, 8443);
  assert.equal(validateConfig(c).ok, true);
});

test('ovpn with bare auth-user-pass fails validation without credentials', () => {
  const ovpn = ['client', 'dev tun', 'remote vpn.example.com 1194', 'auth-user-pass'].join('\n');
  const c = normalizeConfig({ name: 'OVPN', protocol: 'openvpn', ovpnConfig: ovpn });
  const v = validateConfig(c);
  assert.equal(v.ok, false);
  assert.ok(v.errors.some((e) => e.field === 'sshUser'));
  const fixed = validateConfig({ ...c, sshUser: 'user', sshPass: 'pw' });
  assert.equal(fixed.ok, true);
});

test('explicit form fields win over the parsed share link', () => {
  const link = 'vless://aaaa@old.example.com:443?type=tcp#Old';
  const c = normalizeConfig({ rawContent: link, name: 'New Name', address: 'new.example.com', port: 2096 });
  assert.equal(c.name, 'New Name');
  assert.equal(c.address, 'new.example.com');
  assert.equal(c.port, 2096);
  // ...but untouched fields still come from the link.
  assert.equal(c.uuid, 'aaaa');
});

test('ssh + dnstt requires nameserver and key', () => {
  const base = {
    name: 'SlowDNS',
    protocol: 'slowdns',
    address: 'ssh.example.com',
    port: 22,
    sshUser: 'root',
    sshPass: 'toor',
  };
  const c = normalizeConfig(base);
  assert.equal(c.protocol, 'ssh_dnstt');
  const v = validateConfig(c);
  assert.equal(v.ok, false);
  assert.ok(v.errors.some((e) => e.field === 'dnsttServer'));
  const ok = validateConfig(
    normalizeConfig({ ...base, dnsttServer: 'ns.example.com', dnsttKey: 'deadbeef', dnsttResolver: '1.1.1.1:53' }),
  );
  assert.equal(ok.ok, true);
});

test('inject proxy mode without a bug host uses the default server front', () => {
  const c = normalizeConfig({
    name: 'Inject',
    protocol: 'ssh',
    address: 'ssh.example.com',
    port: 22,
    sshUser: 'u',
    sshPass: 'p',
    injectMode: 'proxy with sni',
  });
  assert.equal(c.injectMode, 'proxySni');
  assert.equal(c.injectHost, '[Default]');
  assert.equal(c.injectPort, '80');
  const v = validateConfig(c);
  assert.equal(v.ok, true, JSON.stringify(v.errors));
});

test('inject mode spellings normalize like the app does', () => {
  assert.equal(normalizeInjectMode('DIRECT_SNI'), 'directSni');
  assert.equal(normalizeInjectMode('Proxy-With-SNI'), 'proxySni');
  assert.equal(normalizeInjectMode('direct target'), 'direct');
  assert.equal(normalizeInjectMode('garbage'), 'none');
});

test('category and country are separate fields', () => {
  const c = normalizeConfig({
    name: 'N',
    protocol: 'vless',
    address: 'a.example.com',
    uuid: '11111111-2222-3333-4444-555555555555',
    category: 'gaming',
    countryCode: 'sg',
  });
  assert.equal(c.category, 'gaming');
  assert.equal(c.country, 'SG');
  // An unknown category falls back rather than poisoning the app's grouping.
  assert.equal(normalizeConfig({ category: 'BD' }).category, 'global');
});

test('every app-facing field survives normalize -> toAppConfig', () => {
  const full = {
    id: 'fixed-id',
    name: 'Full',
    note: 'Full',
    protocol: 'vless',
    transport: 'ws',
    security: 'tls',
    address: 'a.example.com',
    port: 2087,
    uuid: '11111111-2222-3333-4444-555555555555',
    alterId: '2',
    password: 'pw',
    encryption: 'none',
    sni: 'sni.example.com',
    path: '/p',
    wsHost: 'h.example.com',
    serviceName: 'svc',
    fingerprint: 'safari',
    flow: 'xtls-rprx-vision',
    publicKey: 'pbk',
    shortId: 'sid',
    isOfficial: true,
    logoBase64: 'AAAA',
    payload: 'GET / HTTP/1.1[crlf][crlf]',
    sshUser: 'u',
    sshPass: 'p',
    injectHost: 'bug.example.com',
    injectPort: '8080',
    injectPayload: 'x',
    injectMode: 'proxy',
    dnsttServer: 'ns.example.com',
    dnsttKey: 'key',
    dnsttResolver: '8.8.8.8:53',
    ovpnConfig: '',
    wireguardConfig: '[Interface]\nPrivateKey = x',
    psiphonRegion: 'US',
    payloadEnhanced: true,
    sshCompression: true,
    category: 'streaming',
    countryCode: 'JP',
    region: 'Tokyo',
    author: 'Tester',
    encryptionKey: 'k',
    locked: true,
    lockMessage: 'nope',
    expiresAt: 1900000000000,
    vip: true,
    vipUnlockHours: 4,
  };
  const c = normalizeConfig(full);
  const app = toAppConfig(c);
  // Field-by-field: nothing may be dropped or silently emptied.
  for (const [k, v] of Object.entries({
    id: 'fixed-id',
    name: 'Full',
    note: 'Full',
    protocol: 'vless',
    transport: 'ws',
    security: 'tls',
    address: 'a.example.com',
    port: 2087,
    uuid: full.uuid,
    alterId: '2',
    password: 'pw',
    encryption: 'none',
    sni: 'sni.example.com',
    path: '/p',
    host: 'h.example.com',
    serviceName: 'svc',
    fingerprint: 'safari',
    flow: 'xtls-rprx-vision',
    publicKey: 'pbk',
    shortId: 'sid',
    isOfficial: true,
    logoBase64: 'AAAA',
    payload: 'GET / HTTP/1.1[crlf][crlf]',
    sshUser: 'u',
    sshPass: 'p',
    injectHost: 'bug.example.com',
    injectPort: '8080',
    injectPayload: 'x',
    injectMode: 'proxy',
    dnsttServer: 'ns.example.com',
    dnsttKey: 'key',
    dnsttResolver: '8.8.8.8:53',
    wireguardConfig: '[Interface]\nPrivateKey = x',
    psiphonRegion: 'US',
    payloadEnhanced: true,
    sshCompression: true,
    category: 'streaming',
    country: 'JP',
    region: 'Tokyo',
    author: 'Tester',
    encryptionKey: 'k',
    locked: true,
    lockMessage: 'nope',
    expiresAt: 1900000000000,
    vip: true,
    vipUnlockHours: 4,
  })) {
    assert.deepEqual(app[k], v, `field "${k}" lost: ${JSON.stringify(app[k])}`);
  }
  // Admin bookkeeping must NOT reach the device bundle.
  for (const k of ['active', 'priority', 'maxConnections', 'createdAt', 'updatedAt']) {
    assert.equal(k in app, false, `admin field "${k}" leaked into the app bundle`);
  }
});

test('re-normalizing an app config is stable (edit does not lose data)', () => {
  const first = normalizeConfig({
    name: 'Stable',
    protocol: 'vmess',
    address: 'v.example.com',
    port: 443,
    uuid: '11111111-2222-3333-4444-555555555555',
    transport: 'ws',
    security: 'tls',
    path: '/ws',
    wsHost: 'cdn.example.com',
    payload: 'GET / HTTP/1.1[crlf][crlf]',
    injectMode: 'direct',
    fingerprint: 'chrome',
  });
  const second = normalizeConfig(toAppConfig(first));
  const a = toAppConfig(first);
  const b = toAppConfig(second);
  assert.deepEqual(b, a, 'a second edit pass changed the config');
});

test('share link round trip preserves the endpoint', () => {
  const c = normalizeConfig({
    name: 'RT',
    protocol: 'vless',
    address: 'rt.example.com',
    port: 8443,
    uuid: '11111111-2222-3333-4444-555555555555',
    transport: 'ws',
    security: 'tls',
    path: '/rt',
    wsHost: 'cdn.rt',
    sni: 'sni.rt',
  });
  const back = normalizeConfig({ rawContent: buildShareLink(c) });
  assert.equal(back.address, c.address);
  assert.equal(back.port, c.port);
  assert.equal(back.uuid, c.uuid);
  assert.equal(back.path, c.path);
  assert.equal(back.host, c.host);
  assert.equal(back.sni, c.sni);
  assert.equal(back.security, c.security);
});

test('vmess share link round trip', () => {
  const c = normalizeConfig({
    name: 'VM',
    protocol: 'vmess',
    address: 'vm.example.com',
    port: 443,
    uuid: '11111111-2222-3333-4444-555555555555',
    transport: 'grpc',
    security: 'tls',
    serviceName: 'Gun',
  });
  const back = normalizeConfig({ rawContent: buildShareLink(c) });
  assert.equal(back.protocol, 'vmess');
  assert.equal(back.serviceName, 'Gun');
  assert.equal(back.transport, 'grpc');
});

test('ssh has no share URI so buildShareLink hands back app JSON', () => {
  const c = normalizeConfig({
    name: 'SSH',
    protocol: 'ssh',
    address: 's.example.com',
    port: 22,
    sshUser: 'u',
    sshPass: 'p',
  });
  const out = buildShareLink(c);
  const parsed = JSON.parse(out);
  assert.equal(parsed.protocol, 'ssh');
  assert.equal(parsed.sshUser, 'u');
});

test('subscription splitting handles base64 and raw', () => {
  const links = ['vless://a@h1:443#one', 'trojan://p@h2:443#two', '# comment', ''].join('\n');
  assert.equal(splitSubscription(links).length, 2);
  const b64 = Buffer.from(links).toString('base64');
  assert.equal(splitSubscription(b64).length, 2);
});

test('darktunnel SSH share flattens into canonical fields', () => {
  const payload = {
    type: 'SSH',
    name: 'DT SSH',
    sshTunnelConfig: {
      sshConfig: { host: 'dt.example.com', port: 143, username: 'root', password: 'pw' },
      injectConfig: { mode: 'proxy', payload: 'GET / HTTP/1.1[crlf][crlf]', host: 'bug.io', port: 8080 },
    },
  };
  const link = 'darktunnel://' + Buffer.from(JSON.stringify(payload)).toString('base64url');
  const c = normalizeConfig({ rawContent: link });
  assert.equal(c.protocol, 'ssh');
  assert.equal(c.address, 'dt.example.com');
  assert.equal(c.port, 143);
  assert.equal(c.sshUser, 'root');
  assert.equal(c.sshPass, 'pw');
  assert.equal(c.injectMode, 'proxy');
  assert.equal(c.injectHost, 'bug.io');
  assert.equal(c.injectPort, '8080');
  assert.equal(validateConfig(c).ok, true);
});

test('vip: vip flag + unlock hours clamp to 1..24 and never leak bookkeeping', () => {
  const c = normalizeConfig({
    name: 'VIP Box',
    protocol: 'ssh',
    address: 'vip.example.com',
    port: 443,
    sshUser: 'u',
    sshPass: 'p',
    vip: 'yes',
    vipUnlockHours: 99,
  });
  const app = toAppConfig(c);
  assert.equal(app.vip, true, 'vip should normalize from truthy input');
  assert.equal(app.vipUnlockHours, 24, 'vipUnlockHours should clamp to 24');
  const c2 = normalizeConfig({ ...c, vip: false, vipUnlockHours: 0 });
  assert.equal(c2.vip, false);
  assert.equal(toAppConfig(c2).vipUnlockHours, 2, 'default unlock hours is 2');
});

test('wireguard requires a real [Interface] wg.conf body (not bare keys)', () => {
  const withBody = normalizeConfig({
    name: 'WG', protocol: 'wireguard', address: 'wg.example.com', port: 51820,
    wireguardConfig: '[Interface]\nPrivateKey = AAAA\n[Peer]\nPublicKey = BBBB',
  });
  assert.ok(withBody.wireguardConfig.startsWith('[Interface]'));
  const vr = validateConfig(withBody);
  assert.ok(vr.ok, 'wg.conf body should validate: ' + JSON.stringify(vr.errors));
  const noBody = normalizeConfig({ name: 'WG2', protocol: 'wireguard', address: 'x', port: 1 });
  const vr2 = validateConfig(noBody);
  assert.equal(vr2.ok, false, 'missing wg.conf must fail validation');
  assert.ok(vr2.errors.some((e) => e.field === 'wireguardConfig'));
});

test('wireguard body survives normalize -> toAppConfig untouched', () => {
  const c = normalizeConfig({
    name: 'WG', protocol: 'wireguard', address: 'wg.example.com', port: 51820,
    wireguardConfig: '[Interface]\nPrivateKey = AAAA\n[Peer]\nAllowedIPs = 0.0.0.0/0',
  });
  const app = toAppConfig(c);
  assert.equal(app.wireguardConfig, c.wireguardConfig);
});

test('validation rejects the obvious garbage', () => {
  const v = validateConfig(normalizeConfig({ name: '', protocol: 'vless', address: '', port: 0 }));
  assert.equal(v.ok, false);
  const fields = v.errors.map((e) => e.field);
  assert.ok(fields.includes('name'));
  assert.ok(fields.includes('address'));
  assert.ok(fields.includes('uuid'));
});

test('port coercion and bounds', () => {
  assert.equal(normalizeConfig({ port: '8080' }).port, 8080);
  assert.equal(normalizeConfig({ protocol: 'ssh' }).port, 22);
  assert.equal(normalizeConfig({ protocol: 'openvpn' }).port, 1194);
  assert.equal(normalizeConfig({ protocol: 'vless', security: 'tls' }).port, 443);
  assert.equal(normalizeConfig({ protocol: 'vless', security: 'none' }).port, 80);
  const v = validateConfig(normalizeConfig({ name: 'x', protocol: 'ssh', address: 'a', port: 99999, sshUser: 'u', sshPass: 'p' }));
  assert.ok(v.errors.some((e) => e.field === 'port'));
});

test('dedupe key ignores cosmetic differences', () => {
  const a = normalizeConfig({ protocol: 'vless', address: 'A.example.com', port: 443, uuid: 'U1', name: 'one' });
  const b = normalizeConfig({ protocol: 'vless', address: 'a.example.com', port: 443, uuid: 'u1', name: 'two' });
  assert.equal(dedupeKey(a), dedupeKey(b));
});

test('dedupe key treats distinct injection variants as separate nodes', () => {
  const base = { protocol: 'ssh', address: 's.example.com', port: 443, sshUser: 'uu', sshPass: 'pp' };
  const a = normalizeConfig({ ...base, injectMode: 'proxySni', injectHost: 'bug-a.local', payload: 'GET / HTTP/1.0' });
  const b = normalizeConfig({ ...base, injectMode: 'directSni', sni: 'tls.example.com' });
  const c = normalizeConfig({ ...base }); // no injection
  const d = normalizeConfig({ ...base }); // blank injection == c
  assert.notEqual(dedupeKey(a), dedupeKey(b));
  assert.notEqual(dedupeKey(a), dedupeKey(c));
  assert.notEqual(dedupeKey(b), dedupeKey(c));
  assert.equal(dedupeKey(c), dedupeKey(d));
});

test('server grouping label is preserved through normalize + toAppConfig', () => {
  const c = normalizeConfig({ protocol: 'ssh', address: 's.example.com', port: 443, sshUser: 'u', sshPass: 'p', server: 'SG Core 2' });
  assert.equal(c.server, 'SG Core 2');
  assert.equal(toAppConfig(c).server, 'SG Core 2');
});

test('payload token expansion resolves named defs and intrinsic placeholders', () => {
  const defs = {
    RYZE: 'HTTP/1.1[crlf]Host: telegram.org[crlf]User-Agent: [ua][crlf][crlf]',
    ROBI: 'HTTP/1.1[crlf]Host: viber.com[crlf][crlf]',
  };
  assert.equal(expandPayload('[RYZE]', defs), 'HTTP/1.1\r\nHost: telegram.org\r\nUser-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36\r\n\r\n');
  assert.equal(expandPayload('[ROBI]', defs), 'HTTP/1.1\r\nHost: viber.com\r\n\r\n');
  // unknown token is left untouched
  assert.equal(expandPayload('[NOPE]', defs), '[NOPE]');
  // mixed literal + token
  assert.equal(expandPayload('hi[crlf][ROBI]', defs), 'hi\r\nHTTP/1.1\r\nHost: viber.com\r\n\r\n');
});

test('expandConfigPayloads expands payload/injectPayload only', () => {
  const c = normalizeConfig({ protocol: 'vless', address: 'a.example.com', uuid: 'u', payload: '[RYZE]', injectPayload: 'X[ua]' });
  const out = expandConfigPayloads(c, { RYZE: 'P' });
  assert.equal(out.payload, 'P');
  assert.ok(out.injectPayload.startsWith('XMozilla'));
  assert.ok(out.injectPayload.includes('Chrome/120.0'));
});

test('parseAnyConfigText returns null on junk', () => {
  assert.equal(parseAnyConfigText('hello world'), null);
  assert.equal(parseAnyConfigText(''), null);
});

test('tls v2ray config gets a uTLS fingerprint by default', () => {
  const c = normalizeConfig({
    protocol: 'vless',
    address: 'a.example.com',
    uuid: 'u',
    security: 'tls',
  });
  assert.equal(c.fingerprint, 'chrome');
  // Non-TLS must not get one.
  assert.equal(normalizeConfig({ protocol: 'vless', security: 'none' }).fingerprint, '');
});


// ---------------------------------------------------------------------------
// DarkTunnel SSL(TCP) VLESS — the exact user-reported link shape
// ---------------------------------------------------------------------------
test('darktunnel SSL(TCP) vless: no ws hijack, NO path/payload on TCP', () => {
  const link =
    'darktunnel://eyJ0eXBlIjoiVkxFU1MiLCJuYW1lIjoiU1NMLTg0NDMtVGVzdGVyIiwidmxlc3NUdW5uZWxDb25maWciOnsidjJyYXlDb25maWciOnsiaG9zdCI6InNneC50ZHotc2VydmVyLnN0b3JlIiwicG9ydCI6ODQ0MywidXVpZCI6IjYyNWQ5ZGUzLTI0ODAtNGY4NC1hMzNmLWQzMGQwOWZjZGJiYiIsInRyYW5zcG9ydE5ldHdvcmsiOiJUY3AiLCJzZXJ2ZXJOYW1lSW5kaWNhdGlvbiI6IkZhY2Vib29rLmNvbSIsIndzUGF0aCI6Ii9AVGVzdGVyIiwid3NIZWFkZXJIb3N0Ijoic2d4LnRkei1zZXJ2ZXIuc3RvcmUifSwiaW5qZWN0Q29uZmlnIjp7InBheWxvYWQiOiIifX19';
  const c = normalizeConfig({ rawContent: link });
  assert.equal(c.protocol, 'vless');
  assert.equal(c.name, 'SSL-8443-Tester');
  assert.equal(c.address, 'sgx.tdz-server.store');
  assert.equal(c.port, 8443);
  assert.equal(c.uuid, '625d9de3-2480-4f84-a33f-d30d09fcdbbb');
  assert.equal(c.transport, 'tcp', 'Tcp + stray wsPath must stay TCP');
  assert.equal(c.security, 'tls');
  assert.equal(c.sni, 'Facebook.com');
  assert.equal(c.host, 'sgx.tdz-server.store');
  // A TCP config with a path is an INVALID config — wsPath is ignored here.
  assert.equal(c.path, '');
  assert.equal(c.payload, '');
  assert.equal(c.injectMode, 'directSni');
  assert.equal(c.country, 'SG', 'country auto-detected from hostname');
  assert.equal(validateConfig(c).ok, true);
});

// ---------------------------------------------------------------------------
// DarkTunnel unlocked VLESS + WS with PROXY-mode injectConfig — the
// "all type not support" link shape (bug host in proxyHost, [crlf] payload).
// Mirrors test/darktunnel_import_test.dart.
// ---------------------------------------------------------------------------
const DT_WS_PROXY =
  'darktunnel://eyJ0eXBlIjoiVkxFU1MiLCJuYW1lIjoid3MgcHJveHkiLCJ2bGVzc1R1bm5lbENvbmZpZyI6eyJ2MnJheUNvbmZpZyI6eyJob3N0IjoiZmIuYmxvZ3Nwb3QuY29tIiwicG9ydCI6NDQzLCJ1dWlkIjoiYWFhYTExMTEtYmJiYi00Y2NjLThkZGQtZWVlZWZmZmYwMDAwIiwic2VydmVyTmFtZUluZGljYXRpb24iOiJmYi5ibG9nc3BvdC5jb20iLCJ3c1BhdGgiOiIvVGVsZWdyYW0vQEFNMl9EMyIsIndzSGVhZGVySG9zdCI6ImFkbWVpZC5ydW4uYXBwIn0sImluamVjdENvbmZpZyI6eyJlbmFibGVkIjp0cnVlLCJtb2RlIjoiUFJPWFkiLCJwcm94eUhvc3QiOiIxNTcuMjQwLjkuMzkiLCJwYXlsb2FkIjoiQ09OTkVDVCBbaG9zdF06W3BvcnRdIEhUVFAvMS4xW2NybGZdW2NybGZdIn19fQ';

test('darktunnel VLESS ws PROXY: front + payload survive the import', () => {
  const c = normalizeConfig({ rawContent: DT_WS_PROXY });
  assert.equal(c.protocol, 'vless');
  assert.equal(c.transport, 'ws', 'wsPath present => WS');
  assert.equal(c.path, '/Telegram/@AM2_D3');
  assert.equal(c.security, 'tls');
  assert.equal(c.injectHost, '157.240.9.39', 'proxyHost = bug front');
  assert.equal(c.injectMode, 'proxy');
  assert.match(c.payload, /CONNECT \[host\]:\[port\]/);
  assert.equal(validateConfig(c).ok, true);
});

test('darktunnel share with trailing comma (bulk paste) still imports', () => {
  const c = normalizeConfig({ rawContent: DT_WS_PROXY + ',' });
  assert.equal(c.address, 'fb.blogspot.com');
  assert.equal(c.injectHost, '157.240.9.39');
});

test('splitSubscription splits comma-joined darktunnel links', () => {
  const links = splitSubscription(`${DT_WS_PROXY},${DT_WS_PROXY}`);
  assert.equal(links.length, 2);
});

test('darktunnel LOCKED share is refused by the panel (app-only decrypt)', () => {
  const locked =
    'darktunnel://' +
    Buffer.from(
      JSON.stringify({
        type: 'VLESS',
        name: 'locked',
        vlessTunnelConfig: { v2rayConfig: { mux: true } },
        encryptedLockedConfig: 'AAAAAAAAAA',
      }),
    ).toString('base64url');
  assert.equal(parseAnyConfigText(locked), null);
});

test('parseAnyConfigText handles armantunnel:// (and legacy senseitunnel://)', () => {
  const cfg = {
    name: 'SG-Shared',
    protocol: 'vless',
    address: 'sg1.example.com',
    port: 443,
    transport: 'ws',
    security: 'tls',
    uuid: '11111111-2222-3333-4444-555555555555',
    sni: 'facebook.com',
    path: '/vless',
    host: 'sg1.example.com',
  };
  const b64 = btoa(JSON.stringify(cfg))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
  for (const scheme of ['armantunnel://', 'senseitunnel://']) {
    const link = scheme + b64;
    const parsed = parseAnyConfigText(link);
    assert.ok(parsed, scheme + ' link must parse');
    assert.equal(parsed.protocol, 'vless');
    assert.equal(parsed.address, 'sg1.example.com');
    assert.equal(parsed.uuid, '11111111-2222-3333-4444-555555555555');
    assert.equal(parsed.sni, 'facebook.com');
    // splitSubscription must also surface the link.
    const links = splitSubscription(link);
    assert.equal(links.length, 1);
    assert.equal(links[0], link);
  }
});

// ---------------------------------------------------------------------------
// Server entity + join (server-first flow: server owns endpoint/creds, config
// owns only the method; they meet at publish time)
// ---------------------------------------------------------------------------

test('normalizeServer keeps endpoint + creds, drops method fields', () => {
  const s = normalizeServer({
    name: 'RYZE Core',
    protocol: 'ssh',
    address: 'ryze.example.com',
    port: 22,
    sshUser: 'u',
    sshPass: 'p',
    // method-ish fields must NOT live on the server
    payload: 'GET / HTTP/1.1[crlf]',
    injectMode: 'directSni',
  });
  assert.equal(s.protocol, 'ssh');
  assert.equal(s.address, 'ryze.example.com');
  assert.equal(s.sshUser, 'u');
  assert.equal(s.id.startsWith('srv_'), true);
  assert.ok(!('payload' in s) || !s.payload);
  assert.ok(!s.injectMode);
  const v = validateServer(s);
  assert.equal(v.ok, true, JSON.stringify(v.errors));
});

test('validateServer still blocks a missing endpoint but not missing credentials', () => {
  // Credentials became optional on a proxy (2026-10-01): the panel must be
  // able to save a bare endpoint. The engine refuses at connect time instead.
  const noCreds = normalizeServer({ name: 'X', protocol: 'ssh', address: 'h', port: 22 });
  const ok = validateServer(noCreds);
  assert.equal(ok.ok, true, 'no username/password is a warning, not a blocker');
  assert.ok(ok.warnings.some((w) => w.field === 'sshUser'));

  // The endpoint itself is still required.
  const noAddr = normalizeServer({ name: 'X', protocol: 'ssh', port: 22 });
  const bad = validateServer(noAddr);
  assert.equal(bad.ok, false);
  assert.ok(bad.errors.some((e) => e.field === 'address'));
});

test('joinServerIntoConfig merges server endpoint with variant method', () => {
  const server = normalizeServer({
    id: 'srv_t1',
    name: 'RYZE Core',
    protocol: 'ssh',
    address: 'ryze.example.com',
    port: 22,
    sshUser: 'u',
    sshPass: 'p',
    category: 'gaming',
    country: 'SG',
  });
  const variant = normalizeConfig({
    id: 'cfg_v1',
    serverId: 'srv_t1',
    name: 'RYZE Payload',
    category: 'telegram',
    injectMode: 'directSni',
    sni: 'fbcdn.net',
    payload: 'GET / HTTP/1.1[crlf]Host: [host][crlf][crlf]',
  });
  const joined = joinServerIntoConfig(variant, [server]);
  // endpoint + creds from the server
  assert.equal(joined.address, 'ryze.example.com');
  assert.equal(joined.sshUser, 'u');
  // category is the METHOD's property — config wins over the server's
  assert.equal(joined.category, 'telegram');
  // method from the variant
  assert.equal(joined.injectMode, 'directSni');
  assert.equal(joined.sni, 'fbcdn.net');
  assert.equal(joined.payload, 'GET / HTTP/1.1[crlf]Host: [host][crlf][crlf]');
  // display: variant name, server label
  assert.equal(joined.name, 'RYZE Payload');
  assert.equal(joined.server, 'RYZE Core');
  // validates as a full config once joined
  const v = validateConfig(joined);
  assert.equal(v.ok, true, JSON.stringify(v.errors));
  // and produces a sane app payload
  const app = toAppConfig(joined);
  assert.equal(app.address, 'ryze.example.com');
  assert.equal(app.sshPass, 'p');
});

test('normalizeServer KEEPS the WS path (regression: silently dropped once)', () => {
  const s = normalizeServer({
    name: 'WS host', protocol: 'vless', transport: 'ws', security: 'none',
    address: 'ws.example.com', port: 480, uuid: '00000000-0000-0000-0000-000000000000',
    path: '/@user', host: 'ws.example.com',
  });
  assert.equal(s.path, '/@user');
  // and it must survive the join into a tweak
  const tweak = normalizeConfig({ name: 'T', serverId: s.id, payload: 'GET x' });
  const joined = joinServerIntoConfig({ ...tweak, serverId: s.id }, [s]);
  assert.equal(joined.path, '/@user');
  // a tweak-level override wins
  const joined2 = joinServerIntoConfig({ ...tweak, serverId: s.id, path: '/other' }, [s]);
  assert.equal(joined2.path, '/other');
});

test('joinServerIntoConfig leaves legacy configs untouched', () => {
  const legacy = normalizeConfig({
    name: 'Old standalone',
    protocol: 'vless',
    address: 'old.example.com',
    port: 443,
    uuid: '00000000-0000-0000-0000-000000000000',
  });
  const out = joinServerIntoConfig(legacy, []);
  assert.deepEqual(out, legacy);
  assert.equal(out.serverId, '');
});

test('joinServerIntoConfig with a deleted server falls back to raw config', () => {
  const variant = normalizeConfig({ name: 'V', serverId: 'srv_gone' });
  const out = joinServerIntoConfig(variant, []);
  assert.equal(out, variant);
});

// ---------------------------------------------------------------------------
// Categories (Tweaks categories → the app's Configs menu sections)
// ---------------------------------------------------------------------------

test('normalizeCategoryEntity: name + optional country, earth flag when blank', () => {
  const c = normalizeCategoryEntity({ name: '  Normal   Internet ', countryCode: 'sg' });
  assert.equal(c.name, 'Normal Internet');
  assert.equal(c.country, 'SG');
  assert.ok(c.id.startsWith('cat_'));
  const earth = normalizeCategoryEntity({ name: 'Bangabandhu Tweaks' });
  assert.equal(earth.country, '');
});

test('validateCategoryEntity: requires a name, ISO-2 country only', () => {
  assert.equal(validateCategoryEntity(normalizeCategoryEntity({ name: 'X' })).ok, true);
  assert.equal(validateCategoryEntity(normalizeCategoryEntity({ name: '' })).ok, false);
  assert.equal(
    validateCategoryEntity(normalizeCategoryEntity({ name: 'X', country: 'SGP' })).ok,
    false,
  );
});

test('normalizeCategoryEntity clamps runaway names', () => {
  const c = normalizeCategoryEntity({ name: 'A'.repeat(200) });
  assert.equal(c.name.length, 48);
});

test('configs keep free-form category names, legacy enums stay lowercase', () => {
  const free = normalizeConfig({
    name: 'T1', protocol: 'vless', address: 'a.example.com', port: 443,
    uuid: '00000000-0000-0000-0000-000000000000',
    category: 'Normal Internet',
  });
  assert.equal(free.category, 'Normal Internet');

  const legacy = normalizeConfig({
    name: 'T2', protocol: 'vless', address: 'b.example.com', port: 443,
    uuid: '00000000-0000-0000-0000-000000000000',
    category: 'GAMING',
  });
  assert.equal(legacy.category, 'gaming');

  const blank = normalizeConfig({
    name: 'T3', protocol: 'vless', address: 'c.example.com', port: 443,
    uuid: '00000000-0000-0000-0000-000000000000',
  });
  assert.equal(blank.category, 'global');
});

test('a 2-letter non-enum category is still treated as a legacy country code', () => {
  const c = normalizeConfig({
    name: 'T4', protocol: 'vless', address: 'd.example.com', port: 443,
    uuid: '00000000-0000-0000-0000-000000000000',
    category: 'sg',
  });
  assert.equal(c.category, 'global');
  assert.equal(c.country, 'SG');
});

test('normalizeCategoryName/Value basics', () => {
  assert.equal(normalizeCategoryName('  hi \n there \t! '), 'hi there !');
  assert.equal(normalizeCategoryValue(''), 'global');
  assert.equal(normalizeCategoryValue('Facebook'), 'facebook');
  assert.equal(normalizeCategoryValue('My Custom Plan'), 'My Custom Plan');
});

test('a bare tweak (no payload/SNI) validates with only a warning', () => {
  const tweak = normalizeConfig({
    name: 'Plain IP change', serverId: 'srv_1', category: 'Normal Internet',
  });
  // serverId set → variant validation; bare tweak must be ok (warning only).
  const v = validateVariantConfig(tweak);
  assert.equal(v.ok, true);
  assert.ok(v.warnings.some((w) => /adds nothing/.test(w.message)));
});

// ---------------------------------------------------------------------------
// Hosted logo URLs (imgbb image DB)
// ---------------------------------------------------------------------------

test('logoUrl survives normalizeServer + the publish projection', () => {
  const s = normalizeServer({
    name: 'Robi Core', protocol: 'ssh', address: 'r.example.com', port: 22,
    sshUser: 'u', sshPass: 'p', country: 'BD',
    logoUrl: 'https://i.ibb.co/xxxxx/robi.png',
  });
  assert.equal(s.logoUrl, 'https://i.ibb.co/xxxxx/robi.png');
  // and lands in the app-facing node
  const tweak = normalizeConfig({ name: 'Robi 0TK', serverId: s.id, payload: 'GET x' });
  const joined = joinServerIntoConfig({ ...tweak, serverId: s.id }, [s]);
  assert.equal(joined.logoUrl, 'https://i.ibb.co/xxxxx/robi.png');
  const app = toAppConfig(joined);
  assert.equal(app.logoUrl, 'https://i.ibb.co/xxxxx/robi.png');
});

test('config-level logoUrl is kept and can be overridden by the server', () => {
  const c = normalizeConfig({
    name: 'Standalone', protocol: 'vless', address: 'a.example.com',
    uuid: '00000000-0000-0000-0000-000000000000',
    logoUrl: 'https://i.ibb.co/yyyyy/logo.png',
  });
  assert.equal(c.logoUrl, 'https://i.ibb.co/yyyyy/logo.png');
  const app = toAppConfig(c);
  assert.equal(app.logoUrl, 'https://i.ibb.co/yyyyy/logo.png');

  // a tweak-level logo wins (per-method branding), the server's is fallback
  const s = normalizeServer({
    name: 'Srv', protocol: 'ssh', address: 's.example.com', port: 22,
    sshUser: 'u', sshPass: 'p',
    logoUrl: 'https://i.ibb.co/zzzzz/srv.png',
  });
  const joined = joinServerIntoConfig({ ...c, serverId: s.id }, [s]);
  assert.equal(joined.logoUrl, 'https://i.ibb.co/yyyyy/logo.png');
  // blank tweak logo → the server's branding applies
  const joinedNoLogo = joinServerIntoConfig(
    { ...c, serverId: s.id, logoUrl: '' }, [s]);
  assert.equal(joinedNoLogo.logoUrl, 'https://i.ibb.co/zzzzz/srv.png');
});

test('blank/missing logoUrl normalizes to empty string (never undefined)', () => {
  const s = normalizeServer({ name: 'X', protocol: 'ssh', address: 'x.example.com', port: 22, sshUser: 'u', sshPass: 'p' });
  assert.equal(s.logoUrl, '');
  const c = normalizeConfig({ name: 'Y', protocol: 'vless', address: 'y.example.com', uuid: '00000000-0000-0000-0000-000000000000' });
  assert.equal(c.logoUrl, '');
});

// ---------------------------------------------------------------------------
// Capability types — the Server ↔ Tweak compatibility system
// ---------------------------------------------------------------------------

test('server capabilities: tweak joins with every compatible server, anchor first', () => {
  const mk = (id, name, caps, prio) => normalizeServer({
    id, name, protocol: 'ssh', address: `${id}.example.com`, port: 22,
    sshUser: 'u', sshPass: 'p', capabilities: caps, priority: prio || 0,
  });
  const a = mk('srv_a', 'Server A', ['INJECTED', 'SNI', 'PROXY+PAYLOAD']);
  const b = mk('srv_b', 'Server B', ['SNI']);
  const c = mk('srv_c', 'Server C', ['PROXY+PAYLOAD', 'CLOUDFLARE-PROXY-PAYLOAD']);
  const servers = [a, b, c];

  // A tweak of type [SNI] — no serverId at all.
  const tweak = normalizeConfig({
    name: 'SG SNI tweak', capability: 'SNI', family: 'ssh',
    category: 'telegram', sni: 'fbcdn.net',
  });
  const joined = joinServerIntoConfig(tweak, servers);
  // anchor = first compatible (Server A), pool = the rest (Server B)
  assert.equal(joined.address, 'srv_a.example.com');
  assert.equal(joined.serverPool.length, 1);
  assert.equal(joined.serverPool[0].address, 'srv_b.example.com');
  assert.equal(joined.serverPool[0].sshUser, 'u');
  // incompatible servers never appear
  assert.ok(!joined.serverPool.some((p) => p.address === 'srv_c.example.com'));
});

test('legacy serverId stays the preferred anchor when compatible', () => {
  const a = normalizeServer({ id: 'srv_a', name: 'A', protocol: 'ssh', address: 'a.example.com', port: 22, sshUser: 'u', sshPass: 'p', capabilities: ['SNI'] });
  const b = normalizeServer({ id: 'srv_b', name: 'B', protocol: 'ssh', address: 'b.example.com', port: 22, sshUser: 'u', sshPass: 'p', capabilities: ['SNI'] });
  const tweak = normalizeConfig({
    name: 'T', serverId: 'srv_b', capability: 'SNI', family: 'ssh', category: 'global',
  });
  const joined = joinServerIntoConfig(tweak, [a, b]);
  assert.equal(joined.address, 'b.example.com');       // legacy preference wins
  assert.equal(joined.serverPool[0].address, 'a.example.com'); // rest follow
});

test('serverIds allow-list limits the tweak failover pool', () => {
  const a = normalizeServer({ id: 'srv_a', name: 'A', protocol: 'ssh', address: 'a.example.com', port: 22, sshUser: 'u', sshPass: 'p', capabilities: ['SNI'] });
  const b = normalizeServer({ id: 'srv_b', name: 'B', protocol: 'ssh', address: 'b.example.com', port: 22, sshUser: 'u', sshPass: 'p', capabilities: ['SNI'] });
  const c = normalizeServer({ id: 'srv_c', name: 'C', protocol: 'ssh', address: 'c.example.com', port: 22, sshUser: 'u', sshPass: 'p', capabilities: ['SNI'] });
  const tweak = normalizeConfig({
    name: 'T', capability: 'SNI', family: 'ssh', serverIds: ['srv_b', 'srv_c'], category: 'global',
  });
  const joined = joinServerIntoConfig(tweak, [a, b, c]);
  assert.equal(joined.address, 'b.example.com');
  assert.equal(joined.serverPool.length, 1);
  assert.equal(joined.serverPool[0].address, 'c.example.com');
});

test('protocol family must match for compatibility', () => {
  const sshSrv = normalizeServer({ name: 'S', protocol: 'ssh', address: 's.example.com', port: 22, sshUser: 'u', sshPass: 'p', capabilities: ['SNI'] });
  const tweak = normalizeConfig({ name: 'T', capability: 'SNI', family: 'v2ray', category: 'global' });
  const joined = joinServerIntoConfig(tweak, [sshSrv]);
  // an ssh server can't carry a v2ray tweak — nothing was joined over the
  // tweak (address stays the tweak's own blank, no server fields applied)
  assert.equal(joined.address, '');
  assert.equal(joined.serverPool, undefined);
  assert.equal(joined.uuid, '');
});

test('inferCapability maps legacy method fields to types', () => {
  assert.equal(inferCapability({ injectMode: 'proxySni', payload: 'GET x' }), 'PROXY+PAYLOAD');
  assert.equal(inferCapability({ injectMode: 'proxy' }), 'PROXY');
  assert.equal(inferCapability({ injectMode: 'directSni', payload: 'GET x' }), 'INJECTED');
  assert.equal(inferCapability({ injectMode: 'directSni' }), 'SNI');
  assert.equal(inferCapability({ injectMode: 'direct', payload: 'GET x' }), 'INJECTED');
  assert.equal(inferCapability({ injectMode: 'direct' }), 'SSL');
  assert.equal(inferCapability({ dnsttServer: 'ns.example.com' }), 'DNSTT');
  assert.equal(inferCapability({ injectMode: 'none' }), 'DIRECT');
});

test('validateVariantConfig: capability OR legacy serverId, pool must exist', () => {
  const srv = normalizeServer({ name: 'S', protocol: 'ssh', address: 's.example.com', port: 22, sshUser: 'u', sshPass: 'p', capabilities: ['SNI'] });
  // no capability and no serverId → error
  let v = validateVariantConfig({ name: 'T' }, [srv]);
  assert.ok(v.errors.some((e) => e.field === 'capability'));
  // capability with no supporting server → error
  v = validateVariantConfig({ name: 'T', capability: 'HTTP', family: 'ssh' }, [srv]);
  assert.ok(v.errors.some((e) => /No server supports/.test(e.message)));
  // supported capability → ok
  v = validateVariantConfig({ name: 'T', capability: 'SNI', family: 'ssh' }, [srv]);
  assert.equal(v.ok, true);
});

test('capability type entity normalize + validate round-trips', () => {
  const t = normalizeCapabilityType({ name: ' robi payload ', description: 'x' });
  assert.equal(t.name, 'ROBI_PAYLOAD');
  assert.equal(t.enabled, true);
  assert.equal(validateCapabilityType(t).ok, true);
  assert.equal(validateCapabilityType(normalizeCapabilityType({ name: 'x' })).ok, false);
});

test('default capability descriptions explain app-visible tweak types', () => {
  assert.equal(DEFAULT_CAPABILITY_DESCRIPTIONS.SNI, 'SNI only');
  assert.match(DEFAULT_CAPABILITY_DESCRIPTIONS['CLOUDFLARE-PROXY-PAYLOAD'], /Cloudflare/);
});

test('family mixed: the tweak rides compatible servers of EVERY engine', () => {
  const ssh = normalizeServer({ id: 'a', name: 'A', protocol: 'ssh', address: 'a.example.com', port: 22, sshUser: 'u', sshPass: 'p', capabilities: ['SNI'] });
  const vless = normalizeServer({ id: 'b', name: 'B', protocol: 'vless', address: 'b.example.com', port: 443, uuid: '00000000-0000-0000-0000-000000000000', capabilities: ['SNI'] });
  const ovpn = normalizeServer({ id: 'c', name: 'C', protocol: 'openvpn', ovpnConfig: 'client\nremote c.example.com 443\nproto tcp\n', capabilities: ['SNI'] });
  const tweak = normalizeConfig({ name: 'M', capability: 'SNI', family: 'mixed', category: 'global' });
  const joined = joinServerIntoConfig(tweak, [ssh, vless, ovpn]);
  // anchor = first compatible (ssh here), pool carries BOTH other engines
  assert.equal(joined.address, 'a.example.com');
  assert.equal(joined.serverPool.length, 2);
  const poolProto = joined.serverPool.map((e) => e.protocol).sort();
  assert.deepEqual(poolProto, ['openvpn', 'vless']);
  // a family-locked tweak still sees only its own engine
  const locked = joinServerIntoConfig(
    normalizeConfig({ name: 'L', capability: 'SNI', family: 'ssh', category: 'global' }),
    [ssh, vless, ovpn]);
  assert.equal(locked.address, 'a.example.com');
  assert.equal(locked.serverPool.length, 0);
});

test('toAppConfig carries capability + serverPool', () => {
  const joined = joinServerIntoConfig(
    normalizeConfig({ name: 'T', capability: 'SNI', family: 'ssh', category: 'global', sni: 'fbcdn.net' }),
    [
      normalizeServer({ id: 'a', name: 'A', protocol: 'ssh', address: 'a.example.com', port: 22, sshUser: 'u', sshPass: 'p', capabilities: ['SNI'] }),
      normalizeServer({ id: 'b', name: 'B', protocol: 'ssh', address: 'b.example.com', port: 22, sshUser: 'u', sshPass: 'p', capabilities: ['SNI'] }),
    ],
  );
  const app = toAppConfig(joined);
  assert.equal(app.capability, 'SNI');
  assert.equal(app.serverPool.length, 1);
  assert.equal(app.serverPool[0].name, 'B');
});

test('toAppConfig redacts a vaulted VIP endpoint and publishes the vault id', () => {
  const base = {
    name: 'VIP', protocol: 'vless', transport: 'ws', security: 'tls',
    address: 'secret.example.com', port: 443, sni: 'fbcdn.net',
    category: 'global', vip: true, vipUnlockHours: 2,
  };
  // vault === id: opted into the server-side endpoint vault.
  const vaulted = toAppConfig(normalizeConfig({ ...base, id: 'vip-1', vault: 'vip-1' }));
  assert.equal(vaulted.vault, 'vip-1', 'the app must learn the vault id');
  assert.equal(vaulted.address, '', 'the real address must NOT reach the bundle');
  assert.equal(vaulted.port, 0, 'the real port must NOT reach the bundle');
  assert.equal(vaulted.vip, true);
  // A vaulted config keeps its share-front fields — the endpoint is the only
  // thing withheld, so a VLESS/WS shape still renders.
  assert.equal(vaulted.sni, 'fbcdn.net');
  assert.equal(vaulted.protocol, 'vless');

  // Not opted in (vault blank): publishes the endpoint as before.
  const plain = toAppConfig(normalizeConfig({ ...base, id: 'vip-2' }));
  assert.equal(plain.vault, '');
  assert.equal(plain.address, 'secret.example.com');
  assert.equal(plain.port, 443);

  // vault set but NOT vip: never redacted (only VIP endpoints are vaulted).
  const nonVip = toAppConfig(normalizeConfig({ ...base, id: 'x', vault: 'x', vip: false }));
  assert.equal(nonVip.vault, '');
  assert.equal(nonVip.address, 'secret.example.com');
});

test('toAppConfig withholds the injection front and failover pool for a vaulted VIP', () => {
  // The bug/squid host and every pool entry are ENDPOINTS too — redacting only
  // address/port left the whole server reachable from the public bundle.
  // The pool is a JOIN-time field, so build it the way publish does.
  const tweak = normalizeConfig({
    name: 'VIP', capability: 'SNI', transport: 'ws', security: 'tls',
    injectMode: 'proxy', injectHost: 'front.example.com', injectPort: '80',
    category: 'global', vip: true, vault: 'v1', id: 'v1',
  });
  const s1 = normalizeServer({
    name: 'S1', address: 'secret1.example.com', port: 443, capabilities: ['SNI'],
  });
  const s2 = normalizeServer({
    name: 'S2', address: 'secret2.example.com', port: 443, capabilities: ['SNI'],
  });
  const joined = joinServerIntoConfig({ ...tweak, serverId: s1.id }, [s1, s2]);
  assert.equal(joined.serverPool.length, 1, 'the join must actually build a pool');
  assert.equal(joined.serverPool[0].address, 'secret2.example.com');

  const vaulted = toAppConfig(joined);
  assert.equal(vaulted.vault, 'v1');
  assert.equal(vaulted.address, '');
  assert.equal(vaulted.port, 0);
  assert.equal(vaulted.injectHost, '', 'the injection front host is an endpoint');
  assert.equal(vaulted.injectPort, '', 'the injection front port is an endpoint');
  assert.deepEqual(vaulted.serverPool, [], 'pool entries carry their own address/port');
  // The inject MODE stays so the card/UI still knows the shape.
  assert.equal(vaulted.injectMode, 'proxy');

  // Same tweak, not opted into the vault: everything publishes as before.
  const plain = toAppConfig(joinServerIntoConfig({ ...tweak, vault: '' }, [s1, s2]));
  assert.equal(plain.address, 'secret1.example.com');
  assert.equal(plain.injectHost, 'front.example.com');
  assert.equal(plain.injectPort, '80');
  assert.equal(plain.serverPool.length, 1);
  assert.equal(plain.serverPool[0].address, 'secret2.example.com');
});

test('a proxy publishes as its own app node with no tweak riding it', () => {
  // The whole point: a proxy used to be invisible until someone wrote a tweak
  // that rode it (compatibleServersFor matches on capabilities). It must now
  // reach the app as a normal node on its own.
  const s = normalizeServer({
    name: 'Robi Proxy', protocol: 'ssh', address: 'robi.example.com', port: 22,
    sshUser: 'u', sshPass: 'p', category: 'Normal Internet', country: 'BD',
  });
  const raw = serverToAppConfig(s);
  assert.equal(raw.id, s.id, 'the node keeps the server id');
  assert.equal(raw.name, 'Robi Proxy');
  assert.equal(raw.protocol, 'ssh');
  assert.equal(raw.address, 'robi.example.com');
  assert.equal(raw.port, 22);
  assert.equal(raw.sshUser, 'u', 'credentials travel with the node');
  assert.equal(raw.category, 'Normal Internet');
  assert.equal(raw.country, 'BD');
  // A bare proxy is a plain connection — no tweak method on it.
  assert.equal(raw.capability, 'DIRECT');
  assert.equal(raw.vip, false);
  assert.equal(raw.vault, '');

  // And it survives the publish projection (the resolve route needs the RAW
  // address, so the projection must not redact a non-vaulted proxy).
  const node = toAppConfig(raw);
  assert.equal(node.address, 'robi.example.com');
  assert.equal(node.port, 22);
  assert.equal(node.sshUser, 'u');
  assert.equal(node.capability, 'DIRECT');
  assert.equal(node.vault, '');
  // A standalone proxy IS one endpoint — no failover pool of its own. (A tweak
  // riding several servers still gets its pool from the join.)
  assert.deepEqual(node.serverPool, []);
});

test('a VIP proxy carries its own VIP gate and unlock hours', () => {
  const s = normalizeServer({
    name: 'VIP Proxy', protocol: 'vless', address: 'vip.example.com', port: 443,
    uuid: 'u-1', vip: true, vipUnlockHours: 2, capabilities: ['SNI'],
  });
  const node = toAppConfig(serverToAppConfig(s));
  assert.equal(node.vip, true, 'the ad gate must reach the node');
  assert.equal(node.vipUnlockHours, 2);
  // capabilities on the server are what TWEAKS may ride — the standalone node
  // is not itself a tweak, so it must not claim a tweak type.
  assert.equal(node.capability, 'DIRECT');
});

test('a vaulted VIP proxy withholds its endpoint from the bundle', () => {
  const s = normalizeServer({
    name: 'Secret', protocol: 'vless', address: 'secret.example.com', port: 443,
    uuid: 'u-1', vip: true, vault: 'on',
    injectHost: 'front.example.com', injectPort: '80',
  });
  // The resolve route reads the RAW node, so the endpoint must still be there
  // for it — only the published projection hides it.
  assert.equal(serverToAppConfig(s).address, 'secret.example.com');

  const node = toAppConfig(serverToAppConfig(s));
  assert.equal(node.address, '');
  assert.equal(node.port, 0);
  assert.equal(node.injectHost, '');
  assert.equal(node.injectPort, '');
  assert.equal(node.vault, s.id, 'the app resolves the endpoint by the server id');
  assert.equal(node.uuid, 'u-1', 'credentials still publish (not an endpoint)');
});

test('ssh credentials are optional on a proxy (warn, not block)', () => {
  const bare = normalizeServer({ name: 'Bare SSH', protocol: 'ssh', address: 'a.example.com', port: 22 });
  const v = validateServer(bare);
  assert.equal(v.ok, true, 'a proxy without user/pass must still save');
  assert.deepEqual(v.errors, [], 'optional means no error');
  assert.ok(v.warnings.some((w) => w.field === 'sshUser'), 'warn that it will not connect');
  assert.ok(v.warnings.some((w) => w.field === 'sshPass'));
  // Other required fields stay required.
  const noAddr = validateServer(normalizeServer({ name: 'x', protocol: 'vless', port: 443 }));
  assert.equal(noAddr.ok, false);
  assert.ok(noAddr.errors.some((e) => e.field === 'address'));
});

test('parseAnyConfigText handles hy2:// (Hysteria 2 link)', () => {
  const p = parseAnyConfigText('hy2://tok123@hy.example.com:8443?sni=cdn.example.com#Fast HY');
  assert.equal(p.protocol, 'hysteria');
  assert.equal(p.address, 'hy.example.com');
  assert.equal(p.port, 8443);
  assert.equal(p.password, 'tok123');
  assert.equal(p.sni, 'cdn.example.com');
  assert.equal(p.security, 'tls');
  assert.equal(p.name, 'Fast HY');
  // insecure=1 → the app's accept-any-cert mode.
  const bad = parseAnyConfigText('hysteria2://@hy.example.com?insecure=1');
  assert.equal(bad.security, 'none');
  assert.equal(bad.port, 443);
});

test('parseAnyConfigText handles a raw WireGuard .conf body', () => {
  const conf = [
    '[Interface]',
    'PrivateKey = aC2xY3EXAMPLE=',
    'Address = 10.66.0.2/32',
    '',
    '[Peer]',
    'PublicKey = q9EXAMPLEkey=',
    'AllowedIPs = 0.0.0.0/0',
    'Endpoint = 5.6.7.8:51820',
  ].join('\n');
  const p = parseAnyConfigText(conf);
  assert.equal(p.protocol, 'wireguard');
  assert.equal(p.wireguardConfig, conf);
  assert.equal(p.address, '5.6.7.8');
  assert.equal(p.port, 51820);
  const v = validateServer(p);
  assert.equal(v.ok, true, 'parsed wg conf must pass server validation');
});

console.log(`config-schema: ${passed} tests passed`);
