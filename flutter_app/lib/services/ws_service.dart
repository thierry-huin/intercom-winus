import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../platform/platform_utils.dart';

typedef WsMessageHandler = void Function(Map<String, dynamic> msg);

class WsService {
  final String wsUrl;
  WebSocketChannel? _channel;
  int _requestId = 0;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _handlers = <String, WsMessageHandler>{};
  bool _disposed = false;
  bool _connecting = false; // Guard against concurrent connect attempts
  Timer? _retryTimer; // Cancellable retry timer
  int _connectEpoch = 0; // Monotonic counter to invalidate stale retries

  WsService({required this.wsUrl});

  bool get connected => _channel != null;

  void onMessage(String type, WsMessageHandler handler) {
    _handlers[type] = handler;
  }

  void connect(String token) async {
    // Prevent concurrent connection attempts
    if (_connecting || _disposed) return;
    _connecting = true;
    _retryTimer?.cancel();
    final epoch = ++_connectEpoch;

    try {
      debugPrint('[WS] Connecting (epoch=$epoch)...');
      final channel = await createWebSocketChannel(wsUrl)
          .timeout(const Duration(seconds: 20), onTimeout: () {
        throw TimeoutException('WS connect timeout');
      });

      // Check if this connect attempt is still current (not superseded by forceReconnect)
      if (epoch != _connectEpoch) {
        debugPrint('[WS] Connect epoch=$epoch superseded, closing stale channel');
        _connecting = false;
        try { channel.sink.close(); } catch (_) {}
        return;
      }

      _channel = channel;
      _connecting = false;

      _channel!.stream.listen(
        (data) => _onData(data),
        onDone: () {
          debugPrint('[WS] Connection closed (epoch=$epoch)');
          if (_channel == channel) _channel = null; // Only clear if still ours
          if (!_disposed && epoch == _connectEpoch) _scheduleRetry(token, epoch);
        },
        onError: (e) {
          debugPrint('[WS] Stream error: $e');
          if (_channel == channel) _channel = null;
          if (!_disposed && epoch == _connectEpoch) _scheduleRetry(token, epoch);
        },
      );
      // Authenticate
      send({'type': 'auth', 'token': token});
      debugPrint('[WS] Connected and authenticated (epoch=$epoch)');
    } catch (e) {
      debugPrint('[WS] Connection failed (epoch=$epoch): $e');
      _connecting = false;
      if (epoch == _connectEpoch) _channel = null;
      if (!_disposed && epoch == _connectEpoch) _scheduleRetry(token, epoch);
    }
  }

  void _scheduleRetry(String token, int epoch) {
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 3), () {
      // Only retry if this is still the latest connect attempt
      if (!_disposed && epoch == _connectEpoch) {
        connect(token);
      }
    });
  }

  void send(Map<String, dynamic> data) {
    _channel?.sink.add(jsonEncode(data));
  }

  Future<Map<String, dynamic>> request(String type, [Map<String, dynamic>? data]) {
    final id = ++_requestId;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;

    send({
      'type': type,
      'requestId': id,
      ...?data,
    });

    // Timeout
    Future.delayed(const Duration(seconds: 10), () {
      if (_pending.containsKey(id)) {
        _pending.remove(id);
        completer.completeError(TimeoutException('WS request $type timeout'));
      }
    });

    return completer.future;
  }

  void _onData(dynamic raw) {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;

    // Request/response matching
    final reqId = msg['requestId'];
    if (reqId != null && _pending.containsKey(reqId)) {
      _pending.remove(reqId)!.complete(msg);
      return;
    }

    // Dispatch to handler
    final type = msg['type'] as String?;
    if (type != null && _handlers.containsKey(type)) {
      _handlers[type]!(msg);
    }
  }

  /// Force close and immediately reconnect (e.g. on network change)
  void forceReconnect(String token) {
    debugPrint('[WS] Force reconnect triggered');
    _retryTimer?.cancel();
    _connecting = false; // Reset guard so connect() can proceed
    ++_connectEpoch; // Invalidate any pending retries
    try { _channel?.sink.close(); } catch (_) {}
    _channel = null;
    if (!_disposed) connect(token);
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _connecting = false;
    try { _channel?.sink.close(); } catch (_) {}
    _channel = null;
    for (final c in _pending.values) {
      c.completeError(Exception('WS disposed'));
    }
    _pending.clear();
  }
}
