import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';

class AuthProvider extends ChangeNotifier {
  final ApiService api;

  Map<String, dynamic>? _user;
  bool _loading = false;
  String? _error;

  AuthProvider({required this.api});

  Map<String, dynamic>? get user => _user;
  bool get isLoggedIn => _user != null;
  bool get isAdmin => _user?['role'] == 'admin' || _user?['role'] == 'superuser';
  String? get token => api.token;
  bool get loading => _loading;
  String? get error => _error;

  /// Try auto-login with saved credentials. Returns true if successful.
  Future<bool> autoLogin() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedUser = prefs.getString('auth_username');
      final savedPass = prefs.getString('auth_password');
      if (savedUser == null || savedPass == null) return false;
      return await login(savedUser, savedPass, save: false);
    } catch (_) {
      return false;
    }
  }

  Future<bool> login(String username, String password, {bool save = true}) async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final data = await api.login(username, password);
      _user = data['user'];
      _loading = false;
      notifyListeners();
      // Save credentials on successful login
      if (save) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('auth_username', username);
        await prefs.setString('auth_password', password);
      }
      return true;
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
      _loading = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> logout() async {
    _user = null;
    api.setToken(null);
    // Clear saved credentials
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_username');
    await prefs.remove('auth_password');
    notifyListeners();
  }
}
