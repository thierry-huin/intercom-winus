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

void platformSetAudioSinkId(String deviceId) {
  // No-op on Android: output device selection not available via web API
}

Future<Map<String, List<Map<String, String>>>> platformEnumerateAudioDevices() async {
  // On Android, audio devices are handled natively by flutter_webrtc
  // Return empty - the media_service fallback using navigator.mediaDevices will handle it
  return {'inputs': <Map<String, String>>[], 'outputs': <Map<String, String>>[]};
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
  Future<void> onDestroy(DateTime timestamp) async {}
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
