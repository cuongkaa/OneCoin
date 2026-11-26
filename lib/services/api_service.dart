import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'api_config.dart';

/// Service gọi REST API backend (Tương thích 100% cả Android/iOS/Desktop và Chrome Web)
class ApiService {
  static final ApiService instance = ApiService._();
  ApiService._();

  final http.Client _client = http.Client();

  String? _accessToken;
  String? _refreshToken;
  String? _cachedDeviceId;
  bool _tokensLoaded = false;
  Future<bool>? _refreshFuture;

  bool? _cachedReachable;
  DateTime? _lastReachabilityCheck;
  Future<bool>? _inflightHealthCheck;

  static const Duration _onlineCacheTtl = Duration(seconds: 30);
  static const Duration _offlineCacheTtl = Duration(seconds: 20);
  static const Duration _requestTimeout = Duration(seconds: 10);

  /// Nhận diện mọi lỗi kết nối mạng đa nền tảng (bao gồm SocketException trên Mobile & ClientException 'Failed to fetch' trên Chrome Web)
  static bool _isNetworkException(Object error) {
    if (error is TimeoutException || error is http.ClientException) {
      return true;
    }
    final msg = error.toString();
    return msg.contains('SocketException') ||
        msg.contains('Failed to fetch') ||
        msg.contains('XMLHttpRequest') ||
        msg.contains('Connection refused') ||
        msg.contains('Network is unreachable');
  }

  Future<void> _ensureTokensLoaded() async {
    if (_tokensLoaded) return;
    final prefs = await SharedPreferences.getInstance();
    _accessToken = prefs.getString('jwt_token');
    _refreshToken = prefs.getString('refresh_token');
    _cachedDeviceId = prefs.getString('device_id');
    _tokensLoaded = true;
  }

  Future<String?> getToken() async {
    await _ensureTokensLoaded();
    return _accessToken;
  }

  Future<void> saveTokens({required String accessToken, required String refreshToken}) async {
    _accessToken = accessToken;
    _refreshToken = refreshToken;
    _tokensLoaded = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('jwt_token', accessToken);
    await prefs.setString('refresh_token', refreshToken);
  }

  Future<void> saveToken(String token) async {
    _accessToken = token;
    _tokensLoaded = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('jwt_token', token);
  }

  Future<void> clearToken() async {
    _accessToken = null;
    _refreshToken = null;
    _tokensLoaded = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('jwt_token');
    await prefs.remove('refresh_token');
  }

  Future<bool> hasToken() async {
    final token = await getToken();
    return token != null && token.isNotEmpty;
  }

  Future<Map<String, String>> _headers() async {
    final token = await getToken();
    return {
      'Content-Type': 'application/json',
      // Không gửi 'Connection: keep-alive' trên trình duyệt Chrome để tránh lỗi Forbidden Header / CORS Preflight
      if (!kIsWeb) 'Connection': 'keep-alive',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  void _markReachable(bool value) {
    _cachedReachable = value;
    _lastReachabilityCheck = DateTime.now();
  }

  Future<bool> _tryRefreshToken() {
    if (_refreshFuture != null) return _refreshFuture!;
    _refreshFuture = _doRefreshToken().whenComplete(() {
      _refreshFuture = null;
    });
    return _refreshFuture!;
  }

  Future<bool> _doRefreshToken() async {
    try {
      await _ensureTokensLoaded();
      final refreshToken = _refreshToken;
      if (refreshToken == null || refreshToken.isEmpty) {
        return false;
      }

      final response = await _client
          .post(
            Uri.parse(ApiConfig.refreshToken),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'refreshToken': refreshToken,
              'deviceId': await _getDeviceId(),
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        await saveTokens(
          accessToken: data['token'],
          refreshToken: data['refreshToken'],
        );
        _markReachable(true);
        return true;
      } else if (response.statusCode == 401 || response.statusCode == 403) {
        await clearToken();
        return false;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<String> _getDeviceId() async {
    await _ensureTokensLoaded();
    if (_cachedDeviceId != null) return _cachedDeviceId!;
    final prefs = await SharedPreferences.getInstance();
    _cachedDeviceId = DateTime.now().millisecondsSinceEpoch.toString();
    await prefs.setString('device_id', _cachedDeviceId!);
    return _cachedDeviceId!;
  }

  Future<bool> isServerReachable({
    Duration timeout = const Duration(milliseconds: 2200),
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _cachedReachable != null && _lastReachabilityCheck != null) {
      final age = DateTime.now().difference(_lastReachabilityCheck!);
      final ttl = _cachedReachable! ? _onlineCacheTtl : _offlineCacheTtl;
      if (age < ttl) {
        return _cachedReachable!;
      }
    }

    if (_inflightHealthCheck != null) return _inflightHealthCheck!;

    _inflightHealthCheck = () async {
      try {
        final response = await _client
            .get(Uri.parse(ApiConfig.health))
            .timeout(timeout);
        final ok = response.statusCode == 200;
        _markReachable(ok);
        return ok;
      } catch (_) {
        _markReachable(false);
        return false;
      } finally {
        _inflightHealthCheck = null;
      }
    }();

    return _inflightHealthCheck!;
  }

  Future<Map<String, dynamic>> register({
    required String username,
    required String email,
    required String password,
    String? displayName,
  }) async {
    try {
      final response = await _client
          .post(
            Uri.parse(ApiConfig.register),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'username': username,
              'email': email,
              'password': password,
              'displayName': displayName ?? username,
              'deviceId': await _getDeviceId(),
            }),
          )
          .timeout(const Duration(seconds: 12));

      _markReachable(true);
      final data = jsonDecode(response.body);

      if (response.statusCode == 201) {
        await saveTokens(
          accessToken: data['token'],
          refreshToken: data['refreshToken'] ?? '',
        );
        return {'success': true, 'user': data['user'], 'token': data['token']};
      } else {
        return {
          'success': false,
          'statusCode': response.statusCode,
          'error': data['error'] ?? 'Đăng ký thất bại',
        };
      }
    } catch (e) {
      if (_isNetworkException(e)) {
        _markReachable(false);
        return {
          'success': false,
          'networkError': true,
          'error': 'Không thể kết nối đến máy chủ (${ApiConfig.baseUrl})',
        };
      }
      return {'success': false, 'error': 'Lỗi xử lý phản hồi: $e'};
    }
  }

  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
  }) async {
    try {
      final response = await _client
          .post(
            Uri.parse(ApiConfig.login),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'username': username,
              'password': password,
              'deviceId': await _getDeviceId(),
            }),
          )
          .timeout(const Duration(seconds: 12));

      _markReachable(true);
      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        await saveTokens(
          accessToken: data['token'],
          refreshToken: data['refreshToken'] ?? '',
        );
        return {'success': true, 'user': data['user'], 'token': data['token']};
      } else {
        return {
          'success': false,
          'statusCode': response.statusCode,
          'error': data['error'] ?? 'Đăng nhập thất bại',
        };
      }
    } catch (e) {
      if (_isNetworkException(e)) {
        _markReachable(false);
        return {
          'success': false,
          'networkError': true,
          'error': 'Không thể kết nối đến máy chủ (${ApiConfig.baseUrl})',
        };
      }
      return {'success': false, 'error': 'Lỗi xử lý phản hồi: $e'};
    }
  }

  Future<Map<String, dynamic>> getProfile() => _authenticatedGet(ApiConfig.profile);

  Future<Map<String, dynamic>> updateProfile({
    String? displayName,
    String? username,
  }) {
    return _authenticatedPut(ApiConfig.profile, {
      if (displayName != null) 'displayName': displayName,
      if (username != null) 'username': username,
    });
  }

  Future<Map<String, dynamic>> changePassword({
    required String oldPassword,
    required String newPassword,
  }) {
    return _authenticatedPut(ApiConfig.changePassword, {
      'oldPassword': oldPassword,
      'newPassword': newPassword,
    });
  }

  Future<Map<String, dynamic>> _authenticatedGet(String url) async {
    var result = await get(url);
    if (result['statusCode'] == 401 && await _tryRefreshToken()) {
      result = await get(url);
    }
    return result;
  }

  Future<Map<String, dynamic>> _authenticatedPut(String url, Map<String, dynamic> body) async {
    var result = await put(url, body);
    if (result['statusCode'] == 401 && await _tryRefreshToken()) {
      result = await put(url, body);
    }
    return result;
  }

  Future<Map<String, dynamic>> get(String url) async {
    try {
      var response = await _client
          .get(Uri.parse(url), headers: await _headers())
          .timeout(_requestTimeout);
      if (response.statusCode == 401 && await _tryRefreshToken()) {
        response = await _client
            .get(Uri.parse(url), headers: await _headers())
            .timeout(_requestTimeout);
      }
      _markReachable(true);
      return {
        'success': response.statusCode == 200,
        'data': jsonDecode(response.body),
        'statusCode': response.statusCode,
      };
    } catch (e) {
      if (_isNetworkException(e)) {
        _markReachable(false);
        return {'success': false, 'networkError': true, 'error': 'Mất kết nối máy chủ'};
      }
      return {'success': false, 'error': 'Lỗi: $e'};
    }
  }

  Future<Map<String, dynamic>> post(String url, Map<String, dynamic> body) async {
    try {
      final encoded = jsonEncode(body);
      var response = await _client
          .post(Uri.parse(url), headers: await _headers(), body: encoded)
          .timeout(_requestTimeout);

      if (response.statusCode == 401 && await _tryRefreshToken()) {
        response = await _client
            .post(Uri.parse(url), headers: await _headers(), body: encoded)
            .timeout(_requestTimeout);
      }
      _markReachable(true);
      return {
        'success': response.statusCode == 200 || response.statusCode == 201,
        'data': jsonDecode(response.body),
        'statusCode': response.statusCode,
      };
    } catch (e) {
      if (_isNetworkException(e)) {
        _markReachable(false);
        return {'success': false, 'networkError': true, 'error': 'Mất kết nối máy chủ'};
      }
      return {'success': false, 'error': 'Lỗi: $e'};
    }
  }

  Future<Map<String, dynamic>> put(String url, Map<String, dynamic> body) async {
    try {
      final encoded = jsonEncode(body);
      var response = await _client
          .put(Uri.parse(url), headers: await _headers(), body: encoded)
          .timeout(_requestTimeout);

      if (response.statusCode == 401 && await _tryRefreshToken()) {
        response = await _client
            .put(Uri.parse(url), headers: await _headers(), body: encoded)
            .timeout(_requestTimeout);
      }
      _markReachable(true);
      return {
        'success': response.statusCode == 200,
        'data': jsonDecode(response.body),
        'statusCode': response.statusCode,
      };
    } catch (e) {
      if (_isNetworkException(e)) {
        _markReachable(false);
        return {'success': false, 'networkError': true, 'error': 'Mất kết nối máy chủ'};
      }
      return {'success': false, 'error': 'Lỗi: $e'};
    }
  }

  Future<Map<String, dynamic>> delete(String url) async {
    try {
      var response = await _client
          .delete(Uri.parse(url), headers: await _headers())
          .timeout(_requestTimeout);

      if (response.statusCode == 401 && await _tryRefreshToken()) {
        response = await _client
            .delete(Uri.parse(url), headers: await _headers())
            .timeout(_requestTimeout);
      }
      _markReachable(true);
      return {
        'success': response.statusCode == 200,
        'data': jsonDecode(response.body),
        'statusCode': response.statusCode,
      };
    } catch (e) {
      if (_isNetworkException(e)) {
        _markReachable(false);
        return {'success': false, 'networkError': true, 'error': 'Mất kết nối máy chủ'};
      }
      return {'success': false, 'error': 'Lỗi: $e'};
    }
  }

  Future<Map<String, dynamic>> syncUpload(Map<String, dynamic> allData) =>
      post(ApiConfig.syncUpload, allData);

  Future<Map<String, dynamic>> syncDownload() => get(ApiConfig.syncDownload);
}
