import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/auth_provider.dart';
import '../platform/platform_utils.dart';
import '../theme/app_theme.dart';

class LoginScreen extends StatefulWidget {
  /// Called when the user changes the server URL so the parent can recreate
  /// ApiService / WsService / providers.
  final VoidCallback? onServerChanged;

  const LoginScreen({super.key, this.onServerChanged});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _serverCtrl = TextEditingController();
  bool _autoLogging = true;

  // Server config (native only)
  static const String _historyKey = 'intercom_server_urls';
  static const int _maxHistory = 10;
  List<String> _serverHistory = [];
  String? _currentServerUrl; // URL the services are currently pointing to
  bool _serverExpanded = false;

  @override
  void initState() {
    super.initState();
    _loadServerInfo();
    _tryAutoLogin();
  }

  Future<void> _loadServerInfo() async {
    if (isWeb) return;
    final saved = await getSavedServerUrl();
    final prefs = await SharedPreferences.getInstance();
    List<String> hist = [];
    final raw = prefs.getString(_historyKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) hist = decoded.map((e) => e.toString()).toList();
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _serverHistory = hist;
      _currentServerUrl = saved;
      _serverCtrl.text = saved ?? 'https://huin.tv:8443';
    });
  }

  Future<void> _tryAutoLogin() async {
    // After a server switch, skip auto-login so the user can review/edit
    // credentials for the new server before connecting.
    final prefs = await SharedPreferences.getInstance();
    final skipAuto = prefs.getBool('skip_auto_login') ?? false;
    if (skipAuto) {
      await prefs.remove('skip_auto_login');
      if (!mounted) return;
      _userCtrl.text = prefs.getString('auth_username') ?? '';
      _passCtrl.text = prefs.getString('auth_password') ?? '';
      setState(() => _autoLogging = false);
      return;
    }

    final auth = context.read<AuthProvider>();
    final ok = await auth.autoLogin();
    if (ok && mounted) {
      Navigator.pushReplacementNamed(context, '/intercom');
      return;
    }
    if (!mounted) return;
    try {
      _userCtrl.text = prefs.getString('auth_username') ?? '';
      _passCtrl.text = prefs.getString('auth_password') ?? '';
    } catch (_) {}
    setState(() => _autoLogging = false);
  }

  /// Save credentials so auto-login can use them after a server switch rebuild.
  Future<void> _persistCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auth_username', _userCtrl.text.trim());
    await prefs.setString('auth_password', _passCtrl.text);
  }

  Future<void> _saveHistory(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    _serverHistory.remove(trimmed);
    _serverHistory.insert(0, trimmed);
    if (_serverHistory.length > _maxHistory) {
      _serverHistory = _serverHistory.sublist(0, _maxHistory);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_historyKey, jsonEncode(_serverHistory));
  }

  Future<void> _deleteFromHistory(String url) async {
    setState(() => _serverHistory.remove(url));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_historyKey, jsonEncode(_serverHistory));
  }

  Future<void> _login() async {
    final serverUrl = _serverCtrl.text.trim();

    // Guard against race condition: _loadServerInfo() is async and might not
    // have finished setting _currentServerUrl yet. Read from prefs directly
    // so we never compare against null and trigger a spurious rebuild.
    _currentServerUrl ??= await getSavedServerUrl();

    // If the server URL changed, save everything and let the parent rebuild
    // with new services. The skip_auto_login flag ensures the rebuilt
    // LoginScreen shows the form instead of auto-connecting.
    if (!isWeb && serverUrl.isNotEmpty && serverUrl != _currentServerUrl) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('skip_auto_login', true);
      await _persistCredentials();
      await setServerUrl(serverUrl);
      await _saveHistory(serverUrl);
      widget.onServerChanged?.call();
      return;
    }

    final auth = context.read<AuthProvider>();
    final ok = await auth.login(_userCtrl.text.trim(), _passCtrl.text);
    if (ok && mounted) {
      Navigator.pushReplacementNamed(context, '/intercom');
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.backgroundAlt, AppColors.background],
          ),
        ),
        child: _autoLogging
            ? const Center(child: CircularProgressIndicator(color: Colors.white))
            : Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: SizedBox(
              width: 380,
              child: Card(
                color: AppColors.surface,
                elevation: 12,
                shadowColor: Colors.black.withValues(alpha: 0.35),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Logo
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: AppColors.surfaceLight,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        padding: const EdgeInsets.all(8),
                        child: Image.asset('assets/winus_logo.png', fit: BoxFit.contain),
                      ),
                      const SizedBox(height: 16),
                      const Text('Winus Intercom',
                          style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                      const SizedBox(height: 4),
                      const Text('Enter your credentials',
                          style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),

                      // ── Server section (native only) ──
                      if (!isWeb) ...[
                        const SizedBox(height: 20),
                        _buildServerSection(),
                      ],

                      const SizedBox(height: 24),
                      TextField(
                        controller: _userCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Username',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                        onSubmitted: (_) => _login(),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _passCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Password',
                          prefixIcon: Icon(Icons.lock_outline),
                        ),
                        obscureText: true,
                        onSubmitted: (_) => _login(),
                      ),
                      if (auth.error != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.red.shade900.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.red.shade300.withValues(alpha: 0.4)),
                          ),
                          child: Text(auth.error!,
                              style: TextStyle(color: Colors.red.shade700, fontSize: 13),
                              textAlign: TextAlign.center),
                        ),
                      ],
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        height: 46,
                        child: ElevatedButton(
                          onPressed: auth.loading ? null : _login,
                          style: raisedButtonStyle(),
                          child: auth.loading
                              ? const SizedBox(width: 22, height: 22,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Text('Login',
                                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Collapsible server URL section with history.
  Widget _buildServerSection() {
    return Column(
      children: [
        // Tap to expand/collapse
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _serverExpanded = !_serverExpanded),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.backgroundAlt,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                const Icon(Icons.dns, size: 18, color: AppColors.textSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _currentServerUrl ?? _serverCtrl.text,
                    style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(
                  _serverExpanded ? Icons.expand_less : Icons.expand_more,
                  color: AppColors.textSecondary,
                  size: 20,
                ),
              ],
            ),
          ),
        ),

        // Expanded: URL field + history
        if (_serverExpanded) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _serverCtrl,
            minLines: 1,
            maxLines: 2,
            keyboardType: TextInputType.url,
            style: const TextStyle(fontSize: 14),
            decoration: const InputDecoration(
              labelText: 'Server URL',
              hintText: 'https://winus.overon.es:8443',
              prefixIcon: Icon(Icons.link),
              contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
          ),
          if (_serverHistory.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.history, size: 16, color: AppColors.textSecondary),
                const SizedBox(width: 6),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.backgroundAlt,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.border),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _serverHistory.contains(_serverCtrl.text)
                            ? _serverCtrl.text
                            : null,
                        isExpanded: true,
                        isDense: true,
                        hint: const Text('Saved servers',
                            style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                        icon: const Icon(Icons.arrow_drop_down,
                            color: AppColors.textSecondary, size: 20),
                        items: _serverHistory
                            .map((url) => DropdownMenuItem<String>(
                                  value: url,
                                  child: Text(url,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 13)),
                                ))
                            .toList(),
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() => _serverCtrl.text = v);
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: 'Remove from history',
                  iconSize: 20,
                  icon: const Icon(Icons.delete_outline, color: AppColors.error),
                  onPressed: () {
                    final target = _serverHistory.contains(_serverCtrl.text)
                        ? _serverCtrl.text
                        : (_serverHistory.isNotEmpty ? _serverHistory.first : null);
                    if (target != null) _deleteFromHistory(target);
                  },
                ),
              ],
            ),
          ],
        ],
      ],
    );
  }

  @override
  void dispose() {
    _userCtrl.dispose();
    _passCtrl.dispose();
    _serverCtrl.dispose();
    super.dispose();
  }
}
