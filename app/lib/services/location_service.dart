import 'dart:convert';
import 'package:flutter/material.dart';

import 'tunnel_http_client.dart';

class LocationInfo {
  final String ip;
  final String country;
  final String city;
  final String isp;
  final String countryCode;
  const LocationInfo({
    required this.ip,
    required this.country,
    required this.city,
    required this.isp,
    required this.countryCode,
  });
}

/// Detects the user's current public-IP location (country / city / ISP) and
/// re-detects whenever the IP may have changed (connect / disconnect).
///
/// All requests go through [TunnelHttpClient], so while the tunnel is up the
/// lookup rides the VPN and reports the tunnel exit IP — never the real IP.
class LocationService extends ChangeNotifier {
  LocationInfo? _info;
  bool _loading = false;
  String _error = '';

  LocationInfo? get info => _info;
  bool get loading => _loading;
  String get error => _error;

  LocationService() {
    detect();
  }

  Future<void> detect() async {
    _loading = true;
    notifyListeners();
    try {
      // ipwho.is — free, https, no key. Returns country/city/connection.isp.
      final r = await TunnelHttpClient.get(
        Uri.parse('https://ipwho.is/'),
        timeout: const Duration(seconds: 10),
      );
      if (r.statusCode == 200) {
        final d = jsonDecode(r.body) as Map<String, dynamic>;
        if (d['success'] == true) {
          _info = LocationInfo(
            ip: d['ip']?.toString() ?? '',
            country: d['country']?.toString() ?? 'Unknown',
            city: d['city']?.toString() ?? '',
            isp: (d['connection']?['isp'] ?? d['connection']?['org'] ?? '')
                .toString(),
            countryCode: (d['country_code'] ?? '').toString().toLowerCase(),
          );
          _error = '';
        } else {
          _error = 'lookup failed';
        }
      } else {
        _error = 'lookup failed';
      }
    } catch (e) {
      // While connected a failure usually means the tunnel itself is dead —
      // keep the last known info rather than flashing a misleading value.
      _error = TunnelHttpClient.tunnelActive ? 'tunnel offline' : 'offline';
    }
    _loading = false;
    notifyListeners();
  }

  /// Re-detect after a short delay (IP changes once the tunnel is up/down).
  void scheduleRedetect() {
    Future.delayed(const Duration(seconds: 2), detect);
  }
}
