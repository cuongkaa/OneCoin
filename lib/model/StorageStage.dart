import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/database_helper.dart';
import '../services/api_service.dart';
import '../services/api_config.dart';
import '../services/sync_service.dart';
import '../services/sync_queue.dart';

class StorageStageProxy extends ChangeNotifier {
  static const int _kdfIterations = 10000;
  static const int _maxPinAttempts = 5;
  static const int _pinLockoutSeconds = 60;

  bool _isLogin = false;
  Map<String, dynamic>? _currentUser;
  bool _isOnline = false;
  final Completer<void> _initCompleter = Completer<void>();

  StorageStageProxy() {
    _init();
  }

  /// Đảm bảo dữ liệu phiên đăng nhập đã đọc xong từ SharedPreferences trước khi điều hướng
  Future<void> ensureInitialized() => _initCompleter.future;

  Future<void> _init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _isLogin = prefs.getBool('isLogin') ?? false;
      final userStr = prefs.getString('user');
      if (userStr != null) {
        _currentUser = jsonDecode(userStr);
      }
      if (!_initCompleter.isCompleted) {
        _initCompleter.complete();
      }
      notifyListeners();

      // Kiểm tra kết nối server bất đồng bộ không chặn màn hình khởi động
      _isOnline = await ApiService.instance.isServerReachable();
      notifyListeners();
    } catch (e) {
      if (!_initCompleter.isCompleted) {
        _initCompleter.complete();
      }
    }
  }

  bool get isLogin => _isLogin;
  bool get isOnline => _isOnline;

  set isLogin(bool value) {
    _isLogin = value;
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('isLogin', value);
    });
    notifyListeners();
  }

  Future<void> saveInfoUser(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }

  Future<String?> getInfoUserAsync(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key);
  }

  /// Legacy SHA-256 (chỉ dùng để tương thích ngược và tự nâng cấp tài khoản cũ)
  static String _legacyHash(String input) {
    return sha256.convert(utf8.encode(input)).toString();
  }

  /// Băm mật khẩu / mã PIN an toàn với Salt ngẫu nhiên 16-byte + 10.000 vòng lặp SHA-256
  static String _hashSecretWithSalt(String secret, {String? saltHex}) {
    final String actualSalt;
    if (saltHex != null && saltHex.isNotEmpty) {
      actualSalt = saltHex;
    } else {
      final rng = Random.secure();
      final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
      actualSalt = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    }

    List<int> digestBytes = utf8.encode('$actualSalt:$secret');
    for (int i = 0; i < _kdfIterations; i++) {
      digestBytes = sha256.convert(digestBytes).bytes;
    }
    final hashHex = digestBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'v2\$$actualSalt\$$hashHex';
  }

  /// So sánh hằng thời gian (Constant-time comparison) hỗ trợ cả chuẩn v2$ và legacy
  static bool _verifyHashedSecret(String input, String storedHash) {
    if (storedHash.startsWith('v2\$')) {
      final parts = storedHash.split('\$');
      if (parts.length != 3) return false;
      final candidate = _hashSecretWithSalt(input, saltHex: parts[1]);
      return _constantTimeEquals(candidate, storedHash);
    }
    return _constantTimeEquals(_legacyHash(input), storedHash);
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Chạy thuật toán băm trên Isolate phụ (Mobile/Desktop) và fallback an toàn trên Chrome Web (kIsWeb)
  static Future<String> _hashSecretAsync(String secret) async {
    if (kIsWeb) {
      await Future<void>.delayed(Duration.zero);
      return _hashSecretWithSalt(secret);
    }
    try {
      return await Isolate.run(() => _hashSecretWithSalt(secret));
    } on UnsupportedError {
      return _hashSecretWithSalt(secret);
    }
  }

  static Future<bool> _verifySecretAsync(String input, String storedHash) async {
    if (kIsWeb) {
      await Future<void>.delayed(Duration.zero);
      return _verifyHashedSecret(input, storedHash);
    }
    try {
      return await Isolate.run(() => _verifyHashedSecret(input, storedHash));
    } on UnsupportedError {
      return _verifyHashedSecret(input, storedHash);
    }
  }

  /// Đăng ký: Gọi thẳng API (không chờ /health dư thừa), tự động lưu local nếu offline
  Future<String?> registerUser({
    required String username,
    required String email,
    required String password,
    required String displayName,
  }) async {
    final result = await ApiService.instance.register(
      username: username,
      email: email,
      password: password,
      displayName: displayName,
    );

    if (result['networkError'] != true) {
      _isOnline = true;
      if (result['success'] == true) {
        final user = result['user'];
        await _saveUserLocally(
          id: user['id'].toString(),
          username: user['username'].toString(),
          email: user['email'].toString(),
          displayName: (user['displayName'] ?? displayName).toString(),
        );

        final hashed = await _hashSecretAsync(password);
        final db = await DatabaseHelper.instance.database;
        try {
          await db.insert('users', {
            'id': user['id'].toString(),
            'username': user['username'],
            'email': user['email'],
            'password': hashed,
          });
        } catch (_) {}

        unawaited(ApiService.instance.post(ApiConfig.groupsInit, {}));
        return null;
      } else {
        return result['error'];
      }
    }

    _isOnline = false;
    // Fallback: Đăng ký local tức thì (offline)
    final db = await DatabaseHelper.instance.database;

    final usernameCheck = await db.query('users', where: 'username = ?', whereArgs: [username]);
    if (usernameCheck.isNotEmpty) {
      return "Tên đăng nhập đã tồn tại";
    }

    final emailCheck = await db.query('users', where: 'email = ?', whereArgs: [email]);
    if (emailCheck.isNotEmpty) {
      return "Email đã được sử dụng";
    }

    final randomDigits = 10000 + DateTime.now().millisecondsSinceEpoch % 90000;
    final id = '17710$randomDigits';
    final hashed = await _hashSecretAsync(password);
    await db.insert('users', {
      'id': id,
      'username': username,
      'email': email,
      'password': hashed,
    });

    await saveInfoUser("displayName_$username", displayName);
    await saveInfoUser("unsynced_account_$username", "1");

    return null;
  }

  /// Đăng nhập: Gọi thẳng API 1 bước (tiết kiệm 1 vòng RTT), tự động fallback SQLite ngay khi offline
  Future<String?> loginUser({
    required String username,
    required String password,
  }) async {
    final db = await DatabaseHelper.instance.database;
    final result = await ApiService.instance.login(
      username: username,
      password: password,
    );

    if (result['networkError'] != true) {
      _isOnline = true;
      if (result['success'] == true) {
        final user = result['user'];
        await _saveUserLocally(
          id: user['id'].toString(),
          username: user['username'].toString(),
          email: user['email'].toString(),
          displayName: (user['displayName'] ?? user['username']).toString(),
        );

        final hashed = await _hashSecretAsync(password);
        final existing = await db.query('users', where: 'id = ?', whereArgs: [user['id'].toString()]);
        if (existing.isEmpty) {
          try {
            await db.insert('users', {
              'id': user['id'].toString(),
              'username': user['username'],
              'email': user['email'],
              'password': hashed,
            });
          } catch (_) {}
        } else {
          await db.update(
            'users',
            {'password': hashed},
            where: 'id = ?',
            whereArgs: [user['id'].toString()],
          );
        }

        await SyncService.instance.downloadAllData();
        isLogin = true;
        return null;
      }

      // Kiểm tra trường hợp tài khoản được tạo lúc Offline
      final localMatches = await db.query(
        'users',
        where: 'username = ? OR email = ?',
        whereArgs: [username, username],
      );
      if (localMatches.isNotEmpty) {
        final localUser = localMatches.first;
        final storedPass = localUser['password']?.toString() ?? '';
        if (await _verifySecretAsync(password, storedPass)) {
          final localUsername = localUser['username'].toString();
          final localEmail = localUser['email'].toString();
          final displayName = await getInfoUserAsync("displayName_$localUsername") ?? localUsername;

          final regRes = await ApiService.instance.register(
            username: localUsername,
            email: localEmail,
            password: password,
            displayName: displayName,
          );
          if (regRes['success'] == true) {
            final serverUser = regRes['user'];
            await _saveUserLocally(
              id: serverUser['id'].toString(),
              username: serverUser['username'].toString(),
              email: serverUser['email'].toString(),
              displayName: (serverUser['displayName'] ?? displayName).toString(),
            );
            unawaited(SyncService.instance.uploadAllData());
            final prefs = await SharedPreferences.getInstance();
            await prefs.remove("unsynced_account_$localUsername");
            isLogin = true;
            return null;
          }
        }
      }

      return result['error'];
    }

    _isOnline = false;
    // Fallback: Đăng nhập local tức thì (offline)
    final candidates = await db.query(
      'users',
      where: 'username = ? OR email = ?',
      whereArgs: [username, username],
    );

    Map<String, Object?>? matchedUser;
    for (final row in candidates) {
      final storedHash = row['password']?.toString() ?? '';
      if (await _verifySecretAsync(password, storedHash)) {
        matchedUser = row;
        if (!storedHash.startsWith('v2\$')) {
          final upgraded = await _hashSecretAsync(password);
          await db.update(
            'users',
            {'password': upgraded},
            where: 'id = ?',
            whereArgs: [row['id']],
          );
        }
        break;
      }
    }

    if (matchedUser == null) {
      return "Sai tên đăng nhập hoặc mật khẩu";
    }

    final displayName =
        await getInfoUserAsync("displayName_${matchedUser['username']}") ?? matchedUser['username'];

    await _saveUserLocally(
      id: matchedUser['id'].toString(),
      username: matchedUser['username'].toString(),
      email: matchedUser['email'].toString(),
      displayName: displayName.toString(),
    );

    isLogin = true;
    return null;
  }

  Future<void> _saveUserLocally({
    required String id,
    required String username,
    required String email,
    required String displayName,
  }) async {
    final userJson = jsonEncode({
      'id': id,
      'name': displayName,
      'email': email,
      'username': username,
    });

    await saveInfoUser('user', userJson);
    await saveInfoUser("displayName_$username", displayName);
    _currentUser = jsonDecode(userJson);
  }

  Future<String?> changePassword({
    required String username,
    required String oldPassword,
    required String newPassword,
  }) async {
    _isOnline = await ApiService.instance.isServerReachable();

    if (_isOnline) {
      final result = await ApiService.instance.changePassword(
        oldPassword: oldPassword,
        newPassword: newPassword,
      );

      if (result['success'] == true) {
        final db = await DatabaseHelper.instance.database;
        await db.update(
          'users',
          {'password': _hashSecretWithSalt(newPassword)},
          where: 'username = ?',
          whereArgs: [username],
        );
        return null;
      } else {
        return result['error'];
      }
    }

    // Fallback: Offline
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query('users', where: 'username = ?', whereArgs: [username]);
    if (rows.isEmpty || !_verifyHashedSecret(oldPassword, rows.first['password']?.toString() ?? '')) {
      return "Mật khẩu cũ không chính xác";
    }

    await db.update(
      'users',
      {'password': _hashSecretWithSalt(newPassword)},
      where: 'username = ?',
      whereArgs: [username],
    );

    return null;
  }

  Future<String?> updateProfile({
    required String oldUsername,
    required String newUsername,
    required String newName,
  }) async {
    _isOnline = await ApiService.instance.isServerReachable();

    if (_isOnline) {
      final result = await ApiService.instance.updateProfile(
        displayName: newName,
        username: newUsername,
      );

      if (result['success'] != true) {
        return result['error'];
      }
    }

    final db = await DatabaseHelper.instance.database;

    if (oldUsername != newUsername) {
      final usernameCheck = await db.query('users', where: 'username = ?', whereArgs: [newUsername]);
      if (usernameCheck.isNotEmpty && !_isOnline) {
        return "Tên đăng nhập đã tồn tại";
      }

      await db.update('users', {'username': newUsername}, where: 'username = ?', whereArgs: [oldUsername]);

      final prefs = await SharedPreferences.getInstance();

      final phone = prefs.getString("phone_$oldUsername");
      if (phone != null) {
        await prefs.setString("phone_$newUsername", phone);
        await prefs.remove("phone_$oldUsername");
      }

      final pin = prefs.getString("pin_$oldUsername");
      if (pin != null) {
        await prefs.setString("pin_$newUsername", pin);
        await prefs.remove("pin_$oldUsername");
      }

      await prefs.remove("displayName_$oldUsername");
    }

    await saveInfoUser("displayName_$newUsername", newName);

    if (_currentUser != null) {
      _currentUser!['name'] = newName;
      _currentUser!['username'] = newUsername;
      await saveInfoUser('user', jsonEncode(_currentUser));
      notifyListeners();
    }

    return null;
  }

  Future<void> savePhone(String username, String phone) async {
    await saveInfoUser("phone_$username", phone);
  }

  Future<String?> getPhone(String username) async {
    return await getInfoUserAsync("phone_$username");
  }

  // ========================
  // PIN SECURITY (Salted KDF + Brute-Force Lockout)
  // ========================
  String get activePinKey {
    final uname = _currentUser?['username']?.toString();
    return (uname != null && uname.isNotEmpty) ? uname : '__guest__';
  }

  Future<int> getPinLockRemainingSeconds(String username) async {
    final key = username.isEmpty ? activePinKey : username;
    final prefs = await SharedPreferences.getInstance();
    final lockUntilMs = prefs.getInt('pin_lock_until_$key') ?? 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (lockUntilMs > nowMs) {
      return ((lockUntilMs - nowMs) / 1000).ceil();
    }
    return 0;
  }

  Future<void> savePin(String username, String pinCode) async {
    final key = username.isEmpty ? activePinKey : username;
    final hashedPin = await _hashSecretAsync(pinCode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("pin_$key", hashedPin);
    await prefs.remove("pin_failed_attempts_$key");
    await prefs.remove("pin_lock_until_$key");
  }

  Future<void> removePin(String username) async {
    final key = username.isEmpty ? activePinKey : username;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove("pin_$key");
    await prefs.remove("pin_failed_attempts_$key");
    await prefs.remove("pin_lock_until_$key");
  }

  Future<bool> verifyPin(String username, String pinCode) async {
    final key = username.isEmpty ? activePinKey : username;
    final remainingLock = await getPinLockRemainingSeconds(key);
    if (remainingLock > 0) {
      return false;
    }

    final prefs = await SharedPreferences.getInstance();
    final savedPinHash = prefs.getString("pin_$key");
    if (savedPinHash == null) {
      return true;
    }

    final ok = await _verifySecretAsync(pinCode, savedPinHash);
    if (ok) {
      await prefs.remove("pin_failed_attempts_$key");
      await prefs.remove("pin_lock_until_$key");
      if (!savedPinHash.startsWith('v2\$')) {
        await prefs.setString("pin_$key", await _hashSecretAsync(pinCode));
      }
      return true;
    } else {
      final attempts = (prefs.getInt("pin_failed_attempts_$key") ?? 0) + 1;
      if (attempts >= _maxPinAttempts) {
        final lockUntil = DateTime.now().millisecondsSinceEpoch + (_pinLockoutSeconds * 1000);
        await prefs.setInt("pin_lock_until_$key", lockUntil);
        await prefs.setInt("pin_failed_attempts_$key", 0);
      } else {
        await prefs.setInt("pin_failed_attempts_$key", attempts);
      }
      return false;
    }
  }

  Future<bool> hasPin([String? username]) async {
    final key = (username == null || username.isEmpty) ? activePinKey : username;
    final savedPinHash = await getInfoUserAsync("pin_$key");
    return savedPinHash != null && savedPinHash.isNotEmpty;
  }

  Map<String, dynamic>? getCurrentUser() {
    return _currentUser;
  }

  Future<void> logoutUser() async {
    final isOnline = await ApiService.instance.isServerReachable();
    if (isOnline && await ApiService.instance.hasToken()) {
      await SyncQueue.instance.processQueue();
      await SyncService.instance.uploadAllData();
      try {
        final prefs = await SharedPreferences.getInstance();
        final refreshToken = prefs.getString('refresh_token');
        if (refreshToken != null) {
          await ApiService.instance.post(ApiConfig.logout, {
            'refreshToken': refreshToken,
          });
        }
      } catch (_) {}
    }

    isLogin = false;
    _currentUser = null;
    await ApiService.instance.clearToken();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('user');

    await DatabaseHelper.instance.clearUserData();
    notifyListeners();
  }

  Future<void> checkOnlineStatus() async {
    _isOnline = await ApiService.instance.isServerReachable();
    notifyListeners();
  }
}
