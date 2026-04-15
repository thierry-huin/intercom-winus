import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class ApiService {
  final String baseUrl;
  String? _token;
  static const _timeout = Duration(seconds: 10);
  static const _maxRetries = 2;

  ApiService({required this.baseUrl});

  void setToken(String? token) => _token = token;
  String? get token => _token;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  // ======================== CORE REQUEST WITH RETRY ========================

  /// Central HTTP method with timeout + automatic retry on network errors.
  Future<http.Response> _fetch(
    String method,
    String path, {
    Map<String, String>? headers,
    String? body,
    int retries = _maxRetries,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final hdrs = headers ?? _headers;
    Exception? lastError;

    for (int attempt = 0; attempt <= retries; attempt++) {
      try {
        if (attempt > 0) {
          debugPrint('[API] Retry $attempt/$retries: $method $path');
          await Future.delayed(Duration(milliseconds: 800 * attempt));
        }
        final http.Response r;
        switch (method) {
          case 'GET':    r = await http.get(uri, headers: hdrs).timeout(_timeout); break;
          case 'POST':   r = await http.post(uri, headers: hdrs, body: body).timeout(_timeout); break;
          case 'PUT':    r = await http.put(uri, headers: hdrs, body: body).timeout(_timeout); break;
          case 'DELETE': r = await http.delete(uri, headers: hdrs).timeout(_timeout); break;
          default: throw Exception('Unknown method $method');
        }
        return r;
      } on TimeoutException {
        lastError = Exception('Request timeout: $method $path');
      } catch (e) {
        lastError = Exception('Network error: $e');
      }
    }
    throw lastError!;
  }

  dynamic _decode(http.Response r, {bool allowEmpty = false}) {
    if (r.body.isEmpty) {
      if (allowEmpty) return null;
      throw Exception('Empty response (HTTP ${r.statusCode})');
    }
    try {
      return jsonDecode(r.body);
    } catch (_) {
      throw Exception('Invalid response from server');
    }
  }

  void _checkStatus(http.Response r, dynamic data) {
    if (r.statusCode >= 200 && r.statusCode < 300) return;
    final msg = data is Map ? data['error'] : null;
    throw Exception(msg ?? 'Error ${r.statusCode}');
  }

  // ---- Auth ----

  Future<Map<String, dynamic>> login(String username, String password) async {
    final r = await _fetch('POST', '/api/auth/login',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username, 'password': password}));
    final data = _decode(r) as Map<String, dynamic>;
    _checkStatus(r, data);
    _token = data['token'];
    return data;
  }

  // ---- Targets ----

  Future<Map<String, dynamic>> getMyTargets() async {
    final r = await _fetch('GET', '/api/rooms/my-targets');
    return _decode(r) as Map<String, dynamic>;
  }

  // ---- Admin: Users ----

  Future<List<dynamic>> getUsers() async {
    final r = await _fetch('GET', '/api/admin/users');
    final data = _decode(r);
    _checkStatus(r, data);
    return data as List<dynamic>;
  }

  Future<Map<String, dynamic>> createUser(Map<String, dynamic> data) async {
    final r = await _fetch('POST', '/api/admin/users', body: jsonEncode(data));
    return _decode(r) as Map<String, dynamic>;
  }

  Future<void> updateUser(int id, Map<String, dynamic> data) async {
    await _fetch('PUT', '/api/admin/users/$id', body: jsonEncode(data));
  }

  Future<void> deleteUser(int id) async {
    await _fetch('DELETE', '/api/admin/users/$id');
  }

  // ---- Admin: Groups ----

  Future<List<dynamic>> getGroups() async {
    final r = await _fetch('GET', '/api/admin/groups');
    final data = _decode(r);
    _checkStatus(r, data);
    return data as List<dynamic>;
  }

  Future<Map<String, dynamic>> createGroup(Map<String, dynamic> data) async {
    final r = await _fetch('POST', '/api/admin/groups', body: jsonEncode(data));
    return _decode(r) as Map<String, dynamic>;
  }

  Future<void> updateGroup(int id, Map<String, dynamic> data) async {
    await _fetch('PUT', '/api/admin/groups/$id', body: jsonEncode(data));
  }

  Future<void> deleteGroup(int id) async {
    await _fetch('DELETE', '/api/admin/groups/$id');
  }

  // ---- Admin: Permissions ----

  Future<List<dynamic>> getPermissions() async {
    final r = await _fetch('GET', '/api/admin/permissions');
    final data = _decode(r);
    _checkStatus(r, data);
    return data as List<dynamic>;
  }

  Future<void> setPermission(int fromId, int toId, bool allowed) async {
    if (allowed) {
      await _fetch('POST', '/api/admin/permissions',
          body: jsonEncode({'from_user_id': fromId, 'to_user_id': toId, 'can_talk': true}));
    } else {
      await _fetch('DELETE', '/api/admin/permissions/$fromId/$toId');
    }
  }

  // ---- Admin: Group Permissions ----

  Future<List<dynamic>> getGroupPermissions() async {
    final r = await _fetch('GET', '/api/admin/group-permissions');
    final data = _decode(r);
    _checkStatus(r, data);
    return data as List<dynamic>;
  }

  Future<void> setGroupPermission(int userId, int groupId, bool allowed) async {
    if (allowed) {
      await _fetch('POST', '/api/admin/group-permissions',
          body: jsonEncode({'from_user_id': userId, 'to_group_id': groupId, 'can_talk': true}));
    } else {
      await _fetch('DELETE', '/api/admin/group-permissions/$userId/$groupId');
    }
  }

  // ---- Admin: Kick / Online ----

  Future<void> kickUser(int id) async {
    final r = await _fetch('POST', '/api/admin/users/$id/kick');
    final data = _decode(r, allowEmpty: true);
    _checkStatus(r, data);
  }

  Future<List<int>> getOnlineUserIds() async {
    final r = await _fetch('GET', '/api/admin/online');
    if (r.statusCode != 200) return [];
    final data = _decode(r) as Map<String, dynamic>;
    return (data['userIds'] as List).map((e) => e as int).toList();
  }

  // ---- Admin: Group Members ----

  Future<void> addGroupMember(int groupId, int userId) async {
    await _fetch('POST', '/api/admin/groups/$groupId/members',
        body: jsonEncode({'user_id': userId}));
  }

  Future<void> removeGroupMember(int groupId, int userId) async {
    await _fetch('DELETE', '/api/admin/groups/$groupId/members/$userId');
  }

  // ---- Admin: Bridge Status ----

  Future<List<dynamic>> getBridgeStatus() async {
    final r = await _fetch('GET', '/api/admin/bridge-status');
    if (r.statusCode != 200) return [];
    final data = _decode(r);
    return data as List<dynamic>;
  }

  // ---- Admin: Config Export/Import ----

  Future<Map<String, dynamic>> exportConfig() async {
    final r = await _fetch('GET', '/api/admin/export-config');
    return _decode(r) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> importConfig(Map<String, dynamic> data) async {
    final r = await _fetch('POST', '/api/admin/import-config', body: jsonEncode(data));
    final decoded = _decode(r) as Map<String, dynamic>;
    _checkStatus(r, decoded);
    return decoded;
  }

  // ---- Admin: Bridge Config ----

  Future<Map<String, dynamic>> getBridgeConfig() async {
    final r = await _fetch('GET', '/api/admin/bridge-config');
    return _decode(r) as Map<String, dynamic>;
  }

  Future<void> saveBridgeConfig(List<Map<String, dynamic>> channels) async {
    final r = await _fetch('PUT', '/api/admin/bridge-config',
        body: jsonEncode({'channels': channels}));
    final decoded = _decode(r, allowEmpty: true);
    _checkStatus(r, decoded);
  }

  // ---- Admin: Server Config ----

  Future<Map<String, dynamic>> getServerConfig() async {
    final r = await _fetch('GET', '/api/admin/server-config');
    final data = _decode(r) as Map<String, dynamic>;
    _checkStatus(r, data);
    return data;
  }

  Future<void> updateServerConfig(Map<String, dynamic> data) async {
    final r = await _fetch('PUT', '/api/admin/server-config', body: jsonEncode(data));
    final decoded = _decode(r, allowEmpty: true);
    _checkStatus(r, decoded);
  }
}
