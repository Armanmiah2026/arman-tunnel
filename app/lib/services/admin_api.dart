import 'dart:convert';
import 'package:http/http.dart' as http;
import 'obf.dart';

class AdminApi {
  static final String _baseUrl = Obf.adminUrl;
  String? _token;

  Future<bool> login(String username, String password) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username, 'password': password}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _token = data['token'];
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> getConfigs() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/api/configs'),
        headers: _token != null ? {'Authorization': 'Bearer $_token'} : {},
      );

      if (response.statusCode == 200) {
        return List<Map<String, dynamic>>.from(jsonDecode(response.body));
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  Future<bool> addConfig(Map<String, dynamic> config) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/configs'),
        headers: {
          'Content-Type': 'application/json',
          if (_token != null) 'Authorization': 'Bearer $_token',
        },
        body: jsonEncode(config),
      );
      return response.statusCode == 200 || response.statusCode == 201;
    } catch (e) {
      return false;
    }
  }

  Future<bool> updateConfig(String id, Map<String, dynamic> config) async {
    try {
      final response = await http.put(
        Uri.parse('$_baseUrl/api/configs/$id'),
        headers: {
          'Content-Type': 'application/json',
          if (_token != null) 'Authorization': 'Bearer $_token',
        },
        body: jsonEncode(config),
      );
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  Future<bool> deleteConfig(String id) async {
    try {
      final response = await http.delete(
        Uri.parse('$_baseUrl/api/configs/$id'),
        headers: _token != null ? {'Authorization': 'Bearer $_token'} : {},
      );
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  Future<bool> uploadConfig({
    required String name,
    required String note,
    required String protocol,
    required String address,
    required int port,
    String? uuid,
    String? sni,
    String? path,
    String? host,
    String? transport,
    String? security,
    String? logoBase64,
    String? payload,
    String? sshUser,
    String? sshPass,
    String? fingerprint,
    String? flow,
    String? encryption,
    bool isOfficial = true,
  }) async {
    final config = {
      'name': name,
      'note': note,
      'protocol': protocol,
      'address': address,
      'port': port,
      'isOfficial': isOfficial,
      if (uuid != null) 'uuid': uuid,
      if (sni != null) 'sni': sni,
      if (path != null) 'path': path,
      if (host != null) 'host': host,
      if (transport != null) 'transport': transport,
      if (security != null) 'security': security,
      if (logoBase64 != null) 'logoBase64': logoBase64,
      if (payload != null) 'payload': payload,
      if (sshUser != null) 'sshUser': sshUser,
      if (sshPass != null) 'sshPass': sshPass,
      if (fingerprint != null) 'fingerprint': fingerprint,
      if (flow != null) 'flow': flow,
      if (encryption != null) 'encryption': encryption,
    };

    return addConfig(config);
  }
}
