import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// App-internal networking that transparently rides the active tunnel.
///
/// Android never routes the VPN-owner app's own traffic through its own TUN,
/// and `bindProcessToNetwork` is not always reliable across OEM ROMs. This
/// wrapper guarantees tunnel routing by pointing the app's HTTP requests at
/// the local HTTP proxy (`127.0.0.1:10809`) whenever the tunnel is up:
/// xray exposes that port natively, and SSH-family tunnels get an identical
/// HTTP<->SOCKS bridge started by the VPN service.
///
/// OpenVPN is the exception: it has no local proxy, but the service binds
/// the whole app process to the VPN network, so plain direct connections
/// already flow through the tunnel (`useLocalProxy: false`).
///
/// When the tunnel is down, plain direct connections are used (normal state).
class TunnelHttpClient {
  static const _proxyPort = 10809;
  static bool _tunnelActive = false;
  static bool _useLocalProxy = true;

  /// Call from the VPN state listener on connect/disconnect.
  ///
  /// [useLocalProxy] must be false only for OpenVPN tunnels, where the app
  /// process is bound to the VPN network and direct sockets are tunneled.
  static void setTunnelActive(bool active, {bool useLocalProxy = true}) {
    _tunnelActive = active;
    _useLocalProxy = useLocalProxy;
  }

  static bool get tunnelActive => _tunnelActive;

  static http.Client _makeClient() {
    if (!_tunnelActive || !_useLocalProxy) return http.Client();
    final inner = HttpClient();
    inner.findProxy = (uri) => 'PROXY 127.0.0.1:$_proxyPort';
    inner.connectionTimeout = const Duration(seconds: 12);
    return IOClient(inner);
  }

  static Future<http.Response> get(
    Uri url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final client = _makeClient();
    try {
      return await client.get(url, headers: headers).timeout(timeout);
    } finally {
      client.close();
    }
  }

  static Future<http.Response> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final client = _makeClient();
    try {
      return await client
          .post(url, headers: headers, body: body, encoding: encoding)
          .timeout(timeout);
    } finally {
      client.close();
    }
  }
}
