import 'dart:async';
import 'package:flutter/material.dart';
import '../services/matrix_channel.dart';
import '../services/api_service.dart';
import '../platform/platform_utils.dart';

class MatrixStationScreen extends StatefulWidget {
  const MatrixStationScreen({super.key});

  @override
  State<MatrixStationScreen> createState() => _MatrixStationScreenState();
}

class _MatrixStationScreenState extends State<MatrixStationScreen> {
  final List<MatrixChannel> _channels = [];
  bool _loading = true;
  bool _multiChannelActive = false;

  // Global audio device selection
  String? _globalInputDeviceId;
  String? _globalOutputDeviceId;
  int _numChannels = 16;

  // Cached audio devices and user/group lists for config dialogs
  List<Map<String, String>> _audioInputs = [];
  List<Map<String, String>> _audioOutputs = [];
  List<Map<String, dynamic>> _allUsers = [];
  List<Map<String, dynamic>> _allGroups = [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final configs = await MatrixChannel.loadAllConfigs();
    for (int i = 0; i < 16; i++) {
      final ch = MatrixChannel(index: i, config: configs[i]);
      ch.addListener(() { if (mounted) setState(() {}); });
      _channels.add(ch);
    }
    // Load saved global settings
    await _loadGlobalSettings();
    // Enumerate audio devices
    await _loadAudioDevices();
    // Load users/groups for target selection
    await _loadUsersAndGroups();
    setState(() => _loading = false);
  }

  Future<void> _loadGlobalSettings() async {
    final prefs = await MatrixChannel.loadGlobalSettings();
    _globalInputDeviceId = prefs['inputDeviceId'];
    _globalOutputDeviceId = prefs['outputDeviceId'];
    _numChannels = prefs['numChannels'] ?? 16;
  }

  Future<void> _saveGlobalSettings() async {
    await MatrixChannel.saveGlobalSettings(
      inputDeviceId: _globalInputDeviceId,
      outputDeviceId: _globalOutputDeviceId,
      numChannels: _numChannels,
    );
  }

  Future<void> _loadAudioDevices() async {
    try {
      final devices = await platformEnumerateAudioDevices();
      _audioInputs = devices['inputs'] ?? [];
      _audioOutputs = devices['outputs'] ?? [];
    } catch (_) {}
  }

  Future<void> _loadUsersAndGroups() async {
    try {
      final api = ApiService(baseUrl: getServerBaseUrl());
      final configured = _channels.where((c) => c.config.isConfigured).toList();
      if (configured.isEmpty) return;
      final cfg = configured.first.config;
      await api.login(cfg.username, cfg.password);
      try {
        final users = await api.getUsers();
        final groups = await api.getGroups();
        _allUsers = List<Map<String, dynamic>>.from(users);
        _allGroups = List<Map<String, dynamic>>.from(groups);
      } catch (_) {
        final targets = await api.getMyTargets();
        _allUsers = List<Map<String, dynamic>>.from(targets['users'] ?? []);
        _allGroups = List<Map<String, dynamic>>.from(targets['groups'] ?? []);
      }
    } catch (_) {}
  }

  Future<void> _saveConfigs() async {
    await MatrixChannel.saveAllConfigs(_channels.map((c) => c.config).toList());
  }

  // ======================== CONNECT / DISCONNECT ========================

  Future<void> _connectAll() async {
    if (_globalInputDeviceId == null || _globalOutputDeviceId == null) {
      _showSnackBar('Select input and output devices first');
      return;
    }

    // Initialize multi-channel audio (captures + splits input, sets up output merger)
    final result = await platformInitMultiChannel(
      _globalInputDeviceId!, _globalOutputDeviceId!, _numChannels,
    );
    if (result == 0) {
      _showSnackBar('Error initializing multi-channel audio');
      return;
    }
    _multiChannelActive = true;
    setState(() {});

    // Connect all configured channels
    for (final ch in _channels) {
      if (ch.config.isConfigured && ch.state == ChannelState.disconnected) {
        ch.connect(); // Don't await — connect in parallel
      }
    }
  }

  Future<void> _disconnectAll() async {
    for (final ch in _channels) {
      if (ch.state != ChannelState.disconnected) {
        await ch.disconnect();
      }
    }
    // Destroy multi-channel audio
    platformDestroyMultiChannel();
    _multiChannelActive = false;
    setState(() {});
  }

  void _showSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  int get _connectedCount => _channels.where((c) => c.state == ChannelState.connected).length;
  int get _configuredCount => _channels.where((c) => c.config.isConfigured).length;

  @override
  void dispose() {
    for (final ch in _channels) {
      ch.dispose();
    }
    platformDestroyMultiChannel();
    super.dispose();
  }

  // ======================== GLOBAL DEVICE SETTINGS DIALOG ========================

  Future<void> _showDeviceSettingsDialog() async {
    await _loadAudioDevices();
    if (!mounted) return;

    String? selInput = _globalInputDeviceId;
    String? selOutput = _globalOutputDeviceId;
    int selChannels = _numChannels;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Audio Devices'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Input (Blackhole/Dante/MADI)', style: TextStyle(fontSize: 12, color: Colors.grey)),
                DropdownButton<String>(
                  value: _audioInputs.any((d) => d['deviceId'] == selInput) ? selInput : null,
                  isExpanded: true,
                  hint: const Text('Select...'),
                  items: _audioInputs.map((d) => DropdownMenuItem(
                    value: d['deviceId'],
                    child: Text(d['label'] ?? '?', overflow: TextOverflow.ellipsis),
                  )).toList(),
                  onChanged: (v) => setDialogState(() => selInput = v),
                ),
                const SizedBox(height: 12),
                const Text('Output (Blackhole/Dante/MADI)', style: TextStyle(fontSize: 12, color: Colors.grey)),
                DropdownButton<String>(
                  value: _audioOutputs.any((d) => d['deviceId'] == selOutput) ? selOutput : null,
                  isExpanded: true,
                  hint: const Text('Select...'),
                  items: _audioOutputs.map((d) => DropdownMenuItem(
                    value: d['deviceId'],
                    child: Text(d['label'] ?? '?', overflow: TextOverflow.ellipsis),
                  )).toList(),
                  onChanged: (v) => setDialogState(() => selOutput = v),
                ),
                const SizedBox(height: 12),
                Text('Channels: $selChannels', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                Slider(
                  value: selChannels.toDouble(),
                  min: 2,
                  max: 16,
                  divisions: 7,
                  label: '$selChannels',
                  onChanged: (v) => setDialogState(() => selChannels = v.round()),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );

    if (result == true) {
      _globalInputDeviceId = selInput;
      _globalOutputDeviceId = selOutput;
      _numChannels = selChannels;
      await _saveGlobalSettings();
      setState(() {});
    }
  }

  // ======================== PER-CHANNEL CONFIG DIALOG ========================

  /// Try to fetch users/groups using given credentials
  Future<bool> _fetchTargetsWithCredentials(String username, String password) async {
    if (username.isEmpty || password.isEmpty) return false;
    try {
      final api = ApiService(baseUrl: getServerBaseUrl());
      await api.login(username, password);
      try {
        final users = await api.getUsers();
        final groups = await api.getGroups();
        _allUsers = List<Map<String, dynamic>>.from(users);
        _allGroups = List<Map<String, dynamic>>.from(groups);
      } catch (_) {
        final targets = await api.getMyTargets();
        _allUsers = List<Map<String, dynamic>>.from(targets['users'] ?? []);
        _allGroups = List<Map<String, dynamic>>.from(targets['groups'] ?? []);
      }
      return _allUsers.isNotEmpty || _allGroups.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> _showConfigDialog(MatrixChannel channel) async {
    final cfg = channel.config;
    final userCtrl = TextEditingController(text: cfg.username);
    final passCtrl = TextEditingController(text: cfg.password);
    String? selectedTargetType = cfg.targetType;
    int? selectedTargetId = cfg.targetId;
    String? selectedTargetName = cfg.targetName;
    double threshold = cfg.voxThresholdDb;
    int holdMs = cfg.voxHoldMs;
    bool loadingTargets = false;

    // Try to load targets if empty and we have credentials
    if (_allUsers.isEmpty && _allGroups.isEmpty) {
      // Try from this channel's saved config, or from any configured channel
      String u = cfg.username;
      String p = cfg.password;
      if (u.isEmpty || p.isEmpty) {
        final other = _channels.where((c) => c.config.isConfigured).toList();
        if (other.isNotEmpty) {
          u = other.first.config.username;
          p = other.first.config.password;
        }
      }
      if (u.isNotEmpty && p.isNotEmpty) {
        await _fetchTargetsWithCredentials(u, p);
      }
    }

    if (!mounted) return;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          // Build target dropdown items
          final targetItems = <DropdownMenuItem<String>>[];
          targetItems.add(const DropdownMenuItem(value: '', child: Text('\u{2014} No target \u{2014}')));
          for (final u in _allUsers) {
            targetItems.add(DropdownMenuItem(
              value: 'user:${u['id']}',
              child: Text('\u{1F464} ${u['display_name'] ?? u['username']}'),
            ));
          }
          for (final g in _allGroups) {
            targetItems.add(DropdownMenuItem(
              value: 'group:${g['id']}',
              child: Text('\u{1F465} ${g['name']}'),
            ));
          }
          final currentTargetValue = selectedTargetType != null && selectedTargetId != null
              ? '$selectedTargetType:$selectedTargetId'
              : '';

          return AlertDialog(
            title: Text('Channel ${channel.index + 1}'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(controller: userCtrl, decoration: const InputDecoration(labelText: 'Username')),
                  const SizedBox(height: 8),
                  TextField(controller: passCtrl, decoration: const InputDecoration(labelText: 'Password'), obscureText: true),
                  const SizedBox(height: 16),

                  // Target selection with refresh button
                  Row(
                    children: [
                      const Text('Target PTT', style: TextStyle(fontSize: 12, color: Colors.grey)),
                      const Spacer(),
                      if (loadingTargets)
                        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      else
                        InkWell(
                          onTap: () async {
                            setDialogState(() => loadingTargets = true);
                            await _fetchTargetsWithCredentials(userCtrl.text.trim(), passCtrl.text);
                            setDialogState(() => loadingTargets = false);
                          },
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(Icons.refresh, size: 18, color: Colors.grey),
                          ),
                        ),
                    ],
                  ),
                  if (_allUsers.isEmpty && _allGroups.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        'Enter user/pass and tap \u{21BB} to load targets',
                        style: TextStyle(fontSize: 11, color: Colors.orange.shade300),
                      ),
                    ),
                  DropdownButton<String>(
                    value: targetItems.any((i) => i.value == currentTargetValue) ? currentTargetValue : '',
                    isExpanded: true,
                    items: targetItems,
                    onChanged: (val) {
                      setDialogState(() {
                        if (val == null || val.isEmpty) {
                          selectedTargetType = null;
                          selectedTargetId = null;
                          selectedTargetName = null;
                        } else {
                          final parts = val.split(':');
                          selectedTargetType = parts[0];
                          selectedTargetId = int.parse(parts[1]);
                          if (parts[0] == 'user') {
                            final u = _allUsers.firstWhere((u) => u['id'] == selectedTargetId, orElse: () => {});
                            selectedTargetName = u['display_name'] ?? u['username'] ?? '?';
                          } else {
                            final g = _allGroups.firstWhere((g) => g['id'] == selectedTargetId, orElse: () => {});
                            selectedTargetName = g['name'] ?? '?';
                          }
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 16),

                  // VOX threshold
                  Text('VOX Threshold: ${threshold.round()} dB', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  Slider(
                    value: threshold,
                    min: -60,
                    max: -10,
                    divisions: 50,
                    label: '${threshold.round()} dB',
                    onChanged: (v) => setDialogState(() => threshold = v),
                  ),

                  // Hold time
                  Text('VOX Hold: $holdMs ms', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  Slider(
                    value: holdMs.toDouble(),
                    min: 100,
                    max: 2000,
                    divisions: 19,
                    label: '$holdMs ms',
                    onChanged: (v) => setDialogState(() => holdMs = v.round()),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  setDialogState(() {
                    userCtrl.clear();
                    passCtrl.clear();
                    selectedTargetType = null;
                    selectedTargetId = null;
                    selectedTargetName = null;
                  });
                },
                child: Text('Clear', style: TextStyle(color: Colors.red.shade400)),
              ),
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
            ],
          );
        },
      ),
    );

    if (result == true) {
      final wasConnected = channel.state != ChannelState.disconnected;
      if (wasConnected) await channel.disconnect();

      channel.config = ChannelConfig(
        username: userCtrl.text.trim(),
        password: passCtrl.text,
        targetType: selectedTargetType,
        targetId: selectedTargetId,
        targetName: selectedTargetName,
        voxThresholdDb: threshold,
        voxHoldMs: holdMs,
      );
      await _saveConfigs();
      setState(() {});

      if (wasConnected && channel.config.isConfigured && _multiChannelActive) {
        channel.connect();
      }
    }
  }

  // ======================== UI ========================

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        backgroundColor: Colors.grey.shade900,
        body: const Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    // Device info for app bar
    final inputLabel = _audioInputs.firstWhere(
        (d) => d['deviceId'] == _globalInputDeviceId, orElse: () => {})['label'];
    final outputLabel = _audioOutputs.firstWhere(
        (d) => d['deviceId'] == _globalOutputDeviceId, orElse: () => {})['label'];

    return Scaffold(
      backgroundColor: Colors.grey.shade900,
      appBar: AppBar(
        backgroundColor: Colors.grey.shade800,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Row(
          children: [
            const Icon(Icons.cable, size: 22),
            const SizedBox(width: 8),
            const Text('Tie Lines'),
            const SizedBox(width: 12),
            // Multi-channel status indicator
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _multiChannelActive ? Colors.green.withValues(alpha: 0.2) : Colors.white.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _multiChannelActive ? Colors.green : Colors.grey.shade600,
                ),
              ),
              child: Text(
                _multiChannelActive ? '$_connectedCount / $_configuredCount' : 'OFF',
                style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.bold,
                  color: _multiChannelActive ? Colors.greenAccent : Colors.grey,
                ),
              ),
            ),
            const Spacer(),
            // Device summary
            if (inputLabel != null || outputLabel != null)
              Flexible(
                child: Text(
                  '${inputLabel ?? '?'} \u{2194} ${outputLabel ?? '?'}',
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade400),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings, size: 20),
            tooltip: 'Devices',
            onPressed: _showDeviceSettingsDialog,
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            tooltip: 'Refresh',
            onPressed: () async {
              await _loadAudioDevices();
              await _loadUsersAndGroups();
              setState(() {});
            },
          ),
          TextButton.icon(
            icon: const Icon(Icons.play_arrow, color: Colors.greenAccent),
            label: const Text('Connect', style: TextStyle(color: Colors.greenAccent)),
            onPressed: _multiChannelActive ? null : _connectAll,
          ),
          TextButton.icon(
            icon: const Icon(Icons.stop, color: Colors.redAccent),
            label: const Text('Stop', style: TextStyle(color: Colors.redAccent)),
            onPressed: _multiChannelActive ? _disconnectAll : null,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.4,
          ),
          itemCount: _numChannels,
          itemBuilder: (context, i) => _buildChannelCard(_channels[i]),
        ),
      ),
    );
  }

  Widget _buildChannelCard(MatrixChannel ch) {
    final configured = ch.config.isConfigured;
    final connected = ch.state == ChannelState.connected;
    final connecting = ch.state == ChannelState.connecting;
    final hasError = ch.state == ChannelState.error;

    // Status color
    Color statusColor;
    if (ch.voxActive) {
      statusColor = Colors.red;
    } else if (ch.receiving) {
      statusColor = Colors.blue;
    } else if (connected) {
      statusColor = Colors.green;
    } else if (connecting) {
      statusColor = Colors.orange;
    } else if (hasError) {
      statusColor = Colors.red.shade300;
    } else {
      statusColor = Colors.grey.shade600;
    }

    return GestureDetector(
      onTap: () => _showConfigDialog(ch),
      onDoubleTap: () {
        if (connected || connecting) {
          ch.disconnect();
        } else if (configured && _multiChannelActive) {
          ch.connect();
        }
      },
      child: Container(
        decoration: BoxDecoration(
          color: connected ? Colors.grey.shade800 : Colors.grey.shade900,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: ch.voxActive ? Colors.red : (connected ? Colors.green.shade700 : Colors.grey.shade700),
            width: ch.voxActive ? 2 : 1,
          ),
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: channel number + status dot
            Row(
              children: [
                Text('${ch.index + 1}',
                    style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold,
                      color: configured ? Colors.white : Colors.grey.shade500,
                    )),
                const SizedBox(width: 6),
                Container(
                  width: 10, height: 10,
                  decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
                ),
                const Spacer(),
                if (connecting)
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange)),
              ],
            ),
            const SizedBox(height: 4),

            // User name
            Text(
              ch.displayName ?? ch.config.username.ifEmpty('\u{2014}'),
              style: TextStyle(fontSize: 12, color: configured ? Colors.white70 : Colors.grey.shade600),
              overflow: TextOverflow.ellipsis,
            ),

            // Target
            if (ch.config.hasTarget)
              Text(
                '\u{2192} ${ch.config.targetName ?? '?'}',
                style: TextStyle(fontSize: 10, color: Colors.grey.shade400),
                overflow: TextOverflow.ellipsis,
              ),

            const Spacer(),

            // Audio level bar
            if (connected)
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: ch.inputLevel,
                  minHeight: 4,
                  backgroundColor: Colors.grey.shade700,
                  valueColor: AlwaysStoppedAnimation(
                    ch.voxActive ? Colors.red : Colors.green.shade600,
                  ),
                ),
              ),

            // Error
            if (hasError && ch.error != null)
              Text(ch.error!, style: TextStyle(fontSize: 9, color: Colors.red.shade300),
                  overflow: TextOverflow.ellipsis, maxLines: 1),
          ],
        ),
      ),
    );
  }
}

extension _StringExt on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
