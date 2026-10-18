import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sensei_tunnel/models/server_config.dart';
import 'package:sensei_tunnel/services/config_service.dart';
import 'package:sensei_tunnel/services/tunnel_http_client.dart';
import 'package:sensei_tunnel/services/vpn_service.dart';

ServerConfig _officialTweak() => const ServerConfig(
      id: 'mine-2',
      name: 'CF Method',
      protocol: ProtocolType.vless,
      address: '',
      port: 443,
      uuid: '',
      capability: 'CLOUDFLARE-PROXY-PAYLOAD',
      sni: 'cf.example.com',
      injectHost: 'proxy.example.com',
      injectPort: '443',
      payload: 'GET / HTTP/1.1[crlf]Host: [host][crlf][crlf]',
      injectMode: InjectMode.proxySni,
      payloadEnhanced: true,
      isCustom: true,
      rawConfig: 'official:tweak',
    );

ServerConfig _ssh() => const ServerConfig(
      id: 'ssh-1',
      name: 'My SSH',
      protocol: ProtocolType.ssh,
      address: 'ssh.example.com',
      port: 443,
      sshUser: 'root',
      sshPass: 's3cret',
      payload:
          'CONNECT [ssh_host]:[ssh_port] [protocol][crlf]Host: [host][crlf][crlf]',
      injectMode: InjectMode.proxySni,
      sni: 'bug.example.com',
      isCustom: true,
    );

/// Native `ShareEnvelope.build` with no security = an `open/` envelope: plain
/// base64url of the config JSON. Reproduced faithfully without the Kotlin side.
String _openEnvelope(ServerConfig c) =>
    'armantunnel://base64/48/open/'
    '${base64Url.encode(utf8.encode(jsonEncode(c.toJson())))}';

void _mockVpnChannel() {
  const channel = MethodChannel('com.sensei.tunnel/vpn');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    switch (call.method) {
      case 'verifyIntegrity':
        return true;
      case 'encryptCache':
      case 'decryptCache':
        return null;
      case 'shareEnvelopeOpen':
        final text = (call.arguments as Map)['text'] as String;
        const prefix = 'armantunnel://base64/48/';
        final rest = text.trim().substring(prefix.length);
        final payload = rest.substring(rest.indexOf('/') + 1);
        final json =
            utf8.decode(base64Url.decode(base64Url.normalize(payload)));
        return <String, dynamic>{'ok': true, 'config': json};
      default:
        return null;
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TunnelHttpClient.setTunnelActive(true);
    _mockVpnChannel();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.sensei.tunnel/vpn'), null);
  });

  test('open share of a normal SSH config imports via importFromText', () async {
    final public = VpnService.wrapShareEnvelope(_openEnvelope(_ssh()));
    final cfg = ConfigService();
    final r = await cfg.importFromText(public);
    expect(r.count, 1);
    expect(r.last!.address, 'ssh.example.com');
    expect(r.last!.protocol, ProtocolType.ssh);
    expect(cfg.customServers, hasLength(1));
  });

  test('open share of an official tweak imports with placeholders intact',
      () async {
    final public =
        VpnService.wrapShareEnvelope(_openEnvelope(_officialTweak()));
    final cfg = ConfigService();
    final r = await cfg.importFromText(public);
    expect(r.count, 1);
    final got = r.last!;
    expect(got.rawConfig, 'official:tweak');
    expect(got.capability, 'CLOUDFLARE-PROXY-PAYLOAD');
    expect(got.sni, 'cf.example.com');
    expect(got.injectHost, 'proxy.example.com');
    expect(got.injectMode, InjectMode.proxySni);
    expect(got.payloadEnhanced, isTrue);
  });

  test('a share token hard-wrapped across lines by a chat app still imports',
      () async {
    final public = VpnService.wrapShareEnvelope(_openEnvelope(_ssh()));
    final at = public.length ~/ 2;
    final wrapped = '${public.substring(0, at)}\n${public.substring(at)}\n';
    final cfg = ConfigService();
    final r = await cfg.importFromText(wrapped);
    expect(r.count, 1, reason: 'whole-text squash repairs chat-app line wrap');
    expect(r.last!.address, 'ssh.example.com');
  });

  test('multi-line .st export imports every line as its own config', () async {
    final file = [
      VpnService.wrapShareEnvelope(_openEnvelope(_ssh())),
      VpnService.wrapShareEnvelope(_openEnvelope(_officialTweak())),
    ].join('\n');
    final cfg = ConfigService();
    final r = await cfg.importFromText(file);
    expect(r.count, 2);
    expect(cfg.customServers, hasLength(2));
  });
}