import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';

class AuthProvider extends ChangeNotifier {
  final ApiService api;

  Map<String, dynamic>? _user;
  bool _loading = false;
  String? _error;
  /// When login is ambiguous, the server returns candidate companies.
  List<Map<String, dynamic>>? _companyChoices;

  AuthProvider({required this.api});

  Map<String, dynamic>? get user => _user;
  bool get isLoggedIn => _user != null;
  bool get isAdmin {
    final r = _user?['role'];
    return r == 'admin' || r == 'superuser' || r == 'superadmin';
  }
  bool get isSuperadmin => _user?['role'] == 'superadmin';
  String? get token => api.token;
  bool get loading => _loading;
  String? get error => _error;
  List<Map<String, dynamic>>? get companyChoices => _companyChoices;

  /// Try auto-login with saved credentials. Returns true if successful.
  Future<bool> autoLogin() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedUser = prefs.getString('auth_username');
      final savedPass = prefs.getString('auth_password');
      if (savedUser == null || savedPass == null) return false;
      final savedCo = prefs.getInt('auth_company_id');
      return await login(savedUser, savedPass, companyId: savedCo, save: false);
    } catch (_) {
      return false;
    }
  }

  Future<bool> login(
    String username,
    String password, {
    bool save = true,
    int? companyId,
    String? company,
  }) async {
    _loading = true;
    _error = null;
    _companyChoices = null;
    notifyListeners();

    try {
      final data = await api.login(
        username,
        password,
        companyId: companyId,
        company: company,
      );
      _user = data['user'];
      _loading = false;
      notifyListeners();
      if (save) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('auth_username', username);
        await prefs.setString('auth_password', password);
        final cid = _user?['company_id'];
        if (cid is int) {
          await prefs.setInt('auth_company_id', cid);
        } else if (cid != null) {
          await prefs.setInt('auth_company_id', int.parse('$cid'));
        } else {
          await prefs.remove('auth_company_id');
        }
      }
      return true;
    } on CompanyRequiredException catch (e) {
      _companyChoices = e.companies;
      _error = e.message;
      _loading = false;
      notifyListeners();
      return false;
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
      _loading = false;
      notifyListeners();
      return false;
    }
  }

  void clearCompanyChoices() {
    _companyChoices = null;
    notifyListeners();
  }

  Future<void> logout() async {
    _user = null;
    _companyChoices = null;
    api.setToken(null);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_username');
    await prefs.remove('auth_password');
    await prefs.remove('auth_company_id');
    notifyListeners();
  }
}
