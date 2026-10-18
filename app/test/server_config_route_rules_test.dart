import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sensei_tunnel/models/server_config.dart';

void main() {
  const server = ServerConfig(
    id: 'test',
    name: 'Test',
    protocol: ProtocolType.vless,
    address: 'example.com',
    port: 443,
    uuid: '00000000-0000-0000-0000-000000000000',
  );

  Map<String, dynamic> configFor(List<Map<String, String>> rules) =>
      jsonDecode(server.toXrayConfig(10808, 'tun2socks', routeRules: rules))
          as Map<String, dynamic>;

  test('adds direct and block outbounds for matching route actions', () {
    final config = configFor([
      {'action': 'direct', 'value': 'example.com'},
      {'action': 'block', 'value': 'ads.example.com'},
    ]);

    final outbounds = config['outbounds'] as List<dynamic>;
    expect(outbounds.map((o) => o['tag']),
        containsAll(['proxy', 'direct', 'block']));
  });

  test('normalizes unknown route actions to direct outbound', () {
    final config = configFor([
      {'action': 'unknown', 'value': 'example.com'},
    ]);

    final outbounds = config['outbounds'] as List<dynamic>;
    final rules =
        (config['routing'] as Map<String, dynamic>)['rules'] as List<dynamic>;

    expect(outbounds.map((o) => o['tag']), contains('direct'));
    expect(rules.first['outboundTag'], 'direct');
  });

  test('classifies geo selectors into correct xray rule fields', () {
    final config = configFor([
      {'action': 'direct', 'value': 'geosite:google'},
      {'action': 'block', 'value': 'geoip:cn'},
    ]);

    final rules =
        (config['routing'] as Map<String, dynamic>)['rules'] as List<dynamic>;

    expect(
        rules.any((r) =>
            (r['domain'] as List<dynamic>?)?.contains('geosite:google') ??
            false),
        isTrue);
    expect(
        rules.any(
            (r) => (r['ip'] as List<dynamic>?)?.contains('geoip:cn') ?? false),
        isTrue);
  });

  test('classifies IPv4 CIDR and IPv6 values as ip rules', () {
    final config = configFor([
      {'action': 'direct', 'value': '1.2.3.0/24'},
      {'action': 'block', 'value': '2001:db8::1'},
    ]);

    final rules =
        (config['routing'] as Map<String, dynamic>)['rules'] as List<dynamic>;

    expect(
        rules.any((r) =>
            (r['ip'] as List<dynamic>?)?.contains('1.2.3.0/24') ?? false),
        isTrue);
    expect(
        rules.any((r) =>
            (r['ip'] as List<dynamic>?)?.contains('2001:db8::1') ?? false),
        isTrue);
  });
}
