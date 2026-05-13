import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:vibration/vibration.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

const _audioChannel = MethodChannel('tv.huin.intercom/audio');

/// Cache of the last-seen native audio devices, keyed by the stringified
/// AudioDeviceInfo.id so we can resolve back to the integer when routing.
final Map<String, int> _nativeAudioDeviceIds = {};

/// Listeners invoked when the native side reports audio device hot-plug
/// events (Bluetooth connect/disconnect, USB headset, etc.).
final List<void Function()> _audioDevicesChangedListeners = [];
/// Listeners invoked when the OS takes audio focus away (GSM call,
/// WhatsApp, FaceTime…) or gives it back at the end of the call.
final List<void Function()> _audioFocusLostListeners = [];
final List<void Function()> _audioFocusGainedListeners = [];
bool _audioChannelHandlerInstalled = false;

void _ensureAudioChannelHandler() {
  if (_audioChannelHandlerInstalled) return;
  _audioChannelHandlerInstalled = true;
  _audioChannel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'devicesChanged':
        for (final cb
            in List<void Function()>.from(_audioDevicesChangedListeners)) {
          try { cb(); } catch (e) {
            debugPrint('[Platform] devicesChanged listener error: $e');
          }
        }
        break;
      case 'audioFocusLost':
        for (final cb
            in List<void Function()>.from(_audioFocusLostListeners)) {
          try { cb(); } catch (e) {
            debugPrint('[Platform] audioFocusLost listener error: $e');
          }
        }
        break;
      case 'audioFocusGained':
        for (final cb
            in List<void Function()>.from(_audioFocusGainedListeners)) {
          try { cb(); } catch (e) {
            debugPrint('[Platform] audioFocusGained listener error: $e');
          }
        }
        break;
    }
    return null;
  });
}

/// Arm (or disarm) the native audio-focus monitor so the app gets notified
/// when another process takes over the audio session (e.g. an incoming
/// WhatsApp call). Safe to call repeatedly.
void platformStartAudioFocusMonitor(bool enable) {
  _ensureAudioChannelHandler();
  _audioChannel
      .invokeMethod<bool>('requestAudioFocusMonitor', {'enable': enable})
      .catchError((e) {
    debugPrint('[Platform] requestAudioFocusMonitor error: $e');
    return false;
  });
}

void platformOnAudioFocusLost(void Function() listener) {
  _ensureAudioChannelHandler();
  _audioFocusLostListeners.add(listener);
}

void platformOnAudioFocusGained(void Function() listener) {
  _ensureAudioChannelHandler();
  _audioFocusGainedListeners.add(listener);
}

/// Native stub: the admin actions that open external URLs are gated behind
/// `if (isWeb)`, so this should never be hit on Android/iOS in practice.
void platformOpenUrl(String url) {
  debugPrint('[Platform] platformOpenUrl ignored on native: $url');
}

/// Register a callback fired when audio devices are added or removed.
/// Returns a disposer.
void Function() platformOnAudioDevicesChanged(void Function() listener) {
  _ensureAudioChannelHandler();
  _audioDevicesChangedListeners.add(listener);
  return () => _audioDevicesChangedListeners.remove(listener);
}

/// Ask the OS to (re)request BLUETOOTH_CONNECT if needed (no-op pre-API 31).
Future<bool> platformEnsureBluetoothPermission() async {
  try {
    final ok = await _audioChannel.invokeMethod<bool>('ensureBluetoothPermission');
    return ok ?? false;
  } catch (e) {
    debugPrint('[Platform] ensureBluetoothPermission error: $e');
    return false;
  }
}

/// Accept self-signed certificates (mkcert) on Android
class _IntercomHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
  }
}

void platformInit() {
  HttpOverrides.global = _IntercomHttpOverrides();
  debugPrint('[Platform] HttpOverrides set for self-signed certs');
}

void platformRequestWakeLock() {
  try {
    WakelockPlus.enable();
    debugPrint('[Platform] WakeLock enabled');
  } catch (e) {
    debugPrint('[Platform] WakeLock error: $e');
  }
}

void platformReleaseWakeLock() {
  try {
    WakelockPlus.disable();
  } catch (_) {}
}

void platformVibrate() async {
  try {
    final hasVibrator = await Vibration.hasVibrator() ?? false;
    if (hasVibrator) {
      Vibration.vibrate(pattern: [0, 200, 100, 200]);
    }
  } catch (_) {}
}

void platformEnsureRemoteAudioPlaying() {
  // No-op on Android: WebRTC audio plays natively without HTML element hacks
}

void platformSetStreamVolume(String streamId, double volume) {
  // TODO: Android volume control via native audio API
}

/// Sidetone: loopback the local microphone to the selected speaker at the
/// given level (0.0 … 1.0). Implemented on the native side so we can share
/// the audio hardware with the existing WebRTC capture without adding a
/// second getUserMedia() call. Until the native implementation lands this
/// is a best-effort call that only logs, so the slider in Settings persists
/// the value and it will take effect as soon as the platform code is
/// wired up.
void platformSetSidetoneLevel(double level) {
  _audioChannel.invokeMethod<bool>('setSidetoneLevel', {'level': level})
      .then((ok) => debugPrint('[Platform] setSidetoneLevel($level) -> $ok'))
      .catchError((e) {
        // No-op: older APKs / iOS builds won't have the handler yet.
        debugPrint('[Platform] setSidetoneLevel error (expected on older '
            'builds): $e');
      });
}

void platformSetAudioSinkId(String deviceId) {
  // Route both playback and capture to the selected communication device
  // (earpiece / speakerphone / wired / Bluetooth SCO / USB headset ...).
  // This is a fire-and-forget helper to match the web signature; failures
  // are logged in the native side.
  final nativeId = _nativeAudioDeviceIds[deviceId];
  if (nativeId == null) {
    debugPrint('[Platform] platformSetAudioSinkId: unknown deviceId=$deviceId');
    return;
  }
  _audioChannel.invokeMethod<bool>('setCommunicationDevice', {'deviceId': nativeId})
      .then((ok) => debugPrint('[Platform] setCommunicationDevice($nativeId) -> $ok'))
      .catchError((e) {
        debugPrint('[Platform] setCommunicationDevice error: $e');
      });
}

Future<Map<String, List<Map<String, String>>>> platformEnumerateAudioDevices() async {
  try {
    final raw = await _audioChannel.invokeMethod<List<dynamic>>('listCommunicationDevices');
    if (raw == null || raw.isEmpty) {
      return {'inputs': <Map<String, String>>[], 'outputs': <Map<String, String>>[]};
    }
    _nativeAudioDeviceIds.clear();
    final inputs = <Map<String, String>>[];
    final outputs = <Map<String, String>>[];
    for (final item in raw) {
      final m = Map<String, dynamic>.from(item as Map);
      final id = (m['deviceId'] as num).toInt();
      final label = m['label']?.toString() ?? 'Audio Device';
      final sid = id.toString();
      // Default to true for both when the native side hasn't tagged the
      // device — keeps backward compatibility with older APK/IPA payloads.
      final isInput = (m['isInput'] as bool?) ?? true;
      final isOutput = (m['isOutput'] as bool?) ?? true;
      _nativeAudioDeviceIds[sid] = id;
      final entry = <String, String>{'deviceId': sid, 'label': label};
      if (isInput) inputs.add(Map<String, String>.from(entry));
      if (isOutput) outputs.add(Map<String, String>.from(entry));
    }
    return {'inputs': inputs, 'outputs': outputs};
  } catch (e) {
    debugPrint('[Platform] listCommunicationDevices error: $e');
    return {'inputs': <Map<String, String>>[], 'outputs': <Map<String, String>>[]};
  }
}

/// Route mic capture to the given communication device. Mirrors
/// [platformSetAudioSinkId] because on Android routing is atomic.
void platformSetAudioSourceId(String deviceId) {
  platformSetAudioSinkId(deviceId);
}

/// Start playing a looping ringtone (used when an admin rings this user).
void platformPlayRingtone() {
  _audioChannel.invokeMethod<void>('playRingtone').catchError((e) {
    debugPrint('[Platform] playRingtone error: $e');
  });
}

/// Stop the ringtone started by [platformPlayRingtone].
void platformStopRingtone() {
  _audioChannel.invokeMethod<void>('stopRingtone').catchError((e) {
    debugPrint('[Platform] stopRingtone error: $e');
  });
}

bool get isWeb => false;

// Server URL stored in shared_preferences
String? _cachedBaseUrl;
String? _cachedWsUrl;

Future<void> setServerUrl(String url) async {
  // Normalize: remove trailing slash
  final normalized = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('server_url', normalized);
  _cachedBaseUrl = normalized;
  final uri = Uri.parse(normalized);
  final wsScheme = uri.scheme == 'https' ? 'wss' : 'ws';
  _cachedWsUrl = '$wsScheme://${uri.host}:${uri.port}/ws';
}

Future<String?> getSavedServerUrl() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString('server_url');
}

String getServerBaseUrl() {
  return _cachedBaseUrl ?? 'https://huin.tv:8443';
}

String getServerWsUrl() {
  return _cachedWsUrl ?? 'wss://huin.tv:8443/ws';
}

Future<void> initServerUrls() async {
  final saved = await getSavedServerUrl();
  if (saved != null) {
    await setServerUrl(saved);
  }
}

/// Start foreground service to keep app alive in background
Future<void> platformStartForegroundService() async {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'intercom_service',
      channelName: 'Intercom Service',
      channelDescription: 'Keeps the connection active',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: false,
      autoRunOnMyPackageReplaced: false,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
  await FlutterForegroundTask.startService(
    notificationTitle: 'Intercom active',
    notificationText: 'Connected and listening',
    callback: _foregroundTaskCallback,
  );
  debugPrint('[Platform] Foreground service started');
}

Future<void> platformStopForegroundService() async {
  await FlutterForegroundTask.stopService();
  debugPrint('[Platform] Foreground service stopped');
}

// Required callback - runs in main isolate with eventAction.nothing()
@pragma('vm:entry-point')
void _foregroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_IntercomTaskHandler());
}

class _IntercomTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  Future<void> onDestroy(DateTime timestamp, bool isAppTerminated) async {}
}

/// Save a text file to the device's Downloads folder.
/// Returns the full path on success, or null on failure.
Future<String?> platformSaveTextFile(String filename, String content) async {
  try {
    // Android: save to /sdcard/Download/ which is visible in the file manager
    final dir = Directory('/sdcard/Download');
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File('${dir.path}/$filename');
    await file.writeAsString(content);
    debugPrint('[Platform] File saved: ${file.path}');
    return file.path;
  } catch (e) {
    debugPrint('[Platform] platformSaveTextFile error: $e');
    return null;
  }
}

/// Read a text file from the device. Caller provides the path.
Future<String?> platformReadTextFile(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) return null;
    return await file.readAsString();
  } catch (e) {
    debugPrint('[Platform] platformReadTextFile error: $e');
    return null;
  }
}

/// Download/save a text file (legacy alias for web compatibility)
void platformDownloadFile(String filename, String content) {
  platformSaveTextFile(filename, content);
}

// ======================== Audio Focus ========================

/// Release exclusive audio focus (MODE_IN_COMMUNICATION → MODE_NORMAL)
/// so other VoIP apps (WhatsApp, etc.) can play audio.
/// The microphone stays open — only audio output exclusivity is released.
Future<void> platformReleaseAudioFocus() async {
  try {
    await _audioChannel.invokeMethod('releaseAudioFocus');
    debugPrint('[Platform] Audio focus released (MODE_NORMAL)');
  } catch (e) {
    debugPrint('[Platform] releaseAudioFocus error: $e');
  }
}

// ======================== Multi-channel / VOX stubs (web-only features) ========================
Future<int> platformInitMultiChannel(String inputDeviceId, String outputDeviceId, int numChannels) async => 0;
void platformDestroyMultiChannel() {}
bool platformRouteAudioStreamToChannel(String streamId, int channelIndex) => false;
void platformDisconnectOutputChannel(int channelIndex) {}
bool platformCreateVoxMonitor(String channelId, double thresholdDb,
    int holdMs, void Function() onStart, void Function() onStop) => false;
void platformDestroyVoxMonitor(String channelId) {}
double platformGetVoxLevel(String channelId) => 0;

/// Create WebSocket channel that accepts self-signed certificates
Future<WebSocketChannel> createWebSocketChannel(String url) async {
  final client = HttpClient()
    ..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
  final ws = await WebSocket.connect(url, customClient: client);
  return IOWebSocketChannel(ws);
}
