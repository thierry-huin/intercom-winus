import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:mediasfu_mediasoup_client/mediasfu_mediasoup_client.dart';
import 'package:mediasfu_mediasoup_client/src/handlers/handler_interface.dart'
    show RTCIceServer, RTCIceCredentialType;
import 'package:flutter_webrtc/flutter_webrtc.dart' show Helper;
import 'ws_service.dart';
import '../platform/platform_utils.dart';

class MediaService {
  final WsService ws;

  Device? _device;
  Transport? _sendTransport;
  Transport? _recvTransport;
  Producer? _producer;
  final _consumers = <String, Consumer>{};
  final _renderers = <String, RTCVideoRenderer>{};
  MediaStream? _localStream;
  String? _selectedOutputDeviceId;

  bool get deviceLoaded => _device?.loaded == true;
  String? get localStreamId => _localStream?.id;


  /// Per-peer volume levels (peerId -> 0.0 to 1.0)
  final _peerVolumes = <String, double>{};

  /// Callback fired when a consumer stream is created (consumerId, streamId)
  void Function(String consumerId, String streamId)? onConsumerCreated;

  MediaService({required this.ws});

  Future<void> init({String? inputDeviceId, int tieLineChannel = -1}) async {
    // 1. Get router RTP capabilities
    final resp = await ws.request('getRouterRtpCapabilities');
    final rtpCaps = RtpCapabilities.fromMap(resp['rtpCapabilities']);

    // 2. Create and load Device
    _device = Device();
    await _device!.load(routerRtpCapabilities: rtpCaps);
    debugPrint('[Media] Device loaded, canProduce audio: ${_device!.canProduce(RTCRtpMediaType.RTCRtpMediaTypeAudio)}');

    // 3. Send our RTP capabilities to server
    await ws.request('setRtpCapabilities', {
      'rtpCapabilities': _device!.rtpCapabilities.toMap(),
    });

    // 4. Create send transport
    await _createSendTransport();

    // 5. Create recv transport
    await _createRecvTransport();

    // 6. Produce audio
    await _produceAudio(deviceId: inputDeviceId, tieLineChannel: tieLineChannel);
  }

  // ======================== ICE SERVERS ========================

  List<RTCIceServer> _parseIceServers(List<dynamic>? servers) {
    if (servers == null || servers.isEmpty) return [];
    return servers.map((s) {
      final urls = s['urls'];
      return RTCIceServer(
        urls: urls is List ? List<String>.from(urls) : [urls.toString()],
        username: s['username']?.toString() ?? '',
        credential: s['credential']?.toString(),
        credentialType: RTCIceCredentialType.password,
      );
    }).toList();
  }

  // ======================== SEND TRANSPORT ========================

  Future<void> _createSendTransport() async {
    final data = await ws.request('createWebRtcTransport', {'direction': 'send'});
    final iceServers = _parseIceServers(data['iceServers'] as List<dynamic>?);
    debugPrint('[Media] Send transport iceServers: ${iceServers.length}');

    _sendTransport = _device!.createSendTransport(
      id: data['id'],
      iceParameters: IceParameters.fromMap(data['iceParameters']),
      iceCandidates: List<IceCandidate>.from(
        (data['iceCandidates'] as List).map((c) => IceCandidate.fromMap(c)),
      ),
      dtlsParameters: DtlsParameters.fromMap(data['dtlsParameters']),
      iceServers: iceServers,
      additionalSettings: {'encodedInsertableStreams': false},
      proprietaryConstraints: {'optional': [{'googDscp': true}]},
      producerCallback: (Producer producer) {
        debugPrint('[Media] Producer created: ${producer.id}');
        _producer = producer;
      },
    );

    _sendTransport!.on('connect', (Map data) async {
      try {
        await ws.request('connectTransport', {
          'transportId': _sendTransport!.id,
          'dtlsParameters': (data['dtlsParameters'] as DtlsParameters).toMap(),
        });
        data['callback']();
      } catch (e) {
        data['errback'](e);
      }
    });

    _sendTransport!.on('produce', (Map data) async {
      try {
        final resp = await ws.request('produce', {
          'transportId': _sendTransport!.id,
          'kind': data['kind'],
          'rtpParameters': (data['rtpParameters'] as RtpParameters).toMap(),
        });
        data['callback'](resp['id']);
      } catch (e) {
        data['errback'](e);
      }
    });

    debugPrint('[Media] Send transport created: ${_sendTransport!.id}');
  }

  // ======================== RECV TRANSPORT ========================

  Future<void> _createRecvTransport() async {
    final data = await ws.request('createWebRtcTransport', {'direction': 'recv'});
    final iceServers = _parseIceServers(data['iceServers'] as List<dynamic>?);
    debugPrint('[Media] Recv transport iceServers: ${iceServers.length}');

    _recvTransport = _device!.createRecvTransport(
      id: data['id'],
      iceParameters: IceParameters.fromMap(data['iceParameters']),
      iceCandidates: List<IceCandidate>.from(
        (data['iceCandidates'] as List).map((c) => IceCandidate.fromMap(c)),
      ),
      dtlsParameters: DtlsParameters.fromMap(data['dtlsParameters']),
      iceServers: iceServers,
      additionalSettings: {'encodedInsertableStreams': false},
      proprietaryConstraints: {'optional': [{'googDscp': true}]},
      consumerCallback: (Consumer consumer, Function? accept) {
        debugPrint('[Media] Consumer created: ${consumer.id} from peer ${consumer.peerId}');
        if (accept != null) accept();
        _consumers[consumer.id] = consumer;
        _playConsumerAudio(consumer);
        // Notify listener (used by tie lines for output routing)
        final streamId = consumer.stream?.id;
        if (streamId != null) {
          onConsumerCreated?.call(consumer.id, streamId);
        }
        // Resume on server
        ws.request('resumeConsumer', {'consumerId': consumer.id});
      },
    );

    _recvTransport!.on('connect', (Map data) async {
      try {
        await ws.request('connectTransport', {
          'transportId': _recvTransport!.id,
          'dtlsParameters': (data['dtlsParameters'] as DtlsParameters).toMap(),
        });
        data['callback']();
      } catch (e) {
        data['errback'](e);
      }
    });

    debugPrint('[Media] Recv transport created: ${_recvTransport!.id}');
  }

  // ======================== PRODUCE ========================

  Future<void> _produceAudio({String? deviceId, int tieLineChannel = -1}) async {
    // Reuse existing mic stream if available (avoids getUserMedia on reconnect,
    // which would kick the app out of PiP on Android)
    if (_localStream != null && _localStream!.getAudioTracks().isNotEmpty) {
      final track = _localStream!.getAudioTracks().first;
      if (track.enabled != false) {
        debugPrint('[Media] Reusing existing mic stream');
        _sendTransport!.produce(
          track: track,
          stream: _localStream!,
          source: 'mic',
          stopTracks: false,
          disableTrackOnPause: false,
          zeroRtpOnPause: false,
        );
        debugPrint('[Media] Producing audio (reused track)...');
        return;
      }
    }

    // First time or track lost — acquire microphone
    final Map<String, dynamic> constraints;
    if (tieLineChannel >= 0) {
      constraints = {
        'audio': {'_mcChannel': tieLineChannel},
        'video': false,
      };
    } else {
      constraints = {
        'audio': deviceId != null ? {'deviceId': {'exact': deviceId}} : true,
        'video': false,
      };
    }
    _localStream = await navigator.mediaDevices.getUserMedia(constraints);
    final track = _localStream!.getAudioTracks().first;

    _sendTransport!.produce(
      track: track,
      stream: _localStream!,
      source: 'mic',
      stopTracks: false,
      disableTrackOnPause: false,
      zeroRtpOnPause: false,
    );
    debugPrint('[Media] Producing audio (new track)...');
  }

  // ======================== DEVICE SELECTION ========================

  Future<Map<String, List<Map<String, String>>>> getAudioDevices() async {
    // Try platform-specific enumeration first (web JS interop)
    final platformDevices = await platformEnumerateAudioDevices();
    if (platformDevices['inputs']!.isNotEmpty || platformDevices['outputs']!.isNotEmpty) {
      debugPrint('[Media] Platform devices: ${platformDevices['inputs']!.length} inputs, ${platformDevices['outputs']!.length} outputs');
      return platformDevices;
    }
    // Fallback to WebRTC API (works on both web and Android)
    try {
      final devices = await navigator.mediaDevices.enumerateDevices();
      final inputs = <Map<String, String>>[];
      final outputs = <Map<String, String>>[];
      for (final d in devices) {
        final label = d.label.isNotEmpty ? d.label : 'Device ${d.deviceId.substring(0, 8)}';
        if (d.kind == 'audioinput') {
          inputs.add({'deviceId': d.deviceId, 'label': label});
        } else if (d.kind == 'audiooutput') {
          outputs.add({'deviceId': d.deviceId, 'label': label});
        }
      }
      debugPrint('[Media] WebRTC devices: ${inputs.length} inputs, ${outputs.length} outputs');
      return {'inputs': inputs, 'outputs': outputs};
    } catch (e) {
      debugPrint('[Media] enumerateDevices failed: $e');
      return {'inputs': <Map<String, String>>[], 'outputs': <Map<String, String>>[]};
    }
  }

  Future<void> switchInputDevice(String deviceId) async {
    debugPrint('[Media] Switching input device to $deviceId...');
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': {'deviceId': {'exact': deviceId}},
      'video': false,
    });
    final newTrack = stream.getAudioTracks().first;
    debugPrint('[Media] New track obtained: ${newTrack.id}, enabled=${newTrack.enabled}');

    if (_producer != null) {
      try {
        await _producer!.replaceTrack(newTrack);
        debugPrint('[Media] replaceTrack succeeded');
      } catch (e) {
        debugPrint('[Media] replaceTrack failed: $e — re-producing...');
        // Fallback: close producer and re-produce
        _producer!.close();
        _producer = null;
        // Stop old tracks before re-producing
        if (_localStream != null) {
          for (final t in _localStream!.getAudioTracks()) {
            t.stop();
          }
        }
        _localStream = stream;
        if (_sendTransport != null) {
          _sendTransport!.produce(
            track: newTrack,
            stream: stream,
            source: 'mic',
            stopTracks: false,
            disableTrackOnPause: false,
            zeroRtpOnPause: true,
          );
          debugPrint('[Media] Re-produced with new input device');
        }
        return;
      }
    }
    // Stop old tracks
    if (_localStream != null) {
      for (final t in _localStream!.getAudioTracks()) {
        t.stop();
      }
    }
    _localStream = stream;
    debugPrint('[Media] Input device switched to $deviceId');
  }

  void setOutputDevice(String deviceId) {
    _selectedOutputDeviceId = deviceId;
    platformSetAudioSinkId(deviceId);
    // Also apply to all existing elements via ensureRemoteAudioPlaying
    platformEnsureRemoteAudioPlaying();
    debugPrint('[Media] Output device set to $deviceId');
  }

  // ======================== CONSUME ========================

  void handleNewConsumer(Map<String, dynamic> msg) {
    if (_recvTransport == null) {
      debugPrint('[Media] handleNewConsumer: recvTransport is null, ignoring');
      return;
    }

    try {
      debugPrint('[Media] handleNewConsumer: id=${msg['id']} from peer=${msg['producerPeerId']}');
      _recvTransport!.consume(
        id: msg['id'],
        producerId: msg['producerId'],
        kind: RTCRtpMediaTypeExtension.fromString(msg['kind']),
        rtpParameters: RtpParameters.fromMap(msg['rtpParameters']),
        peerId: msg['producerPeerId']?.toString() ?? '',
      );
    } catch (e) {
      debugPrint('[Media] handleNewConsumer ERROR: $e');
    }
  }

  void handleConsumersClosed(String peerId) {
    final toRemove = <String>[];
    for (final entry in _consumers.entries) {
      if (entry.value.peerId == peerId) {
        toRemove.add(entry.key);
      }
    }
    for (final id in toRemove) {
      _stopConsumerAudio(id);
      _consumers[id]?.close();
      _consumers.remove(id);
    }
    debugPrint('[Media] Consumers closed for peer $peerId (${toRemove.length} removed)');
  }

  /// Close specific consumers by their IDs (safer — won't kill newer consumers)
  void handleConsumersClosedByIds(List<String> consumerIds) {
    for (final id in consumerIds) {
      if (_consumers.containsKey(id)) {
        _stopConsumerAudio(id);
        _consumers[id]?.close();
        _consumers.remove(id);
      }
    }
    debugPrint('[Media] Specific consumers closed: ${consumerIds.length} IDs');
  }

  // ======================== AUDIO PLAYBACK ========================

  Future<void> _playConsumerAudio(Consumer consumer) async {
    try {
      final renderer = RTCVideoRenderer();
      await renderer.initialize();
      renderer.srcObject = consumer.stream;
      _renderers[consumer.id] = renderer;
      debugPrint('[Media] Playing audio from consumer ${consumer.id}');
      // Force unmute all remote audio elements repeatedly
      // (workaround for ownerTag=='local' muting bug + autoplay policy)
      for (final delay in [100, 300, 600, 1200]) {
        Future.delayed(Duration(milliseconds: delay), () {
          platformEnsureRemoteAudioPlaying();
          // Apply saved volume for this peer
          _applyVolumeForConsumer(consumer);
        });
      }
    } catch (e) {
      debugPrint('[Media] Error playing audio: $e');
    }
  }

  void _applyVolumeForConsumer(Consumer consumer) {
    final volume = _peerVolumes[consumer.peerId];
    // Only apply if user explicitly changed volume (skip default 1.0)
    if (volume != null && volume != 1.0) {
      _setConsumerVolume(consumer, volume);
    }
  }

  void _stopConsumerAudio(String consumerId) {
    final renderer = _renderers.remove(consumerId);
    if (renderer != null) {
      renderer.srcObject = null;
      renderer.dispose();
    }
  }

  // ======================== MUTE BY PEER ========================

  void muteByPeerId(String peerId) {
    for (final entry in _consumers.entries) {
      if (entry.value.peerId == peerId) {
        entry.value.pause();
        debugPrint('[Media] Paused consumer ${entry.key} (peer $peerId)');
      }
    }
  }

  void unmuteByPeerId(String peerId) {
    for (final entry in _consumers.entries) {
      if (entry.value.peerId == peerId) {
        entry.value.resume();
        debugPrint('[Media] Resumed consumer ${entry.key} (peer $peerId)');
      }
    }
  }

  bool isPeerMuted(String peerId) {
    for (final entry in _consumers.entries) {
      if (entry.value.peerId == peerId && entry.value.paused) {
        return true;
      }
    }
    return false;
  }

  // ======================== PER-PEER VOLUME ========================

  void setVolumeByPeerId(String peerId, double volume) {
    _peerVolumes[peerId] = volume;
    for (final consumer in _consumers.values) {
      if (consumer.peerId == peerId) {
        _setConsumerVolume(consumer, volume);
      }
    }
    debugPrint('[Media] Volume for peer $peerId set to ${(volume * 100).round()}%');
  }

  void _setConsumerVolume(Consumer consumer, double volume) {
    // Web: set HTML element volume via JS
    if (consumer.stream != null) {
      platformSetStreamVolume(consumer.stream!.id, volume);
      for (final track in consumer.stream!.getAudioTracks()) {
        platformSetStreamVolume(track.id!, volume);
      }
    }
    // Native (Android): use flutter_webrtc's native setVolume
    if (consumer.track != null && consumer.track!.kind == 'audio') {
      Helper.setVolume(volume, consumer.track!).catchError((e) {
        debugPrint('[Media] Helper.setVolume error: $e');
      });
    }
  }

  double getVolumeByPeerId(String peerId) {
    return _peerVolumes[peerId] ?? 1.0;
  }

  // ======================== CLEANUP ========================

  /// Dispose transports and consumers, but keep _localStream alive
  /// so it can be reused on reconnect (avoids getUserMedia in PiP/background).
  Future<void> dispose() async {
    for (final id in _renderers.keys.toList()) {
      _stopConsumerAudio(id);
    }
    for (final c in _consumers.values) {
      try { await c.close(); } catch (_) {}
    }
    _consumers.clear();
    try { _producer?.close(); } catch (_) {}
    _producer = null;
    try { await _sendTransport?.close(); } catch (_) {}
    _sendTransport = null;
    try { await _recvTransport?.close(); } catch (_) {}
    _recvTransport = null;
    _device = null;
    // NOTE: _localStream is intentionally kept alive for reuse
  }

  /// Full cleanup including microphone (call on logout)
  Future<void> disposeAll() async {
    await dispose();
    if (_localStream != null) {
      for (final t in _localStream!.getAudioTracks()) {
        try { t.stop(); } catch (_) {}
      }
      _localStream = null;
    }
  }
}
