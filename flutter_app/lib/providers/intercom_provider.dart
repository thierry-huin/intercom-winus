import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../services/ws_service.dart';
import '../services/media_service.dart';
import '../platform/platform_utils.dart';

class IntercomProvider extends ChangeNotifier {
  final ApiService api;
  final WsService ws;
  late final MediaService media;

  List<Map<String, dynamic>> _userTargets = [];
  List<Map<String, dynamic>> _groupTargets = [];
  Set<int> _onlineUserIds = {};
  bool _connected = false;
  bool _mediaReady = false;
  final Set<String> _activePtts = {}; // 'user:3', 'group:1', etc.
  String? _incomingFrom;
  String? _error;
  int _initVersion = 0; // Monotonic counter to cancel stale init sequences

  // Audio device selection
  List<Map<String, String>> _audioInputs = [];
  List<Map<String, String>> _audioOutputs = [];
  String? _selectedInputId;
  String? _selectedOutputId;

  // Latch mode per target: key = 'user:id' or 'group:id', value = true if latch
  final Map<String, bool> _latchModes = {};

  // PTT retry tracking for no_consumers denials
  final Map<String, int> _pttRetries = {};

  // Mic mute (blocks all outgoing PTT)
  bool _micMuted = false;

  // Muted incoming users (local-only, not permanent)
  final Set<int> _mutedUserIds = {};

  // Per-user volume (0.0 to 1.0, default 1.0)
  final Map<int, double> _userVolumes = {};

  // Per-group volume (0.0 to 1.0, default 1.0)
  final Map<int, double> _groupVolumes = {};

  String? _lastToken;
  bool _disposed = false;
  bool _inPipMode = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _rttTimer;
  double? _rttMs;

  IntercomProvider({required this.api, required this.ws}) {
    media = MediaService(ws: ws);
    _startNetworkMonitor();
    _loadSavedVolumes();
  }

  void _startNetworkMonitor() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final hasNetwork = results.any((r) => r != ConnectivityResult.none);
      // Reconnect on ANY network availability (WiFi, mobile, etc.)
      // _lastToken is null only after explicit disconnect/kick
      if (hasNetwork && _lastToken != null && !_disposed) {
        debugPrint('[Intercom] Network available — forcing reconnect');
        Future.delayed(const Duration(milliseconds: 1500), () {
          if (_lastToken != null && !_disposed) {
            ws.forceReconnect(_lastToken!);
          }
        });
      }
    });
  }

  // Getters
  List<Map<String, dynamic>> get userTargets => _userTargets;
  List<Map<String, dynamic>> get groupTargets => _groupTargets;
  Set<int> get onlineUserIds => _onlineUserIds;
  bool get connected => _connected;
  bool get mediaReady => _mediaReady;
  bool get isTalking => _activePtts.isNotEmpty;
  bool isTalkingTo(String targetType, int targetId) => _activePtts.contains('$targetType:$targetId');
  String? get incomingFrom => _incomingFrom;
  String? get error => _error;
  Set<int> get mutedUserIds => _mutedUserIds;
  List<Map<String, String>> get audioInputs => _audioInputs;
  List<Map<String, String>> get audioOutputs => _audioOutputs;
  String? get selectedInputId => _selectedInputId;
  String? get selectedOutputId => _selectedOutputId;
  bool get micMuted => _micMuted;
  bool get inPipMode => _inPipMode;
  double? get rttMs => _rttMs;

  /// Call when entering/leaving PiP to throttle UI updates
  void setPipMode(bool pip) {
    _inPipMode = pip;
    if (pip) {
      platformReleaseWakeLock();
    } else {
      platformRequestWakeLock();
      notifyListeners(); // Refresh UI on return from PiP
    }
  }

  /// Throttled notifyListeners: skip when in PiP to avoid UI backpressure
  void _notifyIfVisible() {
    if (!_inPipMode) notifyListeners();
  }

  Future<void> connect(String token) async {
    _lastToken = token;
    _error = null;

    // Register WS message handlers
    ws.onMessage('auth_ok', _onAuthOk);
    ws.onMessage('online_users', _onOnlineUsers);
    ws.onMessage('ptt_allowed', _onPttAllowed);
    ws.onMessage('ptt_denied', _onPttDenied);
    ws.onMessage('newConsumer', _onNewConsumer);
    ws.onMessage('consumersClosed', _onConsumersClosed);
    ws.onMessage('incoming_audio', _onIncomingAudio);
    ws.onMessage('transportClosed', _onTransportClosed);
    ws.onMessage('kicked', _onKicked);

    // Connect WebSocket
    ws.connect(token);

    // Load targets
    try {
      final targets = await api.getMyTargets();
      _userTargets = List<Map<String, dynamic>>.from(targets['users'] ?? []);
      // Sort: regular users first, bridge users last
      _userTargets.sort((a, b) {
        final aIsBridge = a['role'] == 'bridge' ? 1 : 0;
        final bIsBridge = b['role'] == 'bridge' ? 1 : 0;
        return aIsBridge - bIsBridge;
      });
      _groupTargets = List<Map<String, dynamic>>.from(targets['groups'] ?? []);
      notifyListeners();
    } catch (e) {
      debugPrint('[Intercom] Error loading targets: $e');
    }
  }

  // ======================== WS HANDLERS ========================

  void _onAuthOk(Map<String, dynamic> msg) async {
    _connected = true;
    final version = ++_initVersion; // Cancel any ongoing transportClosed reinit
    _mediaReady = false;
    notifyListeners();
    debugPrint('[Intercom] WS authenticated (initVersion=$version)');

    for (int attempt = 1; attempt <= 3; attempt++) {
      if (_initVersion != version) return;
      try {
        await media.dispose();
        if (_initVersion != version) return;
        await media.init(inputDeviceId: _selectedInputId);
        if (_initVersion != version) return;
        _mediaReady = true;
        _error = null;
        notifyListeners();
        debugPrint('[Intercom] Media ready (initVersion=$version, attempt=$attempt)');
        await _loadAudioDevices();
        if (_selectedOutputId != null) {
          media.setOutputDevice(_selectedOutputId!);
        }
        _reapplyVolumes();
        _startRttPolling();
        // Release exclusive audio focus so WhatsApp/other VoIP apps can play
        await platformReleaseAudioFocus();
        // Re-establish active latched PTTs that were lost during reconnect
        _resumeActivePtts();
        platformStartForegroundService();
        return; // Success
      } catch (e) {
        if (_initVersion != version) return;
        debugPrint('[Intercom] Media init failed (attempt $attempt/3): $e');
        if (attempt < 3) {
          await Future.delayed(Duration(seconds: attempt * 2));
        } else {
          _error = 'Error media: $e';
          notifyListeners();
        }
      }
    }
  }

  void _onOnlineUsers(Map<String, dynamic> msg) {
    _onlineUserIds = Set<int>.from(
      (msg['userIds'] as List).map((id) => id is int ? id : int.parse(id.toString())),
    );
    _notifyIfVisible();
  }

  void _onPttAllowed(Map<String, dynamic> msg) {
    final type = msg['targetType']?.toString() ?? '';
    final id = msg['targetId'];
    _pttRetries.remove('_retry_$type:$id'); // Clear retry counter on success
    debugPrint('[Intercom] PTT allowed → $type:$id');
  }

  void _onPttDenied(Map<String, dynamic> msg) {
    final type = msg['targetType']?.toString() ?? '';
    final id = msg['targetId'];
    final reason = msg['reason']?.toString() ?? '';
    debugPrint('[Intercom] PTT denied → $type:$id (reason=$reason)');

    // Auto-retry if target hasn't finished media init yet
    if (reason == 'no_consumers') {
      final key = '$type:$id';
      final retryKey = '_retry_$key';
      final retryCount = _pttRetries[retryKey] ?? 0;
      if (retryCount < 3) {
        _pttRetries[retryKey] = retryCount + 1;
        debugPrint('[Intercom] Auto-retry PTT $key (attempt ${retryCount + 1})');
        Future.delayed(const Duration(milliseconds: 1500), () {
          if (_activePtts.contains(key) && _mediaReady) {
            ws.send({'type': 'ptt_start', 'targetType': type, 'targetId': id});
          } else {
            _pttRetries.remove(retryKey);
          }
        });
        return; // Don't remove from _activePtts — keep button active during retry
      }
      _pttRetries.remove(retryKey);
    }

    _activePtts.remove('$type:$id');
    notifyListeners();
  }

  void _onNewConsumer(Map<String, dynamic> msg) {
    media.handleNewConsumer(msg);
  }

  void _onConsumersClosed(Map<String, dynamic> msg) {
    final consumerIds = msg['consumerIds'] as List<dynamic>?;
    if (consumerIds != null && consumerIds.isNotEmpty) {
      // Close specific consumers (preferred — avoids killing newer consumers)
      media.handleConsumersClosedByIds(consumerIds.map((id) => id.toString()).toList());
    } else {
      // Fallback: close all from peer (legacy / WS disconnect cleanup)
      media.handleConsumersClosed(msg['peerId'].toString());
    }
  }

  void _onIncomingAudio(Map<String, dynamic> msg) {
    final fromId = msg['fromUserId'];
    final userId = fromId is int ? fromId : int.tryParse(fromId.toString());
    if (msg['talking'] == true) {
      // Suppress banner if user volume is 0
      if (userId != null && (_userVolumes[userId] ?? 1.0) <= 0) return;
      _incomingFrom = msg['fromDisplayName'] ?? 'User $userId';
      // Vibrate on incoming audio (skip in PiP to reduce overhead)
      if (!_inPipMode) platformVibrate();
      // Ensure audio context is active (critical for iOS/Safari on reused consumers)
      platformEnsureRemoteAudioPlaying();
    } else {
      _incomingFrom = null;
    }
    _notifyIfVisible();
  }

  void _onKicked(Map<String, dynamic> msg) {
    debugPrint('[Intercom] Kicked by admin: ${msg['reason']}');
    _error = msg['reason']?.toString() ?? 'Disconnected by admin';
    // Stop reconnecting completely
    _lastToken = null;
    ws.dispose(); // Kill WS and prevent auto-reconnect
    _connected = false;
    _mediaReady = false;
    _activePtts.clear();
    _incomingFrom = null;
    notifyListeners();
  }

  void _onTransportClosed(Map<String, dynamic> msg) async {
    final version = ++_initVersion;
    debugPrint('[Intercom] Transport closed (${msg['direction']}), re-initializing (initVersion=$version)...');
    _mediaReady = false;
    notifyListeners();
    try {
      await media.dispose();
      if (_initVersion != version) {
        debugPrint('[Intercom] transportClosed reinit superseded by newer init ($version vs $_initVersion)');
        return;
      }
      await media.init(inputDeviceId: _selectedInputId);
      if (_initVersion != version) {
        debugPrint('[Intercom] transportClosed reinit superseded after init ($version vs $_initVersion)');
        return;
      }
      _mediaReady = true;
      debugPrint('[Intercom] Media re-initialized after transport close (initVersion=$version)');
      // Re-apply output device
      if (_selectedOutputId != null) {
        media.setOutputDevice(_selectedOutputId!);
      }
    } catch (e) {
      if (_initVersion != version) return;
      _error = 'Error reinit media: $e';
      debugPrint('[Intercom] $_error');
    }
    notifyListeners();
  }

  // ======================== AUDIO DEVICES ========================

  Future<void> _loadAudioDevices() async {
    try {
      final devices = await media.getAudioDevices();
      _audioInputs = devices['inputs'] ?? [];
      _audioOutputs = devices['outputs'] ?? [];

      // Validate that the previously selected device still exists
      if (_selectedInputId != null &&
          !_audioInputs.any((d) => d['deviceId'] == _selectedInputId)) {
        debugPrint('[Intercom] Previously selected input device no longer available, resetting');
        _selectedInputId = null;
      }
      if (_selectedOutputId != null &&
          !_audioOutputs.any((d) => d['deviceId'] == _selectedOutputId)) {
        debugPrint('[Intercom] Previously selected output device no longer available, resetting');
        _selectedOutputId = null;
      }

      if (_selectedInputId == null && _audioInputs.isNotEmpty) {
        _selectedInputId = _audioInputs.first['deviceId'];
      }
      if (_selectedOutputId == null && _audioOutputs.isNotEmpty) {
        _selectedOutputId = _audioOutputs.first['deviceId'];
      }
      notifyListeners();
    } catch (e) {
      debugPrint('[Intercom] Error loading audio devices: $e');
    }
  }

  Future<void> switchInputDevice(String deviceId) async {
    _selectedInputId = deviceId;
    notifyListeners();
    try {
      await media.switchInputDevice(deviceId);
    } catch (e) {
      debugPrint('[Intercom] Error switching input: $e');
    }
  }

  void switchOutputDevice(String deviceId) {
    _selectedOutputId = deviceId;
    notifyListeners();
    media.setOutputDevice(deviceId);
  }

  // ======================== MUTE USER ========================

  double getUserVolume(int userId) => _userVolumes[userId] ?? 1.0;

  void setUserVolume(int userId, double volume) {
    _userVolumes[userId] = volume;
    media.setVolumeByPeerId(userId.toString(), volume);
    _saveVolumes();
    notifyListeners();
  }

  double getGroupVolume(int groupId) => _groupVolumes[groupId] ?? 1.0;

  void setGroupVolume(int groupId, double volume) {
    _groupVolumes[groupId] = volume;
    final group = _groupTargets.firstWhere(
      (g) => g['id'] == groupId,
      orElse: () => {},
    );
    final memberIds = (group['member_ids'] as List?)?.cast<int>() ?? [];
    for (final uid in memberIds) {
      media.setVolumeByPeerId(uid.toString(), volume);
    }
    _saveVolumes();
    notifyListeners();
  }

  /// Re-apply all saved volumes to the media service (after reconnect)
  void _reapplyVolumes() {
    for (final entry in _userVolumes.entries) {
      media.setVolumeByPeerId(entry.key.toString(), entry.value);
    }
    // Group volumes apply to individual members
    for (final entry in _groupVolumes.entries) {
      final group = _groupTargets.firstWhere(
        (g) => g['id'] == entry.key,
        orElse: () => {},
      );
      final memberIds = (group['member_ids'] as List?)?.cast<int>() ?? [];
      for (final uid in memberIds) {
        media.setVolumeByPeerId(uid.toString(), entry.value);
      }
    }
    debugPrint('[Intercom] Volumes re-applied: ${_userVolumes.length} users, ${_groupVolumes.length} groups');
  }

  /// Persist volumes to SharedPreferences
  Future<void> _saveVolumes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final uv = _userVolumes.map((k, v) => MapEntry(k.toString(), v));
      final gv = _groupVolumes.map((k, v) => MapEntry(k.toString(), v));
      await prefs.setString('intercom_user_volumes', jsonEncode(uv));
      await prefs.setString('intercom_group_volumes', jsonEncode(gv));
    } catch (_) {}
  }

  /// Load volumes from SharedPreferences
  Future<void> _loadSavedVolumes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final uvJson = prefs.getString('intercom_user_volumes');
      final gvJson = prefs.getString('intercom_group_volumes');
      if (uvJson != null) {
        final map = jsonDecode(uvJson) as Map<String, dynamic>;
        _userVolumes.addAll(map.map((k, v) => MapEntry(int.parse(k), (v as num).toDouble())));
      }
      if (gvJson != null) {
        final map = jsonDecode(gvJson) as Map<String, dynamic>;
        _groupVolumes.addAll(map.map((k, v) => MapEntry(int.parse(k), (v as num).toDouble())));
      }
      debugPrint('[Intercom] Loaded saved volumes: ${_userVolumes.length} users, ${_groupVolumes.length} groups');
    } catch (e) {
      debugPrint('[Intercom] Error loading saved volumes: $e');
    }
  }

  bool isUserMuted(int userId) => _mutedUserIds.contains(userId);

  void toggleMuteUser(int userId) {
    if (_mutedUserIds.contains(userId)) {
      _mutedUserIds.remove(userId);
      media.unmuteByPeerId(userId.toString());
      debugPrint('[Intercom] Unmuted user $userId');
    } else {
      _mutedUserIds.add(userId);
      media.muteByPeerId(userId.toString());
      debugPrint('[Intercom] Muted user $userId');
    }
    notifyListeners();
  }

  // ======================== RTT MEASUREMENT ========================

  void _startRttPolling() {
    _rttTimer?.cancel();
    _rttTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!_mediaReady || _disposed) return;
      try {
        final sw = Stopwatch()..start();
        await ws.request('ping');
        sw.stop();
        final rtt = sw.elapsedMilliseconds.toDouble();
        // Only update UI if rounded value changed (avoids unnecessary rebuilds)
        final oldRound = _rttMs?.round();
        final newRound = rtt.round();
        _rttMs = rtt;
        if (oldRound != newRound) {
          notifyListeners();
        }
      } catch (_) {}
    });
  }

  // ======================== RESUME ACTIVE PTTs ========================

  /// Re-send ptt_start for all active (latched) PTTs after reconnect.
  void _resumeActivePtts() {
    if (_activePtts.isEmpty || _micMuted) return;
    for (final key in _activePtts) {
      final parts = key.split(':');
      if (parts.length == 2) {
        final type = parts[0];
        final id = int.tryParse(parts[1]);
        if (id != null) {
          ws.send({'type': 'ptt_start', 'targetType': type, 'targetId': id});
          debugPrint('[Intercom] Resumed PTT: $key');
        }
      }
    }
  }

  // ======================== LATCH ========================

  bool isLatch(String targetType, int targetId) {
    return _latchModes['$targetType:$targetId'] ?? false;
  }

  void toggleLatch(String targetType, int targetId) {
    final key = '$targetType:$targetId';
    _latchModes[key] = !(_latchModes[key] ?? false);
    notifyListeners();
  }

  // ======================== PTT ========================

  void toggleMicMute() {
    _micMuted = !_micMuted;
    // If muting while talking, stop all active PTTs
    if (_micMuted && _activePtts.isNotEmpty) {
      for (final key in List.of(_activePtts)) {
        final parts = key.split(':');
        if (parts.length == 2) {
          ws.send({'type': 'ptt_stop', 'targetType': parts[0], 'targetId': int.tryParse(parts[1])});
        }
      }
      _activePtts.clear();
    }
    debugPrint('[Intercom] Mic ${_micMuted ? 'MUTED' : 'UNMUTED'}');
    notifyListeners();
  }

  /// Called on tap (latch mode) or press-down (momentary mode)
  void startTalking(String targetType, int targetId) {
    if (!_mediaReady || _micMuted) return;
    final key = '$targetType:$targetId';
    if (_activePtts.contains(key)) return; // Already talking to this target
    _activePtts.add(key);
    ws.send({'type': 'ptt_start', 'targetType': targetType, 'targetId': targetId});
    notifyListeners();
  }

  /// Called on release (momentary) or second tap (latch)
  void stopTalking(String targetType, int targetId) {
    final key = '$targetType:$targetId';
    if (!_activePtts.contains(key)) return;
    _activePtts.remove(key);
    ws.send({'type': 'ptt_stop', 'targetType': targetType, 'targetId': targetId});
    notifyListeners();
  }

  /// Unified handler for PTT tap: handles both latch and momentary
  void onPttTap(String targetType, int targetId) {
    if (isLatch(targetType, targetId)) {
      if (isTalkingTo(targetType, targetId)) {
        stopTalking(targetType, targetId);
      } else {
        startTalking(targetType, targetId);
      }
    }
  }

  // ======================== CLEANUP ========================

  Future<void> disconnect() async {
    _disposed = true;
    _lastToken = null;
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _rttTimer?.cancel();
    _rttTimer = null;
    _rttMs = null;
    await platformStopForegroundService();
    await media.disposeAll(); // Full cleanup including microphone
    ws.dispose();
    _connected = false;
    _mediaReady = false;
    _activePtts.clear();
    _incomingFrom = null;
    notifyListeners();
  }
}
