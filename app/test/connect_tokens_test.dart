import 'package:flutter_test/flutter_test.dart';
import 'package:sensei_tunnel/models/server_config.dart';
import 'package:sensei_tunnel/services/config_service.dart';
import 'package:sensei_tunnel/utils/format.dart';

void main() {
  group('resolveConnectTokens', () {
    test('expands payload/sni/host/port/ua/crlf markers', () {
      final out = resolveConnectTokens(
        'GET http://[host]:[port]/ [payload] Host: [sni][crlf][ua][crlf][crlf]',
        host: 'vpn.example.com',
        port: '443',
        payload: 'X-Online-Host: real.host',
        sni: 'real.sni',
      );
      expect(out, contains('http://vpn.example.com:443/'));
      expect(out, contains('X-Online-Host: real.host'));
      expect(out, contains('Host: real.sni'));
      expect(out, contains('\r\n'));
      expect(out, contains('Mozilla/5.0'));
      expect(out.contains('[host]'), isFalse);
    });

    test('blank payload/sni expand to empty string', () {
      final out = resolveConnectTokens(
        'CONNECT [host] [payload][sni]',
        host: 'h',
        port: '1',
      );
      expect(out, 'CONNECT h ');
    });

    test('unknown tokens pass through untouched', () {
      final out = resolveConnectTokens(
        '[RYZE] [crlf] keep [me]',
        host: 'h',
        port: '1',
      );
      expect(out, contains('[RYZE]'));
      expect(out, contains('[me]'));
      expect(out, contains('\r\n'));
    });

    test('input without brackets returns untouched (same instance path)', () {
      final out = resolveConnectTokens('plain payload', host: 'h', port: '1');
      expect(out, 'plain payload');
    });

    test('native mode leaves wire markers for the injector, fills '
        'payload/sni references', () {
      final out = resolveConnectTokens(
        'CONNECT [host]:[port] HTTP/1.1[crlf]Host: [host][crlf][crlf]'
        'X-Ref: [payload] / [sni]',
        payload: 'abc',
        sni: 'bug.host',
        native: true,
      );
      // The native PayloadInjector is the authoritative renderer for these:
      // its [host] means the FRONT (bug/SNI) host, so they must survive.
      expect(out, contains('[host]'));
      expect(out, contains('[port]'));
      expect(out, contains('[crlf]'));
      // References to the config's own fields are still expanded — the
      // injector has no [payload]/[sni] tokens of its own.
      expect(out, contains('X-Ref: abc / bug.host'));
    });
  });

  group('ServerConfig.nativeInjectsPayload', () {
    ServerConfig cfg(
      ProtocolType protocol, {
      InjectMode injectMode = InjectMode.none,
      String? payload,
    }) =>
        ServerConfig(
          id: 'x',
          name: 'x',
          protocol: protocol,
          address: '1.1.1.1',
          port: 22,
          injectMode: injectMode,
          payload: payload,
        );

    test('ssh with any inject mode renders via the native injector', () {
      expect(cfg(ProtocolType.ssh, injectMode: InjectMode.proxySni)
          .nativeInjectsPayload, isTrue);
      expect(cfg(ProtocolType.ssh, injectMode: InjectMode.direct)
          .nativeInjectsPayload, isTrue);
      expect(cfg(ProtocolType.sshDnstt, injectMode: InjectMode.direct)
          .nativeInjectsPayload, isTrue);
    });

    test('ssh without an inject mode (none/dnstt) stays Dart-side', () {
      expect(cfg(ProtocolType.ssh).nativeInjectsPayload, isFalse);
      expect(cfg(ProtocolType.ssh, injectMode: InjectMode.dnstt)
          .nativeInjectsPayload, isFalse);
    });

    test('v2ray follows v2rayInjectActive', () {
      expect(cfg(ProtocolType.vless, payload: 'GET / HTTP/1.1')
          .nativeInjectsPayload, isTrue);
      expect(cfg(ProtocolType.vless, injectMode: InjectMode.proxy)
          .nativeInjectsPayload, isFalse);
      expect(cfg(ProtocolType.vless).nativeInjectsPayload, isFalse);
    });

    test('openvpn with an inject mode renders via the native injector', () {
      expect(cfg(ProtocolType.openvpn, injectMode: InjectMode.directSni)
          .nativeInjectsPayload, isTrue);
      expect(cfg(ProtocolType.openvpn).nativeInjectsPayload, isFalse);
    });
  });

  group('ConfigService.poolFor', () {
    test('anchor first, then same-category servers in feed order', () {
      const a = ServerConfig(
        id: 'a',
        name: 'A',
        protocol: ProtocolType.vless,
        address: 'a.example.com',
        port: 443,
      );
      const b = ServerConfig(
        id: 'b',
        name: 'B',
        protocol: ProtocolType.ssh,
        address: 'b.example.com',
        port: 22,
        category: 'RYZE',
      );
      const c = ServerConfig(
        id: 'c',
        name: 'C',
        protocol: ProtocolType.vmess,
        address: 'c.example.com',
        port: 443,
        category: 'RYZE',
      );
      const d = ServerConfig(
        id: 'd',
        name: 'D',
        protocol: ProtocolType.ssh,
        address: 'd.example.com',
        port: 22,
        category: 'other',
      );
      final pool = ServerPool.build([a, b, c, d], b);
      expect(pool.map((s) => s.id).toList(), ['b', 'c', 'a', 'd']);
    });

    test('blocked servers are skipped', () {
      const b = ServerConfig(
        id: 'b',
        name: 'B',
        protocol: ProtocolType.ssh,
        address: 'b.example.com',
        port: 22,
        category: 'RYZE',
        locked: true,
      );
      const c = ServerConfig(
        id: 'c',
        name: 'C',
        protocol: ProtocolType.vmess,
        address: 'c.example.com',
        port: 443,
        category: 'RYZE',
      );
      final pool = ServerPool.build([b, c], b);
      expect(pool.map((s) => s.id).toList(), ['c']);
    });

    test('solo-category anchor still gets other servers as last tier', () {
      const x = ServerConfig(
        id: 'x',
        name: 'X',
        protocol: ProtocolType.ssh,
        address: 'x.example.com',
        port: 22,
        category: 'solo',
      );
      const y = ServerConfig(
        id: 'y',
        name: 'Y',
        protocol: ProtocolType.ssh,
        address: 'y.example.com',
        port: 22,
      );
      final pool = ServerPool.build([y], x);
      expect(pool.map((s) => s.id).toList(), ['x', 'y']);
    });
  });
}
