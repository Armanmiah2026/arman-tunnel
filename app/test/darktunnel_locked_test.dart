import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sensei_tunnel/models/server_config.dart';
import 'package:sensei_tunnel/services/config_service.dart';
import 'package:sensei_tunnel/utils/darktunnel_codec.dart';

Uint8List _h(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ]);

String _fixture(String name) =>
    File('test/fixtures/$name').readAsStringSync().trim();

ServerConfig _vless({
  String name = 'Test VLESS',
  String address = 'vless.example.com',
  int port = 443,
  String uuid = '11111111-2222-3333-4444-555555555555',
  TransportType transport = TransportType.ws,
  SecurityType security = SecurityType.tls,
  String? sni = 'sni.example.com',
  String? path = '/ws',
  String? host = 'cdn.example.com',
}) =>
    ServerConfig(
      id: '1',
      name: name,
      protocol: ProtocolType.vless,
      transport: transport,
      security: security,
      address: address,
      port: port,
      uuid: uuid,
      sni: sni,
      path: path,
      host: host,
      isCustom: true,
    );

void main() {
  // ── Crypto known-answer vectors ──────────────────────────────────────

  test('sha256 known vectors', () {
    expect(sha256Hex(''),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    expect(sha256Hex('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  });

  test('AES ECB FIPS-197 C.1 (AES-128)', () {
    expect(
      aesEncryptBlockForTest(
        _h('000102030405060708090a0b0c0d0e0f'),
        _h('00112233445566778899aabbccddeeff'),
      ),
      _h('69c4e0d86a7b0430d8cdb78070b4c55a'),
    );
  });

  test('AES ECB FIPS-197 C.2 (AES-192 — the INNER key size)', () {
    expect(
      aesEncryptBlockForTest(
        _h('000102030405060708090a0b0c0d0e0f1011121314151617'),
        _h('00112233445566778899aabbccddeeff'),
      ),
      _h('dda97ca4864cdfe06eaf70a0ec0d7191'),
    );
  });

  test('AES ECB FIPS-197 C.3 (AES-256 — the OUTER key size)', () {
    expect(
      aesEncryptBlockForTest(
        _h('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'),
        _h('00112233445566778899aabbccddeeff'),
      ),
      _h('8ea2b7ca516745bfeafc49904b496089'),
    );
  });

  test('AES-128 CFB128 SP 800-38A first block', () {
    expect(
      aesCfb128(
        _h('2b7e151628aed2a6abf7158809cf4f3c'),
        _h('000102030405060708090a0b0c0d0e0f'),
        _h('6bc1bee22e409f96e93d7e117393172a'),
      ),
      _h('3b3fd92eb72dad20333449f8e83cfb4a'),
    );
  });

  test('AES-CFB handles partial final blocks (stream property)', () {
    final key = _h('000102030405060708090a0b0c0d0e0f');
    final iv = _h('101112131415161718191a1b1c1d1e1f');
    for (final len in [1, 15, 16, 17, 33, 100]) {
      final pt = Uint8List.fromList(List.generate(len, (i) => i * 7 % 256));
      final ct = aesCfb128(key, iv, pt);
      expect(ct.length, len);
      expect(aesCfb128(key, iv, ct, decrypt: true), pt);
    }
  });

  test('msgpack round trip', () {
    final packed = msgpackPack({
      'str': 'hello',
      'big': 0x1234567890,
      'neg': -1234,
      'flag': true,
      'nil': null,
      'bin': Uint8List.fromList([1, 2, 3, 250]),
      'list': [1, 'two', false],
      'nested': {'a': 'b'},
    });
    final m = msgpackUnpack(packed) as Map;
    expect(m['str'], 'hello');
    expect(m['big'], 0x1234567890);
    expect(m['neg'], -1234);
    expect(m['flag'], true);
    expect(m['nil'], null);
    expect(m['bin'], Uint8List.fromList([1, 2, 3, 250]));
    expect(m['list'], [1, 'two', false]);
    expect(m['nested'], {'a': 'b'});
  });

  // ── Real-world locked .dark files (from the DarkTunnel ecosystem) ────

  test('real locked VLESS (SSL/TCP) decodes and imports', () {
    final uri = _fixture('vless-locked-tcp-ssl.dark');
    final lock = DarkTunnelCodec.decode(uri);
    expect(lock, isNotNull);
    expect(lock!.tunnelType, 'VLESS');
    expect(lock.passwordRequired, isFalse); // app-default no-password marker
    expect(lock.message, isNotEmpty);

    final c = ServerConfig.fromDarkTunnelUri(uri);
    expect(c, isNotNull);
    expect(c!.protocol, ProtocolType.vless);
    expect(c.transport, TransportType.tcp);
    expect(c.security, SecurityType.tls);
    expect(c.address, isNotEmpty); // fixture endpoint
    expect(c.port, 2299);
    expect(c.uuid, '38b6f93a-03bd-4acc-8763-8289de4e5dbd');
    expect(c.sni, 'fbcdn.net');
    // The original share text rides along for re-sharing.
    expect(c.rawConfig, uri);
    expect(c.locked, isFalse); // decrypted → fully usable/editable
  });

  test('real locked VMESS (ws) decodes and imports', () {
    final c = ServerConfig.fromDarkTunnelUri(_fixture('vmess-locked-ws.dark'));
    expect(c, isNotNull);
    expect(c!.protocol, ProtocolType.vmess);
    expect(c.transport, TransportType.ws);
    expect(c.security, SecurityType.none);
    expect(c.address, 'id-ctn.skartistore.site');
    expect(c.port, 80);
    expect(c.uuid, 'bb3df399-9077-4e62-8493-ae773c5c60b7');
    expect(c.path, '/vmess');
    expect(c.host, 'youtube.com');
  });

  test('real locked SSH (DIRECT_SNI) decodes and imports', () {
    final uri = _fixture('ssh-locked.dark');
    final c = ServerConfig.fromDarkTunnelUri(uri);
    expect(c, isNotNull);
    expect(c!.protocol, ProtocolType.ssh);
    expect(c.transport, TransportType.tcp);
    expect(c.address, 'sg69.bdloser.xyz');
    expect(c.port, 443);
    expect(c.sshUser, 'tanvir');
    expect(c.sshPass, '123');
    expect(c.injectMode, InjectMode.directSni);
    expect(c.sni, 'tsports.com');
    expect(c.rawConfig, uri);
  });

  test('real locked TROJAN (ws+tls) decodes and imports', () {
    final c = ServerConfig.fromDarkTunnelUri(_fixture('trojan-locked.dark'));
    expect(c, isNotNull);
    expect(c!.protocol, ProtocolType.trojan);
    expect(c.transport, TransportType.ws);
    expect(c.security, SecurityType.tls);
    expect(c.address, 'sg69.zone.id');
    expect(c.port, 443);
    expect(c.uuid, '387bff4e-8e35-4bc4-a931-ff2bd963c3b0'); // trojan password
    expect(c.password, '387bff4e-8e35-4bc4-a931-ff2bd963c3b0');
    expect(c.sni, 'upload.youtube.com');
    expect(c.path, '/whatever/trojan-ws');
    expect(c.host, 'sg69.zone.id');
  });

  // ── Export round trips (our encoder → our decoder) ───────────────────

  test('vless ws+tls round trips through a locked .dark', () {
    final src = _vless();
    final uri = src.toDarkTunnelLockedUri(
      password: 'pw1',
      message: '<b>hello</b>',
    );
    expect(uri, isNotNull);
    expect(isPinLockedText(uri!), isTrue);

    final back = ServerConfig.fromDarkTunnelUri(uri, lockPin: 'pw1');
    expect(back, isNotNull);
    expect(back!.protocol, ProtocolType.vless);
    expect(back.transport, TransportType.ws);
    expect(back.security, SecurityType.tls);
    expect(back.address, 'vless.example.com');
    expect(back.port, 443);
    expect(back.uuid, '11111111-2222-3333-4444-555555555555');
    expect(back.sni, 'sni.example.com');
    expect(back.path, '/ws');
    expect(back.host, 'cdn.example.com');
    expect(back.lockMessage, '<b>hello</b>');
  });

  test('vmess tcp round trips', () {
    const src = ServerConfig(
      id: '2',
      name: 'VM TCP',
      protocol: ProtocolType.vmess,
      transport: TransportType.tcp,
      security: SecurityType.none,
      address: 'vm.example.com',
      port: 8080,
      uuid: '99999999-8888-7777-6666-555555555555',
      isCustom: true,
    );
    final back = ServerConfig.fromDarkTunnelUri(src.toDarkTunnelLockedUri()!)!;
    expect(back.protocol, ProtocolType.vmess);
    expect(back.transport, TransportType.tcp);
    expect(back.address, 'vm.example.com');
    expect(back.port, 8080);
    expect(back.uuid, '99999999-8888-7777-6666-555555555555');
  });

  test('ssh with payload+SNI round trips', () {
    const src = ServerConfig(
      id: '3',
      name: 'SSH PAY',
      protocol: ProtocolType.ssh,
      transport: TransportType.tcp,
      security: SecurityType.none,
      address: 'ssh.example.com',
      port: 80,
      sshUser: 'u9',
      sshPass: 'p9',
      sni: 'zero.example.com',
      payload: 'GET / HTTP/1.1[crlf]Host: zero.example.com[crlf][crlf]',
      injectMode: InjectMode.direct,
      isCustom: true,
    );
    final back = ServerConfig.fromDarkTunnelUri(src.toDarkTunnelLockedUri()!)!;
    expect(back.protocol, ProtocolType.ssh);
    expect(back.address, 'ssh.example.com');
    expect(back.port, 80);
    expect(back.sshUser, 'u9');
    expect(back.sshPass, 'p9');
    expect(back.sni, 'zero.example.com');
    expect(back.payload, 'GET / HTTP/1.1[crlf]Host: zero.example.com[crlf][crlf]');
  });

  test('ssh-dnstt round trips', () {
    const src = ServerConfig(
      id: '4',
      name: 'SlowDNS',
      protocol: ProtocolType.sshDnstt,
      transport: TransportType.tcp,
      security: SecurityType.none,
      address: 'dns.example.com',
      port: 22,
      sshUser: 'duser',
      sshPass: 'dpass',
      dnsttServer: 'dnstt.example.com',
      dnsttKey: 'pubkey123',
      dnsttResolver: '8.8.8.8:5353',
      injectMode: InjectMode.dnstt,
      isCustom: true,
    );
    final uri = src.toDarkTunnelLockedUri()!;
    final back = ServerConfig.fromDarkTunnelUri(uri)!;
    expect(back.protocol, ProtocolType.sshDnstt);
    expect(back.address, 'dns.example.com');
    expect(back.sshUser, 'duser');
    expect(back.dnsttServer, 'dnstt.example.com');
    expect(back.dnsttKey, 'pubkey123');
    // The format stores host and port separately; a non-default port is
    // recombined on import, the default 53 collapses to a bare host.
    expect(back.dnsttResolver, '8.8.8.8:5353');
    expect(
      ServerConfig.fromDarkTunnelUri(
        src.copyWith(dnsttResolver: '8.8.8.8:53').toDarkTunnelLockedUri()!,
      )!.dnsttResolver,
      '8.8.8.8',
    );
  });

  test('unsupported protocols return null on .dark export', () {
    const ovpn = ServerConfig(
      id: '5',
      name: 'OVPN',
      protocol: ProtocolType.openvpn,
      transport: TransportType.tcp,
      security: SecurityType.none,
      address: 'vpn.example.com',
      port: 1194,
      ovpnConfig: 'client\nremote vpn.example.com 1194\n',
      isCustom: true,
    );
    expect(ovpn.toDarkTunnelLockedUri(), isNull);
  });

  // ── Password lock + expiry semantics ─────────────────────────────────

  test('password lock: no/wrong PIN refused, right PIN opens', () {
    final uri = _vless().toDarkTunnelLockedUri(password: 's3cret')!;
    final lock = DarkTunnelCodec.decode(uri)!;
    expect(lock.passwordRequired, isTrue);
    expect(lock.checkPin('wrong'), isFalse);
    expect(lock.checkPin('s3cret'), isTrue);
    // No pin / wrong pin → null (importFromUri throws LockPinRequired
    // before even getting here).
    expect(ServerConfig.fromDarkTunnelUri(uri), isNull);
    expect(ServerConfig.fromDarkTunnelUri(uri, lockPin: 'wrong'), isNull);
    expect(ServerConfig.fromDarkTunnelUri(uri, lockPin: 's3cret'), isNotNull);
  });

  test('expiry (epoch seconds in the format) normalizes to ms', () {
    final expMs = DateTime.utc(2027, 1, 1).millisecondsSinceEpoch;
    final uri = _vless().toDarkTunnelLockedUri(expiresAtMs: expMs)!;
    final back = ServerConfig.fromDarkTunnelUri(uri)!;
    expect(back.expiresAt, expMs);
  });

  test('our no-password exports open without a PIN', () {
    final uri = _vless().toDarkTunnelLockedUri()!;
    expect(DarkTunnelCodec.requiresPassword(uri), isFalse);
    expect(isPinLockedText(uri), isFalse);
    expect(ServerConfig.fromDarkTunnelUri(uri), isNotNull);
  });

  test('exported v2ray lock carries the app-required sections', () {
    // The real DarkTunnel app expects V2RayConfig AND (default) SshConfig +
    // InjectConfig sections even for v2ray configs — verified against every
    // real locked file in the wild.
    final uri = _vless().toDarkTunnelLockedUri()!;
    final lock = DarkTunnelCodec.decode(uri)!;
    expect(lock.v2rayConfigJson, isNotNull);
    expect(lock.sshConfig['Host'], '');
    expect(lock.injectConfig['Mode'], 'DIRECT');
  });

  test('isPinLockedText leaves plain darktunnel shares alone', () {
    // An unlocked share (no envelope) must not be treated as PIN-locked.
    expect(isPinLockedText('darktunnel://eyJ0eXBlIjoiVExFU1MifQ'), isFalse);
    expect(isPinLockedText('hello world'), isFalse);
    expect(isPinLockedText('sensei:v2p:AAAA'), isTrue);
  });
}