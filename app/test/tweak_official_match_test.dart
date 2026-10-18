import 'package:flutter_test/flutter_test.dart';
import 'package:sensei_tunnel/models/server_config.dart';
import 'package:sensei_tunnel/services/config_service.dart';

ServerConfig official(
  String id,
  ProtocolType protocol,
  String capability, {
  TransportType transport = TransportType.tcp,
}) =>
    ServerConfig(
      id: id,
      name: id,
      protocol: protocol,
      transport: transport,
      address: '$id.example.com',
      port: 443,
      capability: capability,
    );

void main() {
  group('capabilityKey', () {
    test('matches the panel normalization (upper + underscores)', () {
      expect(ServerConfig.capabilityKey(' sni '), 'SNI');
      expect(ServerConfig.capabilityKey('proxy payload'), 'PROXY_PAYLOAD');
      expect(ServerConfig.capabilityKey('CLOUDFRONT-PROXY-PAYLOAD'),
          'CLOUDFRONT-PROXY-PAYLOAD');
      expect(ServerConfig.capabilityKey(''), '');
    });
  });

  group('familyOf', () {
    test('mirrors familyOfProtocol from config-schema.js', () {
      expect(ServerConfig.familyOf(ProtocolType.vless), 'v2ray');
      expect(ServerConfig.familyOf(ProtocolType.vmess), 'v2ray');
      expect(ServerConfig.familyOf(ProtocolType.trojan), 'v2ray');
      expect(ServerConfig.familyOf(ProtocolType.ssh), 'ssh');
      expect(ServerConfig.familyOf(ProtocolType.sshDnstt), 'ssh');
      expect(ServerConfig.familyOf(ProtocolType.openvpn), 'openvpn');
    });
  });

  group('tweakPoolFor (Server ↔ Tweak join)', () {
    final feed = [
      official('ws1', ProtocolType.vless, 'SNI', transport: TransportType.ws),
      official('ssh1', ProtocolType.ssh, 'SNI'),
      official('ws2', ProtocolType.vmess, 'sni', transport: TransportType.ws),
      official('ovp1', ProtocolType.openvpn, 'SNI'),
      official('tls1', ProtocolType.vless, 'SSL'),
    ];

    test('capability match alone is NOT enough — family must match', () {
      final pool = ConfigService.tweakPoolFor(
        feed,
        capability: 'SNI',
        protocol: ProtocolType.vless,
      );
      expect(pool.map((s) => s.id), ['ws1', 'ws2']);
    });

    test('canonical keys: tweak [sni] matches feed [SNI] and vice versa', () {
      final pool = ConfigService.tweakPoolFor(
        feed,
        capability: ' sni ',
        protocol: ProtocolType.vless,
      );
      expect(pool.length, 2);
    });

    test('an SSH tweak rides SSH servers only', () {
      final pool = ConfigService.tweakPoolFor(
        feed,
        capability: 'SNI',
        protocol: ProtocolType.ssh,
      );
      expect(pool.map((s) => s.id), ['ssh1']);
    });

    test("family 'mixed' rides EVERY family with the capability", () {
      final pool = ConfigService.tweakPoolFor(
        feed,
        capability: 'SNI',
        protocol: ProtocolType.ssh,
        family: 'mixed',
      );
      expect(pool.map((s) => s.id), ['ws1', 'ssh1', 'ws2', 'ovp1']);
    });

    test("family '*' is an alias for mixed", () {
      final pool = ConfigService.tweakPoolFor(
        feed,
        capability: 'SNI',
        protocol: ProtocolType.vless,
        family: '*',
      );
      expect(pool.map((s) => s.id), ['ws1', 'ssh1', 'ws2', 'ovp1']);
    });

    test('an explicit family overrides the tweak protocol', () {
      // A tweak whose protocol is SSH but family says 'v2ray' rides v2ray.
      final pool = ConfigService.tweakPoolFor(
        feed,
        capability: 'SNI',
        protocol: ProtocolType.ssh,
        family: 'v2ray',
      );
      expect(pool.map((s) => s.id), ['ws1', 'ws2']);
    });

    test('preferred anchor moves to the front, feed order stays behind', () {
      final pool = ConfigService.tweakPoolFor(
        feed,
        capability: 'SNI',
        protocol: ProtocolType.vless,
        anchorId: 'ws2',
      );
      expect(pool.map((s) => s.id), ['ws2', 'ws1']);
    });

    test('anchor removed from the panel falls back to feed order', () {
      final pool = ConfigService.tweakPoolFor(
        feed,
        capability: 'SNI',
        protocol: ProtocolType.vless,
        anchorId: 'gone',
      );
      expect(pool.map((s) => s.id), ['ws1', 'ws2']);
    });

    test('unknown capability rides nothing', () {
      expect(
        ConfigService.tweakPoolFor(feed, capability: 'NOPE',
            protocol: ProtocolType.vless),
        isEmpty,
      );
    });

    test('multi-cap node matches via its capabilities[] list', () {
      final multi = official('both1', ProtocolType.vless, 'DIRECT').copyWith(
        capabilities: const ['DIRECT', 'SNI'],
      );
      final list = [...feed, multi];
      final pool = ConfigService.tweakPoolFor(
        list,
        capability: 'SNI',
        protocol: ProtocolType.vless,
      );
      expect(pool.map((s) => s.id), contains('both1'));
    });
  });

  group('tweak share round-trip', () {
    test('anchor survives the key=value share format', () {
      const tweak = ServerConfig(
        id: 't1',
        name: 'My SNI tweak',
        protocol: ProtocolType.ssh,
        address: '',
        port: 443,
        isCustom: true,
        rawConfig: 'official:tweak',
        capability: 'SNI',
        anchorId: 'ssh1',
        sni: 'bug.example.com',
      );
      final text = tweak.toHttpCustomText();
      expect(text, contains('anchor=ssh1'));
      final back = ServerConfig.fromHttpCustomConfig(text);
      expect(back, isNotNull);
      expect(back!.capability, 'SNI');
      expect(back.anchorId, 'ssh1');
      expect(back.rawConfig, 'official:tweak');
    });

    test('anchor survives the JSON round-trip', () {
      const tweak = ServerConfig(
        id: 't1',
        name: 't',
        protocol: ProtocolType.vless,
        address: '',
        port: 443,
        isCustom: true,
        rawConfig: 'official:tweak',
        capability: 'SNI',
        anchorId: 'ws1',
      );
      final back = ServerConfig.fromJson(tweak.toJson());
      expect(back.anchorId, 'ws1');
    });
  });
}
