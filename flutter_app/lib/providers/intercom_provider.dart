import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
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
  // Set of user ids currently transmitting audio TO us. Multiple users can
  // talk at the same time (full duplex / group calls); the UI lights up
  // every matching button instead of only the most recent speaker. Each id
  // stays in the set for at least 3 s after the user stops talking so the
  // user has time to visually identify which key was active.
  final Set<int> _incomingFromUserIds = {};
  final Map<int, Timer> _incomingStickyTimers = {};
  static const _rxStickyDuration = Duration(seconds: 3);
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

  // Mic mute (toggles the local audio track only — PTT sessions survive so
  // unmuting resumes talking to whoever was latched/pressed before).
  bool _micMuted = false;

  // UI preferences persisted in SharedPreferences.
  int _gridColumns = 3;
  bool _hideOfflineUsers = false;
  double _sidetoneLevel = 0.0; // 0.0 = off, 1.0 = full local-mic loopback
  int _callDuckDb = -3; // How much to duck incoming intercom during a call

  // Call-interruption runtime state. `_callInterruption` flips to true as
  // soon as the OS takes audio focus away and back to false ~1 s after the
  // call has ended (small grace period so the audio focus bounces that some
  // ROMs do don't flap the mic open/close).
  bool _callInterruption = false;
  Timer? _callReacquireTimer;

  // Muted incoming users (local-only, not permanent)
  final Set<int> _mutedUserIds = {};

  // Per-user volume (0.0 to 1.0, default 1.0)
  final Map<int, double> _userVolumes = {};

  // Per-group volume (0.0 to 1.0, default 1.0)
  final Map<int, double> _groupVolumes = {};

  // Incoming ring (admin/superuser wants our attention)
  Map<String, dynamic>? _incomingRing;
  Timer? _ringAutoStopTimer;
  // Feedback on outgoing ring (admin shows a snackbar etc.)
  String? _ringFeedback;

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
    _loadSavedDevices();
    _loadSavedUiPrefs();
    // Subscribe to the native audio focus events so VoIP calls (WhatsApp,
    // FaceTime…) and GSM calls can steal the mic from us and we
    // automatically resume afterwards.
    platformOnAudioFocusLost(_onAudioFocusLost);
    platformOnAudioFocusGained(_onAudioFocusGained);
    // Refresh the device dropdown whenever the OS reports a hot-plug
    // (Bluetooth connect/disconnect, USB headset in/out, ...). Wrapped in
    // try/catch so a platform-side failure never aborts app launch.
    try {
      _audioDevicesListenerDisposer = platformOnAudioDevicesChanged(() {
        debugPrint('[Intercom] Audio devices changed — re-enumerating');
        if (_mediaReady) {
          _loadAudioDevices();
        }
      });
    } catch (e) {
      debugPrint('[Intercom] platformOnAudioDevicesChanged failed: $e');
    }
  }

  void Function()? _audioDevicesListenerDisposer;

  // Previous connectivity state. Starts "assumed online" so the very first
  // event we receive after subscribing (which echoes the current state) does
  // not trigger a spurious reconnect.
  bool _hadNetwork = true;

  void _startNetworkMonitor() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final hasNetwork = results.any((r) => r != ConnectivityResult.none);
      final cameBackOnline = hasNetwork && !_hadNetwork;
      _hadNetwork = hasNetwork;
      // Only force a reconnect on an actual offline → online transition. Doing
      // it on every onConnectivityChanged event causes a reconnect loop on
      // phones that emit multiple events for Wi-Fi validation, captive
      // portal checks, NCAPABILITY changes, etc.
      if (cameBackOnline && _lastToken != null && !_disposed) {
        debugPrint('[Intercom] Network just came back online — forcing reconnect');
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
  Set<int> get incomingFromUserIds => _incomingFromUserIds;
  Map<String, dynamic>? get incomingRing => _incomingRing;
  String? get ringFeedback => _ringFeedback;
  String? get error => _error;
  Set<int> get mutedUserIds => _mutedUserIds;
  List<Map<String, String>> get audioInputs => _audioInputs;
  List<Map<String, String>> get audioOutputs => _audioOutputs;
  String? get selectedInputId => _selectedInputId;
  String? get selectedOutputId => _selectedOutputId;
  bool get micMuted => _micMuted;
  bool get inPipMode => _inPipMode;
  double? get rttMs => _rttMs;
  int get gridColumns => _gridColumns;
  bool get hideOfflineUsers => _hideOfflineUsers;
  double get sidetoneLevel => _sidetoneLevel;
  int get callDuckDb => _callDuckDb;
  bool get callInterruption => _callInterruption;

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
    ws.onMessage('incoming_ring', _onIncomingRing);
    ws.onMessage('ring_ack', _onRingAck);
    ws.onMessage('ring_denied', _onRingDenied);

    // Connect WebSocket
    ws.connect(token);

    // Load targets
    await _loadTargets();
  }

  /// Reload the user / group target lists from the server without dropping
  /// the active WS or media session. Called from the AppBar refresh button
  /// so an admin who just created a new user can see them appear without
  /// having to log out and back in.
  ///
  /// Returns the number of (users, groups) loaded so the caller can show a
  /// quick SnackBar with the result. On failure the previous lists remain
  /// in place and the exception is rethrown.
  Future<({int users, int groups})> refreshTargets() async {
    final n = await _loadTargets();
    return n;
  }

  Future<({int users, int groups})> _loadTargets() async {
    try {
      final targets = await api.getMyTargets();
      _userTargets = List<Map<String, dynamic>>.from(targets['users'] ?? []);
      // Sort: regular users first, bridge users last (same rule as on first
      // load) so the visual order does not jump around when the operator
      // refreshes mid-session.
      _userTargets.sort((a, b) {
        final aIsBridge = a['role'] == 'bridge' ? 1 : 0;
        final bIsBridge = b['role'] == 'bridge' ? 1 : 0;
        return aIsBridge - bIsBridge;
      });
      _groupTargets = List<Map<String, dynamic>>.from(targets['groups'] ?? []);
      notifyListeners();
      return (users: _userTargets.length, groups: _groupTargets.length);
    } catch (e) {
      debugPrint('[Intercom] Error loading targets: $e');
      rethrow;
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
        // Ensure saved device preferences are loaded before the first init.
        await _loadSavedDevices();
        if (_initVersion != version) return;
        // Enumerate first so we can reconcile the saved/selected IDs with what's
        // actually available. This keeps the dropdown in sync with the device
        // that getUserMedia will capture. On first launch (pre-permission) this
        // may return an empty list — we handle that with a second pass below.
        await _loadAudioDevices();
        if (_initVersion != version) return;
        final initInputId = _selectedInputId;
        await media.init(inputDeviceId: initInputId);
        if (_initVersion != version) return;
        _mediaReady = true;
        _error = null;
        notifyListeners();
        debugPrint('[Intercom] Media ready (initVersion=$version, attempt=$attempt)');
        // Re-enumerate now that mic permission has been granted (labels are
        // populated and some platforms only expose devices post-permission).
        await _loadAudioDevices();
        // If the first pass couldn't pick a concrete device (empty list before
        // permission) but we have one now, migrate the mic to match the UI.
        if (_selectedInputId != null && _selectedInputId != initInputId) {
          debugPrint('[Intercom] Migrating mic to selected device $_selectedInputId');
          try {
            await media.switchInputDevice(_selectedInputId!);
          } catch (e) {
            debugPrint('[Intercom] Error migrating mic: $e');
          }
        }
        if (_selectedOutputId != null) {
          media.setOutputDevice(_selectedOutputId!);
        }
        // Persist the (possibly newly-resolved) selection so subsequent launches
        // start already aligned.
        unawaited(_saveSelectedDevices());
        _reapplyVolumes();
        _startRttPolling();
        // Release exclusive audio focus so WhatsApp/other VoIP apps can play
        await platformReleaseAudioFocus();
        // Re-establish active latched PTTs that were lost during reconnect
        _resumeActivePtts();
        platformStartForegroundService();
        // Arm the native audio-focus monitor so VoIP/GSM calls pre-empt us.
        platformStartAudioFocusMonitor(true);
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
    // Bridge peers never light up the green RX strip — they constantly emit
    // audio (matrix/tieline tones) so flagging them as active would keep
    // their key lit up forever.
    if (userId != null && _isBridgeUser(userId)) return;
    if (msg['talking'] == true) {
      // Suppress incoming indication if user volume is 0
      if (userId != null && (_userVolumes[userId] ?? 1.0) <= 0) return;
      _incomingFrom = msg['fromDisplayName'] ?? 'User $userId';
      if (userId != null) {
        // Cancel any pending "unstick" timer so the green stays solid while
        // the user keeps talking.
        _incomingStickyTimers.remove(userId)?.cancel();
        _incomingFromUserIds.add(userId);
      }
      // Vibrate on incoming audio (skip in PiP to reduce overhead)
      if (!_inPipMode) platformVibrate();
      // Ensure audio context is active (critical for iOS/Safari on reused consumers)
      platformEnsureRemoteAudioPlaying();
    } else {
      if (userId != null && _incomingFromUserIds.contains(userId)) {
        // Hold the green for _rxStickyDuration so the user has time to spot
        // the key visually before it fades. A new talking=true cancels this.
        _incomingStickyTimers.remove(userId)?.cancel();
        _incomingStickyTimers[userId] = Timer(_rxStickyDuration, () {
          _incomingStickyTimers.remove(userId);
          _incomingFromUserIds.remove(userId);
          if (_incomingFromUserIds.isEmpty) _incomingFrom = null;
          _notifyIfVisible();
        });
      }
    }
    _notifyIfVisible();
  }

  // ======================== RING ========================

  /// Admin/superuser rings a user to get their attention. Only online users
  /// are accepted by the server; the UI should already filter offline ones.
  void ringUser(int targetUserId, {String? reason}) {
    ws.send({
      'type': 'ring_user',
      'targetUserId': targetUserId,
      if (reason != null) 'reason': reason,
    });
  }

  void _onIncomingRing(Map<String, dynamic> msg) {
    _incomingRing = {
      'fromUserId': msg['fromUserId'],
      'fromDisplayName': msg['fromDisplayName']?.toString() ?? 'Admin',
      'reason': msg['reason']?.toString(),
      'at': DateTime.now().millisecondsSinceEpoch,
    };
    platformPlayRingtone();
    platformVibrate();
    // Auto-stop after 30 s so we don't hang forever if the user leaves the device.
    _ringAutoStopTimer?.cancel();
    _ringAutoStopTimer = Timer(const Duration(seconds: 30), () {
      dismissIncomingRing(silent: true);
    });
    notifyListeners();
  }

  /// Dismiss the incoming ring modal and stop the ringtone.
  /// When [silent] is false, also notify the admin that the ring was seen.
  void dismissIncomingRing({bool silent = false}) {
    if (_incomingRing == null) return;
    final fromId = _incomingRing!['fromUserId'];
    _incomingRing = null;
    _ringAutoStopTimer?.cancel();
    _ringAutoStopTimer = null;
    platformStopRingtone();
    if (!silent && fromId is int) {
      ws.send({'type': 'ring_dismiss', 'fromUserId': fromId});
    }
    notifyListeners();
  }

  void _onRingAck(Map<String, dynamic> msg) {
    _ringFeedback = 'Ring delivered';
    notifyListeners();
    Future.delayed(const Duration(seconds: 2), () {
      if (_ringFeedback == 'Ring delivered') {
        _ringFeedback = null;
        notifyListeners();
      }
    });
  }

  void _onRingDenied(Map<String, dynamic> msg) {
    final reason = msg['reason']?.toString() ?? 'unknown';
    switch (reason) {
      case 'offline':
        _ringFeedback = 'User is offline';
        break;
      case 'cooldown':
        final ms = (msg['remainMs'] as num?)?.toInt() ?? 0;
        _ringFeedback = 'Wait ${(ms / 1000).ceil()}s to ring again';
        break;
      case 'forbidden':
        _ringFeedback = 'Only admins can ring';
        break;
      default:
        _ringFeedback = 'Ring failed: $reason';
    }
    notifyListeners();
    Future.delayed(const Duration(seconds: 3), () {
      _ringFeedback = null;
      notifyListeners();
    });
  }

  void clearRingFeedback() {
    _ringFeedback = null;
    notifyListeners();
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
    _incomingFromUserIds.clear();
    for (final t in _incomingStickyTimers.values) {
      t.cancel();
    }
    _incomingStickyTimers.clear();
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
    // On native platforms routing is atomic (Android setCommunicationDevice /
    // iOS setPreferredInput route both mic and speaker to the same device),
    // so mirror the selection on the other dropdown whenever the device also
    // supports that side — otherwise the UI shows an inconsistent state.
    if (!isWeb && _audioOutputs.any((d) => d['deviceId'] == deviceId)) {
      _selectedOutputId = deviceId;
    }
    unawaited(_saveSelectedDevices());
    notifyListeners();
    try {
      await media.switchInputDevice(deviceId);
    } catch (e) {
      debugPrint('[Intercom] Error switching input: $e');
    }
  }

  void switchOutputDevice(String deviceId) {
    _selectedOutputId = deviceId;
    if (!isWeb && _audioInputs.any((d) => d['deviceId'] == deviceId)) {
      _selectedInputId = deviceId;
    }
    unawaited(_saveSelectedDevices());
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

  /// True if [userId] is a bridge user. Bridge users keep an independent
  /// volume slider so the group fader never drags the matrix audio along
  /// with the human members — even if an admin accidentally adds them as
  /// group members.
  bool _isBridgeUser(int userId) {
    final u = _userTargets.firstWhere(
      (e) => e['id'] == userId,
      orElse: () => const {},
    );
    return u['role'] == 'bridge';
  }

  void setGroupVolume(int groupId, double volume) {
    _groupVolumes[groupId] = volume;
    final group = _groupTargets.firstWhere(
      (g) => g['id'] == groupId,
      orElse: () => {},
    );
    final memberIds = (group['member_ids'] as List?)?.cast<int>() ?? [];
    for (final uid in memberIds) {
      // Skip bridges: their per-user fader stays independent.
      if (_isBridgeUser(uid)) continue;
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
    // Group volumes apply to individual members — bridges excluded so the
    // matrix audio keeps its independent fader on reconnect.
    for (final entry in _groupVolumes.entries) {
      final group = _groupTargets.firstWhere(
        (g) => g['id'] == entry.key,
        orElse: () => {},
      );
      final memberIds = (group['member_ids'] as List?)?.cast<int>() ?? [];
      for (final uid in memberIds) {
        if (_isBridgeUser(uid)) continue;
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

  // ======================== UI PREFERENCES ========================

  Future<void> _loadSavedUiPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cols = prefs.getInt('intercom_grid_columns');
      final hide = prefs.getBool('intercom_hide_offline');
      final side = prefs.getDouble('intercom_sidetone');
      final duck = prefs.getInt('intercom_call_duck_db');
      if (cols != null && cols >= 2 && cols <= 4) _gridColumns = cols;
      if (hide != null) _hideOfflineUsers = hide;
      if (side != null && side >= 0 && side <= 1) _sidetoneLevel = side;
      if (duck != null && duck >= -60 && duck <= 0) _callDuckDb = duck;
      // Apply the restored sidetone level on the platform side so the user
      // doesn't have to open the Settings sheet to "re-arm" it.
      platformSetSidetoneLevel(_sidetoneLevel);
      notifyListeners();
    } catch (e) {
      debugPrint('[Intercom] Error loading UI prefs: $e');
    }
  }

  Future<void> setSidetoneLevel(double level) async {
    if (level < 0) level = 0;
    if (level > 1) level = 1;
    if ((level - _sidetoneLevel).abs() < 0.001) return;
    _sidetoneLevel = level;
    platformSetSidetoneLevel(level);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('intercom_sidetone', level);
    } catch (_) {}
  }

  Future<void> setCallDuckDb(int db) async {
    if (db > 0) db = 0;
    if (db < -60) db = -60; // Treat -60 dB as "mute".
    if (db == _callDuckDb) return;
    _callDuckDb = db;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('intercom_call_duck_db', db);
    } catch (_) {}
  }

  /// Linear attenuation factor corresponding to the user-selected dB value.
  double get _callDuckFactor {
    if (_callDuckDb <= -60) return 0.0; // mute
    return math.pow(10, _callDuckDb / 20).toDouble();
  }

  // ======================== CALL INTERRUPTION ========================

  /// Called when the OS hands audio focus over to another app (incoming
  /// call, WhatsApp, FaceTime…). We release the mic so the other app can
  /// capture it and duck the incoming intercom consumers according to the
  /// user-configured level.
  void _onAudioFocusLost() {
    debugPrint('[Intercom] Audio focus lost — pausing mic, ducking intercom');
    _callReacquireTimer?.cancel();
    _callReacquireTimer = null;
    _callInterruption = true;
    media.setDuckActive(true, factor: _callDuckFactor);
    media.releaseLocalStream();
    notifyListeners();
  }

  /// Called when the OS returns audio focus. We wait ~1 s before grabbing
  /// the mic again — some ROMs emit spurious focus-gain events right before
  /// the next focus-loss (notification tones, etc.), so this small grace
  /// period avoids thrashing the audio path.
  void _onAudioFocusGained() {
    debugPrint('[Intercom] Audio focus gained — scheduling recovery in 1 s');
    _callReacquireTimer?.cancel();
    _callReacquireTimer = Timer(const Duration(seconds: 1), () async {
      _callReacquireTimer = null;
      try {
        await media.reacquireLocalStream(deviceId: _selectedInputId);
      } catch (e) {
        debugPrint('[Intercom] reacquireLocalStream error: $e');
      }
      media.setDuckActive(false);
      _callInterruption = false;
      notifyListeners();
      debugPrint('[Intercom] Intercom audio path restored');
    });
  }

  Future<void> setGridColumns(int columns) async {
    if (columns < 2) columns = 2;
    if (columns > 4) columns = 4;
    if (columns == _gridColumns) return;
    _gridColumns = columns;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('intercom_grid_columns', columns);
    } catch (_) {}
  }

  Future<void> setHideOfflineUsers(bool hide) async {
    if (hide == _hideOfflineUsers) return;
    _hideOfflineUsers = hide;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('intercom_hide_offline', hide);
    } catch (_) {}
  }

  /// True if at least one member of [groupId] is currently online. Used by
  /// the "hide offline" filter so groups with no connected members disappear
  /// until someone shows up.
  bool groupHasOnlineMember(int groupId) {
    final group = _groupTargets.firstWhere(
      (g) => g['id'] == groupId,
      orElse: () => const {},
    );
    final memberIds = (group['member_ids'] as List?)?.cast<int>() ?? const <int>[];
    if (memberIds.isEmpty) return true; // Fail open — show the group anyway.
    for (final uid in memberIds) {
      if (_onlineUserIds.contains(uid)) return true;
    }
    return false;
  }

  /// Persist the currently selected input/output audio device IDs
  Future<void> _saveSelectedDevices() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_selectedInputId != null) {
        await prefs.setString('intercom_input_device', _selectedInputId!);
      } else {
        await prefs.remove('intercom_input_device');
      }
      if (_selectedOutputId != null) {
        await prefs.setString('intercom_output_device', _selectedOutputId!);
      } else {
        await prefs.remove('intercom_output_device');
      }
    } catch (_) {}
  }

  /// Load previously persisted audio device IDs
  Future<void> _loadSavedDevices() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedIn = prefs.getString('intercom_input_device');
      final savedOut = prefs.getString('intercom_output_device');
      // Only overwrite if we don't already have a selection from this session
      _selectedInputId ??= savedIn;
      _selectedOutputId ??= savedOut;
      debugPrint('[Intercom] Loaded saved devices: input=$_selectedInputId, output=$_selectedOutputId');
    } catch (e) {
      debugPrint('[Intercom] Error loading saved devices: $e');
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
    if (_activePtts.isEmpty) return;
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
    // Toggle the local mic track. The server keeps routing audio to each
    // active PTT target — with the track disabled nothing flows, and when
    // the user unmutes, audio resumes toward the same latched targets.
    // Therefore _activePtts is NOT cleared here.
    media.setMicEnabled(!_micMuted);
    debugPrint('[Intercom] Mic ${_micMuted ? 'MUTED' : 'UNMUTED'} '
        '(active PTTs: ${_activePtts.length})');
    notifyListeners();
  }

  /// Called on tap (latch mode) or press-down (momentary mode)
  void startTalking(String targetType, int targetId) {
    // Mic mute no longer blocks new PTTs — we let the user press buttons
    // while muted and the audio will start flowing as soon as they unmute.
    if (!_mediaReady) return;
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

  /// Called by ChangeNotifierProvider when the provider is disposed (e.g.
  /// when the widget key changes after a server switch). Releases all
  /// resources synchronously; async parts (media, foreground service) are
  /// fire-and-forget since the provider is being thrown away.
  @override
  void dispose() {
    _disposed = true;
    _lastToken = null;
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _rttTimer?.cancel();
    _rttTimer = null;
    _audioDevicesListenerDisposer?.call();
    _audioDevicesListenerDisposer = null;
    _callReacquireTimer?.cancel();
    _callReacquireTimer = null;
    _ringAutoStopTimer?.cancel();
    _ringAutoStopTimer = null;
    for (final t in _incomingStickyTimers.values) {
      t.cancel();
    }
    _incomingStickyTimers.clear();
    platformStartAudioFocusMonitor(false);
    platformStopRingtone();
    // Fire-and-forget async cleanup — provider is being discarded.
    platformStopForegroundService();
    media.disposeAll();
    ws.dispose();
    super.dispose();
  }

  /// Explicit disconnect (logout, kicked). Unlike dispose(), this awaits
  /// async cleanup and notifies listeners so the UI can react.
  Future<void> disconnect() async {
    _disposed = true;
    _lastToken = null;
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _rttTimer?.cancel();
    _rttTimer = null;
    _rttMs = null;
    _audioDevicesListenerDisposer?.call();
    _audioDevicesListenerDisposer = null;
    _callReacquireTimer?.cancel();
    _callReacquireTimer = null;
    _ringAutoStopTimer?.cancel();
    _ringAutoStopTimer = null;
    platformStartAudioFocusMonitor(false);
    platformStopRingtone();
    await platformStopForegroundService();
    await media.disposeAll(); // Full cleanup including microphone
    ws.dispose();
    _connected = false;
    _mediaReady = false;
    _activePtts.clear();
    _incomingFrom = null;
    _incomingFromUserIds.clear();
    for (final t in _incomingStickyTimers.values) {
      t.cancel();
    }
    _incomingStickyTimers.clear();
    notifyListeners();
  }
}
