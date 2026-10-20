import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapdark_tunnel/models/server_config.dart';
import 'package:snapdark_tunnel/services/config_service.dart';
import 'package:snapdark_tunnel/services/vpn_service.dart';

void main() {
  test('official-backed custom placeholder does not persist official secrets', () {
    const leaked = ServerConfig(
      id: 'mine-1',
      name: 'Official SNI tweak',
      protocol: ProtocolType.ssh,
      address: 'secret.official.example.com',
      port: 443,
      sshUser: 'official-user',
      sshPass: 'official-pass',
      uuid: 'official-uuid',
      sni: 'bug.example.com',
      capability: 'SNI',
      serverPool: [
        {
          'address': 'backup.official.example.com',
          'sshPass': 'backup-pass',
        },
      ],
      isCustom: true,
    );

    final safe = ConfigService.officialTweakPlaceholder(leaked);
    final json = jsonEncode(safe.toJson());

    expect(safe.rawConfig, 'official:tweak');
    expect(safe.capability, 'SNI');
    expect(safe.address, isEmpty);
    expect(safe.uuid, isEmpty);
    expect(safe.serverPool, isEmpty);
    expect(json, isNot(contains('secret.official')));
    expect(json, isNot(contains('official-pass')));
    expect(json, isNot(contains('backup-pass')));
  });

  test('official-backed text share carries only type and tweak fields', () {
    const c = ServerConfig(
      id: 'mine-2',
      name: 'Official Cloudflare method',
      protocol: ProtocolType.vless,
      address: '',
      port: 443,
      uuid: '',
      capability: 'CLOUDFLARE-PROXY-PAYLOAD',
      sni: 'cf.example.com',
      injectHost: 'bug.example.com',
      injectPort: '443',
      payload: 'GET / HTTP/1.1[crlf]Host: [host][crlf][crlf]',
      injectMode: InjectMode.proxySni,
      payloadEnhanced: true,
      isCustom: true,
      rawConfig: 'official:tweak',
    );

    final text = c.toHttpCustomText();
    expect(text, contains('official=1'));
    expect(text, contains('capability=CLOUDFLARE-PROXY-PAYLOAD'));
    expect(text, contains('sni=cf.example.com'));
    expect(text, contains('payload='));
    expect(text, isNot(contains('host=')));
    expect(text, isNot(contains('uuid=')));
    expect(text, isNot(contains('auth=')));

    final back = ServerConfig.fromHttpCustomConfig(text);
    expect(back, isNotNull);
    expect(back!.rawConfig, 'official:tweak');
    expect(back.address, isEmpty);
    expect(back.uuid, isEmpty);
    expect(back.capability, 'CLOUDFLARE-PROXY-PAYLOAD');
    expect(back.sni, 'cf.example.com');
    expect(back.injectHost, 'bug.example.com');
    expect(back.injectMode, InjectMode.proxySni);
    expect(back.payloadEnhanced, isTrue);
  });

  test('SSH config round-trips through key=value share text', () {
    const c = ServerConfig(
      id: '1',
      name: 'My SSH',
      protocol: ProtocolType.ssh,
      address: 'ssh.example.com',
      port: 443,
      sshUser: 'root',
      sshPass: 's3cret',
      sni: 'bug.example.com',
      injectHost: '10.10.10.10',
      injectPort: '8080',
      injectMode: InjectMode.proxySni,
      payload:
          'CONNECT [ssh_host]:[ssh_port] [protocol][crlf]Host: [host][crlf][crlf]',
      payloadEnhanced: true,
      isCustom: true,
      category: 'global',
    );

    final text = c.toHttpCustomText();
    // The share text is plain key=value lines.
    expect(text, contains('type=SSH'));
    expect(text, contains('host=ssh.example.com'));
    expect(text, contains('auth=root:s3cret'));
    expect(text, contains('bug=10.10.10.10'));
    expect(text, contains('enhance=1'));

    final back = ServerConfig.fromHttpCustomConfig(text);
    expect(back, isNotNull);
    expect(back!.name, 'My SSH');
    expect(back.protocol, ProtocolType.ssh);
    expect(back.address, 'ssh.example.com');
    expect(back.port, 443);
    expect(back.sshUser, 'root');
    expect(back.sshPass, 's3cret');
    expect(back.sni, 'bug.example.com');
    expect(back.injectHost, '10.10.10.10');
    expect(back.injectPort, '8080');
    expect(back.injectMode, InjectMode.proxySni);
    expect(back.payload, c.payload);
    expect(back.payloadEnhanced, isTrue);
  });

  test('VLESS ws+tls round-trips through key=value share text', () {
    const c = ServerConfig(
      id: '2',
      name: 'VLESS TLS WS',
      protocol: ProtocolType.vless,
      transport: TransportType.ws,
      security: SecurityType.tls,
      address: 'sgx.tdz-server.store',
      port: 490,
      uuid: '0bb6cfbd-3a25-46e6-b50a-3b5a25aee3ff',
      host: 'sgx.tdz-server.store',
      path: '/@your_channel',
      sni: 'Facebook.com',
      isCustom: true,
      category: 'global',
    );

    final back = ServerConfig.fromHttpCustomConfig(c.toHttpCustomText());
    expect(back, isNotNull);
    expect(back!.protocol, ProtocolType.vless);
    expect(back.transport, TransportType.ws);
    expect(back.security, SecurityType.tls);
    expect(back.address, 'sgx.tdz-server.store');
    expect(back.port, 490);
    expect(back.uuid, '0bb6cfbd-3a25-46e6-b50a-3b5a25aee3ff');
    expect(back.path, '/@your_channel');
    expect(back.sni, 'Facebook.com');
  });

  test('payload with real newlines is escaped to literal \\r\\n in share text',
      () {
    const c = ServerConfig(
      id: '3',
      name: 'multi',
      protocol: ProtocolType.ssh,
      address: 'h',
      port: 22,
      payload: 'GET / HTTP/1.1\r\nHost: x\r\n\r\n',
      isCustom: true,
      category: 'global',
    );
    final text = c.toHttpCustomText();
    // The wire format must stay single-line per key: real CRLFs would break
    // the key=value parser. The engine expands the literal escapes itself.
    expect(text.contains('payload=GET / HTTP/1.1\\r\\nHost: x\\r\\n\\r\\n'),
        isTrue);
    expect('payload='.allMatches(text).length, 1);

    final back = ServerConfig.fromHttpCustomConfig(text)!;
    expect(back.payload, 'GET / HTTP/1.1\\r\\nHost: x\\r\\n\\r\\n');
  });

  test('share link survives base64url round-trip', () {
    const c = ServerConfig(
      id: '4',
      name: 'link',
      protocol: ProtocolType.vless,
      address: 'a.b.c',
      port: 443,
      uuid: 'x',
      isCustom: true,
      category: 'global',
    );
    final link = c.toShareLink();
    expect(link.startsWith('armantunnel://'), isTrue);

    // Same decode path importFromText uses.
    final payload = link.substring('armantunnel://'.length);
    final normalized = payload.replaceAll('-', '+').replaceAll('_', '/');
    final padded = normalized + '=' * ((4 - normalized.length % 4) % 4);
    final json = jsonDecode(utf8.decode(base64.decode(padded)));
    final back = ServerConfig.fromJson(Map<String, dynamic>.from(json));
    expect(back.protocol, ProtocolType.vless);
    expect(back.address, 'a.b.c');
    expect(back.port, 443);
  });

  test('v48 share envelope is hidden behind one opaque snapdarktunnel URI', () {
    const native = 'armantunnel://base64/48/lock/header.body';
    final public = VpnService.wrapShareEnvelope(native);
    expect(public.startsWith('armantunnel://'), isTrue);
    expect(public, isNot(contains('base64/48')));
    expect(public, isNot(contains('/lock')));
    expect(VpnService.unwrapShareEnvelope(public), native);
    expect(VpnService.unwrapShareEnvelope(native), isNull);
  });

  test('shareLinkForAll produces an array backup', () {
    const c1 = ServerConfig(
      id: 'a',
      name: 'one',
      protocol: ProtocolType.ssh,
      address: 'h1',
      port: 22,
      isCustom: true,
      category: 'global',
    );
    const c2 = ServerConfig(
      id: 'b',
      name: 'two',
      protocol: ProtocolType.vless,
      address: 'h2',
      port: 443,
      isCustom: true,
      category: 'global',
    );
    final link = ServerConfig.shareLinkForAll([c1, c2]);
    final payload = link.substring('armantunnel://'.length);
    final normalized = payload.replaceAll('-', '+').replaceAll('_', '/');
    final padded = normalized + '=' * ((4 - normalized.length % 4) % 4);
    final json = jsonDecode(utf8.decode(base64.decode(padded)));
    expect(json, isA<List<dynamic>>());
    expect((json as List).length, 2);
    // Every entry re-imports into a config.
    for (final item in json) {
      final c = ServerConfig.fromJson(Map<String, dynamic>.from(item));
      expect(c.isCustom, isTrue);
    }
  });

  test('dnstt fields round-trip through share text', () {
    const c = ServerConfig(
      id: 'd',
      name: 'slowdns',
      protocol: ProtocolType.sshDnstt,
      address: 'h',
      port: 22,
      dnsttServer: 'tunnel.example.com',
      dnsttKey: 'pubkey123',
      dnsttResolver: '1.1.1.1',
      isCustom: true,
      category: 'global',
    );
    final back = ServerConfig.fromHttpCustomConfig(c.toHttpCustomText())!;
    expect(back.protocol, ProtocolType.sshDnstt);
    expect(back.dnsttServer, 'tunnel.example.com');
    expect(back.dnsttKey, 'pubkey123');
    expect(back.dnsttResolver, '1.1.1.1');
  });

  test('multi-section .st export text parses per-config on split', () {
    const a = ServerConfig(
      id: '1',
      name: 'Robi',
      protocol: ProtocolType.ssh,
      address: 'robi.example.com',
      port: 443,
      sshUser: 'u',
      sshPass: 'p',
      sni: 'robi-bug.example.com',
      injectMode: InjectMode.directSni,
      payload: 'GET / HTTP/1.1[crlf]Host: [host][crlf][crlf]',
      isCustom: true,
      category: 'global',
    );
    const b = ServerConfig(
      id: '2',
      name: 'Airtel',
      protocol: ProtocolType.ssh,
      address: 'airtel.example.com',
      port: 443,
      sshUser: 'u',
      sshPass: 'p',
      sni: 'airtel-bug.example.com',
      injectMode: InjectMode.directSni,
      isCustom: true,
      category: 'global',
    );

    // The export path joins whole share texts — every section starts with
    // its own `###` header line.
    final joined = [a, b].map((c) => c.toHttpCustomText()).join('\n');
    final blocks = joined
        .split(RegExp(r'^###.*$', multiLine: true))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    expect(blocks, hasLength(2), reason: 'each config keeps its own section');

    final backA = ServerConfig.fromHttpCustomConfig(blocks[0])!;
    final backB = ServerConfig.fromHttpCustomConfig(blocks[1])!;
    expect(backA.name, 'Robi');
    expect(backA.sni, 'robi-bug.example.com');
    expect(backB.name, 'Airtel');
    expect(backB.sni, 'airtel-bug.example.com');
  });
}
