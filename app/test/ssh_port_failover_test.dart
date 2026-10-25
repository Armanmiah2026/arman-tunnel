import 'package:flutter_test/flutter_test.dart';
import 'package:snapdark_tunnel/models/server_config.dart';

void main() {
  ServerConfig ssh({int port = 22, List<int> fallbackPorts = const []}) =>
      ServerConfig(
        id: 'ssh-test',
        name: 'SSH Test',
        protocol: ProtocolType.ssh,
        address: 'example.com',
        port: port,
        fallbackPorts: fallbackPorts,
        sshUser: 'u',
        sshPass: 'p',
      );

  group('effectiveSshPorts', () {
    test('defaults to primary first, then the built-in panel ports', () {
      // The panel ships port 22; the same sshd also listens on 443/80/109.
      expect(ssh(port: 22).effectiveSshPorts, [22, 443, 80, 109]);
      expect(ssh(port: 443).effectiveSshPorts, [443, 80, 109, 22]);
      expect(ssh(port: 109).effectiveSshPorts, [109, 443, 80, 22]);
    });

    test('never walks the same port twice', () {
      final ports = ssh(port: 443).effectiveSshPorts;
      expect(ports.toSet().length, ports.length);
    });

    test('explicit fallbackPorts replace the defaults', () {
      final c = ssh(port: 22, fallbackPorts: [8443, 8080]);
      expect(c.effectiveSshPorts, [22, 8443, 8080]);
    });

    test('listing only the primary port disables the walk', () {
      expect(ssh(port: 22, fallbackPorts: [22]).effectiveSshPorts, [22]);
    });

    test('drops out-of-range and duplicate entries', () {
      final c = ssh(port: 22, fallbackPorts: [0, -1, 70000, 80, 80]);
      expect(c.effectiveSshPorts, [22, 80]);
    });

    test('empty for non-SSH protocols', () {
      const vless = ServerConfig(
        id: 'v',
        name: 'V',
        protocol: ProtocolType.vless,
        address: 'example.com',
        port: 443,
        uuid: '00000000-0000-0000-0000-000000000000',
      );
      expect(vless.effectiveSshPorts, isEmpty);
    });

    test('sshDnstt (slowdns) counts as SSH family', () {
      final c = ssh(port: 53);
      final dnstt = c.copyWith(protocol: ProtocolType.sshDnstt);
      expect(dnstt.effectiveSshPorts, [53, 443, 80, 109, 22]);
    });
  });

  group('parsePortList', () {
    test('parses comma, semicolon and whitespace separated strings', () {
      expect(ServerConfig.parsePortList('443,80'), [443, 80]);
      expect(ServerConfig.parsePortList('443; 80'), [443, 80]);
      expect(ServerConfig.parsePortList('443 80,22'), [443, 80, 22]);
    });

    test('parses JSON list and bare int', () {
      expect(ServerConfig.parsePortList([443, '80']), [443, 80]);
      expect(ServerConfig.parsePortList(443), [443]);
    });

    test('drops garbage, empties and out-of-range values', () {
      expect(ServerConfig.parsePortList('http,80,99999'), [80]);
      expect(ServerConfig.parsePortList(''), isEmpty);
      expect(ServerConfig.parsePortList(null), isEmpty);
      expect(ServerConfig.parsePortList('0,-5,65536'), isEmpty);
    });
  });

  group('persistence', () {
    test('toJson/fromJson round-trips fallbackPorts', () {
      final c = ssh(port: 22, fallbackPorts: [443, 80]);
      final back = ServerConfig.fromJson(c.toJson());
      expect(back.fallbackPorts, [443, 80]);
      expect(back.effectiveSshPorts, [22, 443, 80]);
    });

    test('copyWith keeps fallbackPorts unless overridden', () {
      final c = ssh(port: 22, fallbackPorts: [443, 80]);
      expect(c.copyWith(name: 'X').fallbackPorts, [443, 80]);
      expect(c.copyWith(fallbackPorts: [109]).fallbackPorts, [109]);
    });
  });
}
