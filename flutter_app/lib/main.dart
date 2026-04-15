import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/api_service.dart';
import 'services/ws_service.dart';
import 'providers/auth_provider.dart';
import 'providers/intercom_provider.dart';
import 'screens/login_screen.dart';
import 'screens/intercom_screen.dart';
import 'screens/admin_screen.dart';
import 'screens/server_config_screen.dart';
import 'platform/platform_utils.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  platformInit();
  runApp(const IntercomApp());
}

class IntercomApp extends StatefulWidget {
  const IntercomApp({super.key});

  @override
  State<IntercomApp> createState() => _IntercomAppState();
}

class _IntercomAppState extends State<IntercomApp> {
  ApiService? api;
  WsService? ws;
  bool _ready = false;
  bool _hasServerUrl = false;
  int _configVersion = 0; // Forces provider recreation when server changes

  @override
  void initState() {
    super.initState();
    _initServices();
  }

  Future<void> _initServices() async {
    if (!isWeb) {
      await initServerUrls();
      final saved = await getSavedServerUrl();
      _hasServerUrl = saved != null;
    }
    _createServices();
    setState(() => _ready = true);
  }

  void _createServices() {
    ws?.dispose();
    final baseUrl = getServerBaseUrl();
    final wsUrl = getServerWsUrl();
    api = ApiService(baseUrl: baseUrl);
    ws = WsService(wsUrl: wsUrl);
  }

  void _onServerConfigured() {
    _createServices();
    setState(() {
      _hasServerUrl = true;
      _configVersion++; // Force new providers
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: AppColors.background,
          body: const Center(child: CircularProgressIndicator(color: Colors.white)),
        ),
      );
    }

    return MultiProvider(
      key: ValueKey(_configVersion),
      providers: [
        ChangeNotifierProvider(
          create: (_) => AuthProvider(api: api!),
        ),
        ChangeNotifierProvider(
          create: (_) => IntercomProvider(api: api!, ws: ws!),
        ),
      ],
      child: MaterialApp(
        title: 'Winus Intercom',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        initialRoute: isWeb ? '/' : (_hasServerUrl ? '/' : '/server_config'),
        routes: {
          '/': (_) => const LoginScreen(),
          '/intercom': (_) => const IntercomScreen(),
          '/admin': (_) => const AdminScreen(),
          '/server_config': (_) => ServerConfigScreen(
                onConfigured: _onServerConfigured,
              ),
        },
      ),
    );
  }
}
