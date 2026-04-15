import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'ws_service.dart';
import 'media_service.dart';
import '../platform/platform_utils.dart';

enum ChannelState { disconnected, connecting, connected, error }

class ChannelConfig {
  String username;
  String password;
  String? targetType;  // 'user' or 'group'
  int? targetId;
  String? targetName;  // display name for UI
  double voxThresholdDb;
  int voxHoldMs;

  ChannelConfig({
    this.username = '',
    this.password = '',
    this.targetType,
    this.targetId,
    this.targetName,
    this.voxThresholdDb = -40,
    this.voxHoldMs = 300,
  });

  bool get isConfigured => username.isNotEmpty && password.isNotEmpty;
  bool get hasTarget => targetType != null && targetId != null;

  Map<String, dynamic> toJson() => {
    'username': username,
    'password': password,
    'targetType': targetType,
    'targetId': targetId,
    'targetName': targetName,
    'voxThresholdDb': voxThresholdDb,
    'voxHoldMs': voxHoldMs,
  };

  factory ChannelConfig.fromJson(Map<String, dynamic> json) => ChannelConfig(
    username: json['username'] ?? '',
    password: json['password'] ?? '',
    targetType: json['targetType'],
    targetId: json['targetId'],
    targetName: json['targetName'],
    voxThresholdDb: (json['voxThresholdDb'] ?? -40).toDouble(),
    voxHoldMs: json['voxHoldMs'] ?? 300,
  );
}

class MatrixChannel extends ChangeNotifier {
  final int index; // 0-15
  String get channelId => 'ch$index';

  ChannelConfig config;
  ChannelState _state = ChannelState.disconnected;
  bool _voxActive = false;
  double _inputLevel = 0;
  String? _error;
  String? _displayName;
  bool _receiving = false;

  // Independent services per channel
  ApiService? _api;
  WsService? _ws;
  MediaService? _media;
  String? _token;

  // Timer for polling input level from JS
  Timer? _levelTimer;

  MatrixChannel({required this.index, ChannelConfig? config})
      : config = config ?? ChannelConfig();

  ChannelState get state => _state;
  bool get voxActive => _voxActive;
  double get inputLevel => _inputLevel;
  String? get error => _error;
  String? get displayName => _displayName;
  bool get receiving => _receiving;

  Future<void> connect() async {
    if (!config.isConfigured) {
      _error = 'No configurado';
      notifyListeners();
      return;
    }

    _state = ChannelState.connecting;
    _error = null;
    notifyListeners();

    try {
      // 1. Create independent services
      final baseUrl = getServerBaseUrl();
      final wsUrl = getServerWsUrl();
      _api = ApiService(baseUrl: baseUrl);
      _ws = WsService(wsUrl: wsUrl);
      _media = MediaService(ws: _ws!);

      // 2. Login
      final loginData = await _api!.login(config.username, config.password);
      _token = _api!.token;
      _displayName = loginData['user']?['display_name'] ?? config.username;

      // 3. Setup WS handlers
      _ws!.onMessage('auth_ok', _onAuthOk);
      _ws!.onMessage('newConsumer', _onNewConsumer);
      _ws!.onMessage('consumersClosed', _onConsumersClosed);
      _ws!.onMessage('incoming_audio', _onIncomingAudio);

      // 4. Connect WebSocket
      _ws!.connect(_token!);

    } catch (e) {
      _state = ChannelState.error;
      _error = e.toString().replaceFirst('Exception: ', '');
      notifyListeners();
    }
  }

  void _onAuthOk(Map<String, dynamic> msg) async {
    debugPrint('[TieLine $channelId] WS authenticated as ${config.username}');

    try {
      // Set up consumer stream routing to multi-channel output
      _media!.onConsumerCreated = (consumerId, streamId) {
        // Route consumer audio to our channel in the merger
        Future.delayed(const Duration(milliseconds: 300), () {
          platformRouteAudioStreamToChannel(streamId, index);
          debugPrint('[TieLine $channelId] Consumer routed to output ch $index');
        });
      };

      // Init mediasoup with tie line channel (getUserMedia override returns mono stream)
      await _media!.init(tieLineChannel: index);

      _state = ChannelState.connected;
      notifyListeners();
      debugPrint('[TieLine $channelId] Media ready');

      // Start VOX monitor on the local input stream (from multi-channel splitter)
      _startVox();

      // Start polling input level
      _levelTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        final newLevel = platformGetVoxLevel(channelId);
        if ((newLevel - _inputLevel).abs() > 0.01) {
          _inputLevel = newLevel;
          notifyListeners();
        }
      });

    } catch (e) {
      _state = ChannelState.error;
      _error = 'Media init: $e';
      notifyListeners();
    }
  }

  void _startVox() {
    platformCreateVoxMonitor(
      channelId,
      config.voxThresholdDb,
      config.voxHoldMs,
      _onVoxStart,
      _onVoxStop,
    );
    debugPrint('[TieLine $channelId] VOX started');
  }

  void _onVoxStart() {
    if (_voxActive || !config.hasTarget) return;
    _voxActive = true;
    notifyListeners();

    // PTT start to configured target
    _ws?.send({
      'type': 'ptt_start',
      'targetType': config.targetType,
      'targetId': config.targetId,
    });
    debugPrint('[TieLine $channelId] VOX → PTT start → ${config.targetType}:${config.targetId}');
  }

  void _onVoxStop() {
    if (!_voxActive) return;
    _voxActive = false;
    notifyListeners();

    // PTT stop
    _ws?.send({
      'type': 'ptt_stop',
      'targetType': config.targetType,
      'targetId': config.targetId,
    });
    debugPrint('[TieLine $channelId] VOX → PTT stop');
  }

  void _onNewConsumer(Map<String, dynamic> msg) {
    _media?.handleNewConsumer(msg);
    // Audio routing to multi-channel output is handled by onConsumerCreated callback
    Future.delayed(const Duration(milliseconds: 200), () {
      platformEnsureRemoteAudioPlaying();
    });
  }

  void _onConsumersClosed(Map<String, dynamic> msg) {
    final consumerIds = msg['consumerIds'] as List<dynamic>?;
    if (consumerIds != null && consumerIds.isNotEmpty) {
      _media?.handleConsumersClosedByIds(consumerIds.map((id) => id.toString()).toList());
    } else {
      _media?.handleConsumersClosed(msg['peerId'].toString());
    }
  }

  void _onIncomingAudio(Map<String, dynamic> msg) {
    _receiving = msg['talking'] == true;
    notifyListeners();
  }

  Future<void> disconnect() async {
    // Stop VOX
    platformDestroyVoxMonitor(channelId);
    _levelTimer?.cancel();
    _levelTimer = null;

    // Stop PTT if active
    if (_voxActive && config.hasTarget) {
      _ws?.send({
        'type': 'ptt_stop',
        'targetType': config.targetType,
        'targetId': config.targetId,
      });
    }

    // Cleanup media
    await _media?.dispose();

    // Close WS
    _ws?.dispose();

    // Disconnect output from multi-channel merger
    platformDisconnectOutputChannel(index);

    _api = null;
    _ws = null;
    _media = null;
    _token = null;
    _voxActive = false;
    _inputLevel = 0;
    _receiving = false;
    _state = ChannelState.disconnected;
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }

  // ======================== Persistence ========================

  static Future<List<ChannelConfig>> loadAllConfigs() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString('matrix_configs');
    if (json == null) return List.generate(16, (_) => ChannelConfig());
    try {
      final list = jsonDecode(json) as List;
      final configs = list.map((e) => ChannelConfig.fromJson(e as Map<String, dynamic>)).toList();
      while (configs.length < 16) configs.add(ChannelConfig());
      return configs;
    } catch (_) {
      return List.generate(16, (_) => ChannelConfig());
    }
  }

  static Future<void> saveAllConfigs(List<ChannelConfig> configs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('matrix_configs', jsonEncode(configs.map((c) => c.toJson()).toList()));
  }

  static Future<Map<String, dynamic>> loadGlobalSettings() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'inputDeviceId': prefs.getString('matrix_global_input'),
      'outputDeviceId': prefs.getString('matrix_global_output'),
      'numChannels': prefs.getInt('matrix_global_channels') ?? 16,
    };
  }

  static Future<void> saveGlobalSettings({
    String? inputDeviceId,
    String? outputDeviceId,
    int numChannels = 16,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (inputDeviceId != null) {
      await prefs.setString('matrix_global_input', inputDeviceId);
    }
    if (outputDeviceId != null) {
      await prefs.setString('matrix_global_output', outputDeviceId);
    }
    await prefs.setInt('matrix_global_channels', numChannels);
  }
}
