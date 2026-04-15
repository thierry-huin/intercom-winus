import 'dart:convert';
import 'dart:js_interop';
import 'package:web_socket_channel/web_socket_channel.dart';

@JS('requestWakeLock')
external void _jsRequestWakeLock();

@JS('releaseWakeLock')
external void _jsReleaseWakeLock();

@JS('vibrateIncoming')
external void _jsVibrateIncoming();

@JS('ensureRemoteAudioPlaying')
external void _jsEnsureRemoteAudioPlaying();

@JS('setStreamVolume')
external JSNumber _jsSetStreamVolume(JSString streamId, JSNumber volume);

@JS('setAudioSinkId')
external void _jsSetAudioSinkId(JSString deviceId);

@JS('enumerateAudioDevices')
external JSPromise<JSString> _jsEnumerateAudioDevices();

void platformRequestWakeLock() {
  try { _jsRequestWakeLock(); } catch (_) {}
}

void platformReleaseWakeLock() {
  try { _jsReleaseWakeLock(); } catch (_) {}
}

void platformVibrate() {
  try { _jsVibrateIncoming(); } catch (_) {}
}

void platformEnsureRemoteAudioPlaying() {
  try { _jsEnsureRemoteAudioPlaying(); } catch (_) {}
}

void platformSetStreamVolume(String streamId, double volume) {
  try { _jsSetStreamVolume(streamId.toJS, volume.toJS); } catch (_) {}
}

void platformSetAudioSinkId(String deviceId) {
  try { _jsSetAudioSinkId(deviceId.toJS); } catch (_) {}
}

Future<Map<String, List<Map<String, String>>>> platformEnumerateAudioDevices() async {
  try {
    final jsResult = await _jsEnumerateAudioDevices().toDart;
    final map = jsonDecode(jsResult.toDart) as Map<String, dynamic>;
    final inputs = (map['inputs'] as List)
        .map((d) => Map<String, String>.from(d as Map))
        .toList();
    final outputs = (map['outputs'] as List)
        .map((d) => Map<String, String>.from(d as Map))
        .toList();
    return {'inputs': inputs, 'outputs': outputs};
  } catch (_) {
    return {'inputs': <Map<String, String>>[], 'outputs': <Map<String, String>>[]};
  }
}

// ======================== Multi-channel I/O (Tie Lines) ========================

@JS('initMultiChannel')
external JSPromise<JSNumber> _jsInitMultiChannel(
    JSString inputDeviceId, JSString outputDeviceId, JSNumber numChannels);

@JS('destroyMultiChannel')
external void _jsDestroyMultiChannel();

@JS('routeAudioStreamToChannel')
external JSBoolean _jsRouteAudioStreamToChannel(JSString streamId, JSNumber channelIndex);

@JS('disconnectOutputChannel')
external void _jsDisconnectOutputChannel(JSNumber channelIndex);

Future<int> platformInitMultiChannel(String inputDeviceId, String outputDeviceId, int numChannels) async {
  try {
    final result = await _jsInitMultiChannel(
        inputDeviceId.toJS, outputDeviceId.toJS, numChannels.toJS).toDart;
    final channels = result.toDartInt;
    if (channels > 0) {
      print('[MC] Multi-channel initialized: $channels channels');
    }
    return channels;
  } catch (e) {
    print('[MC] initMultiChannel error: $e');
    return 0;
  }
}

void platformDestroyMultiChannel() {
  try { _jsDestroyMultiChannel(); } catch (_) {}
}

bool platformRouteAudioStreamToChannel(String streamId, int channelIndex) {
  try {
    return _jsRouteAudioStreamToChannel(streamId.toJS, channelIndex.toJS).toDart;
  } catch (_) { return false; }
}

void platformDisconnectOutputChannel(int channelIndex) {
  try { _jsDisconnectOutputChannel(channelIndex.toJS); } catch (_) {}
}

// ======================== VOX Monitor ========================

@JS('createVoxMonitor')
external JSBoolean _jsCreateVoxMonitor(
    JSString channelId, JSNumber thresholdDb,
    JSNumber holdMs, JSFunction onStart, JSFunction onStop);

@JS('destroyVoxMonitor')
external void _jsDestroyVoxMonitor(JSString channelId);

@JS('getVoxLevel')
external JSNumber _jsGetVoxLevel(JSString channelId);

bool platformCreateVoxMonitor(String channelId, double thresholdDb,
    int holdMs, void Function() onStart, void Function() onStop) {
  try {
    return _jsCreateVoxMonitor(
      channelId.toJS, thresholdDb.toJS, holdMs.toJS,
      onStart.toJS, onStop.toJS,
    ).toDart;
  } catch (e) {
    return false;
  }
}

void platformDestroyVoxMonitor(String channelId) {
  try { _jsDestroyVoxMonitor(channelId.toJS); } catch (_) {}
}

double platformGetVoxLevel(String channelId) {
  try { return _jsGetVoxLevel(channelId.toJS).toDartDouble; } catch (_) { return 0; }
}

bool get isWeb => true;

String getServerBaseUrl() {
  final base = Uri.base;
  return '${base.scheme}://${base.host}:${base.port}';
}

String getServerWsUrl() {
  final base = Uri.base;
  final wsScheme = base.scheme == 'https' ? 'wss' : 'ws';
  return '$wsScheme://${base.host}:${base.port}/ws';
}

/// Download a text file (web: triggers browser download)
void platformDownloadFile(String filename, String content) {
  try {
    // Use JS to create a download link
    _jsDownloadFile(filename.toJS, content.toJS);
  } catch (_) {}
}

@JS('_downloadTextFile')
external void _jsDownloadFile(JSString filename, JSString content);

// Stubs (only used on Android)
Future<void> platformReleaseAudioFocus() async {}
void platformInit() {}
Future<void> platformStartForegroundService() async {}
Future<void> platformStopForegroundService() async {}
Future<void> setServerUrl(String url) async {}
Future<String?> getSavedServerUrl() async => null;
Future<void> initServerUrls() async {}

/// Create WebSocket channel (standard, no SSL override needed on web)
Future<WebSocketChannel> createWebSocketChannel(String url) async {
  return WebSocketChannel.connect(Uri.parse(url));
}
