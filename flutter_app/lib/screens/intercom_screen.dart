import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/intercom_provider.dart';
import '../widgets/ptt_button.dart';
import '../platform/platform_utils.dart';
import '../theme/app_theme.dart';

Color? _parseColor(String? hex) {
  if (hex == null || hex.isEmpty) return null;
  final h = hex.replaceAll('#', '');
  return Color(int.parse('FF$h', radix: 16));
}

class IntercomScreen extends StatefulWidget {
  const IntercomScreen({super.key});

  @override
  State<IntercomScreen> createState() => _IntercomScreenState();
}

class _IntercomScreenState extends State<IntercomScreen> {
  static const _pipChannel = MethodChannel('tv.huin.intercom/pip');

  @override
  void initState() {
    super.initState();
    platformRequestWakeLock();
    // Listen for PiP mode changes from Android
    _pipChannel.setMethodCallHandler((call) async {
      if (call.method == 'pipChanged' && mounted) {
        final inPip = call.arguments as bool? ?? false;
        context.read<IntercomProvider>().setPipMode(inPip);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthProvider>();
      final intercom = context.read<IntercomProvider>();
      if (auth.token != null) {
        intercom.connect(auth.token!);
      }
    });
  }

  @override
  void dispose() {
    _pipChannel.setMethodCallHandler(null);
    platformReleaseWakeLock();
    super.dispose();
  }

  Widget _buildTargetButton(IntercomProvider ic, String type, int id, String label, bool online, {Color? color}) {
    final talking = ic.isTalkingTo(type, id);
    final latch = ic.isLatch(type, id);
    return PttButton(
      label: label,
      online: online,
      active: talking,
      enabled: ic.mediaReady,
      isLatch: latch,
      userColor: color,
      volume: type == 'user' ? ic.getUserVolume(id) : ic.getGroupVolume(id),
      onVolumeChanged: type == 'user'
          ? (v) => ic.setUserVolume(id, v)
          : (v) => ic.setGroupVolume(id, v),
      onPttStart: () => ic.startTalking(type, id),
      onPttStop: () => ic.stopTalking(type, id),
      onTap: () => ic.onPttTap(type, id),
      onToggleLatch: () => ic.toggleLatch(type, id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final ic = context.watch<IntercomProvider>();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: AppColors.backgroundAlt,
        foregroundColor: AppColors.textPrimary,
        title: Row(
          children: [
            const Icon(Icons.headset_mic, size: 22),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(auth.user?['display_name'] ?? 'Winus Intercom', style: const TextStyle(fontSize: 16)),
const Text('v2.4.1', style: TextStyle(fontSize: 10, color: AppColors.textSecondary)),
              ],
            ),
          ],
        ),
        actions: [
          // Mic mute button
          IconButton(
            icon: Icon(
              ic.micMuted ? Icons.mic_off : Icons.mic,
              color: ic.micMuted ? Colors.red.shade400 : AppColors.textPrimary,
              size: 24,
            ),
            tooltip: ic.micMuted ? 'Unmute mic' : 'Mute mic',
            onPressed: ic.mediaReady ? () => ic.toggleMicMute() : null,
          ),
          // Status chip
          Container(
            margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: ic.micMuted
                  ? Colors.red.shade900.withValues(alpha: 0.3)
                  : Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: ic.micMuted ? Colors.red.shade700 : AppColors.border,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, size: 8,
                    color: ic.micMuted
                        ? Colors.red.shade400
                        : ic.connected && ic.mediaReady
                            ? Colors.green
                            : AppColors.disconnectedGreyLight),
                const SizedBox(width: 6),
                Text(
                  ic.micMuted
                      ? 'MIC OFF'
                      : ic.mediaReady
                          ? 'Connected${ic.rttMs != null ? ' · ${ic.rttMs!.round()}ms' : ''}'
                          : ic.connected ? 'Loading...' : 'Connecting...',
                  style: TextStyle(
                    fontSize: 12,
                    color: ic.micMuted ? Colors.red.shade300 : null,
                  ),
                ),
              ],
            ),
          ),
          if (auth.isAdmin)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: TextButton.icon(
                icon: const Icon(Icons.admin_panel_settings, color: Colors.white, size: 24),
                label: const Text('Admin', style: TextStyle(color: Colors.white, fontSize: 14)),
                onPressed: () => Navigator.pushNamed(context, '/admin'),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await ic.disconnect();
              await auth.logout();
              if (mounted) Navigator.pushReplacementNamed(context, '/');
            },
          ),
        ],
      ),
      body: !ic.mediaReady
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(color: AppColors.pressedBlueLight),
                  const SizedBox(height: 20),
                  Text(
                    ic.connected ? 'Initializing audio...' : 'Connecting to server...',
                    style: const TextStyle(fontSize: 16, color: AppColors.textSecondary),
                  ),
                  if (ic.error != null) ...[
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(ic.error!, style: TextStyle(color: Colors.red.shade700, fontSize: 13), textAlign: TextAlign.center),
                    ),
                  ],
                  if (!isWeb) ...[
                    const SizedBox(height: 24),
                    TextButton.icon(
                      icon: const Icon(Icons.settings),
                      label: const Text('Change server'),
                      onPressed: () async {
                        await ic.disconnect();
                        if (context.mounted) Navigator.pushReplacementNamed(context, '/server_config');
                      },
                    ),
                  ],
                ],
              ),
            )
          : SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Audio device selection
            if (ic.audioInputs.isNotEmpty || ic.audioOutputs.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.border),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.22),
                      blurRadius: 10,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    if (ic.audioInputs.isNotEmpty)
                      Row(
                        children: [
                          const Icon(Icons.mic, size: 16, color: AppColors.connectedBlueGreyLight),
                          const SizedBox(width: 6),
                          Expanded(
                            child: DropdownButton<String>(
                              value: ic.audioInputs.any((d) => d['deviceId'] == ic.selectedInputId)
                                  ? ic.selectedInputId
                                  : ic.audioInputs.first['deviceId'],
                              isExpanded: true,
                              isDense: true,
                              underline: const SizedBox(),
                              style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                              items: ic.audioInputs.map((d) => DropdownMenuItem(
                                value: d['deviceId'],
                                child: Text(d['label'] ?? '?', overflow: TextOverflow.ellipsis),
                              )).toList(),
                              onChanged: (v) { if (v != null) ic.switchInputDevice(v); },
                            ),
                          ),
                        ],
                      ),
                    if (ic.audioOutputs.isNotEmpty) ...[                      
                      if (ic.audioInputs.isNotEmpty)
                        const Divider(height: 8, color: AppColors.border),
                      Row(
                        children: [
                          const Icon(Icons.volume_up, size: 16, color: AppColors.connectedBlueGreyLight),
                          const SizedBox(width: 6),
                          Expanded(
                            child: DropdownButton<String>(
                              value: ic.audioOutputs.any((d) => d['deviceId'] == ic.selectedOutputId)
                                  ? ic.selectedOutputId
                                  : ic.audioOutputs.first['deviceId'],
                              isExpanded: true,
                              isDense: true,
                              underline: const SizedBox(),
                              style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                              items: ic.audioOutputs.map((d) => DropdownMenuItem(
                                value: d['deviceId'],
                                child: Text(d['label'] ?? '?', overflow: TextOverflow.ellipsis),
                              )).toList(),
                              onChanged: (v) { if (v != null) ic.switchOutputDevice(v); },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),

            // Incoming audio banner
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: ic.incomingFrom != null
                  ? Container(
                      key: ValueKey(ic.incomingFrom),
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [AppColors.connectedBlueGrey, AppColors.pressedBlueDark],
                        ),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.connectedBlueGrey.withValues(alpha: 0.35),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.volume_up, color: Colors.white, size: 22),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Receiving audio from ${ic.incomingFrom}',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
                            ),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),

            // Error
            if (ic.error != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.red.shade900.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.red.shade300.withValues(alpha: 0.35)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, color: Colors.red.shade400, size: 20),
                    const SizedBox(width: 8),
                    Expanded(child: Text(ic.error!, style: TextStyle(color: Colors.red.shade700, fontSize: 13))),
                  ],
                ),
              ),

            // Users section (non-bridge)
            ..._buildTargetSection(
              ic,
              icon: Icons.person,
              title: 'Users',
              items: ic.userTargets.where((u) => u['role'] != 'bridge').toList(),
              emptyText: 'No user permissions',
              builder: (u) {
                final id = u['id'] as int;
                return _buildTargetButton(ic, 'user', id,
                    u['display_name'] ?? 'User $id', ic.onlineUserIds.contains(id),
                    color: _parseColor(u['color'] as String?));
              },
            ),

            // Bridges section
            ...(() {
              final bridges = ic.userTargets.where((u) => u['role'] == 'bridge').toList();
              if (bridges.isEmpty) return <Widget>[];
              return _buildTargetSection(
                ic,
                icon: Icons.link,
                title: 'Bridges',
                items: bridges,
                emptyText: '',
                builder: (u) {
                  final id = u['id'] as int;
                  return _buildTargetButton(ic, 'user', id,
                      u['display_name'] ?? 'Bridge $id', ic.onlineUserIds.contains(id),
                      color: _parseColor(u['color'] as String?));
                },
              );
            })(),

            // Groups section
            ..._buildTargetSection(
              ic,
              icon: Icons.group,
              title: 'Groups',
              items: ic.groupTargets,
              emptyText: 'No groups assigned',
              builder: (g) {
                final id = g['id'] as int;
                final memberCount = (g['member_rooms'] as List?)?.length ?? 0;
                return _buildTargetButton(ic, 'group', id,
                    '${g['name']} ($memberCount)', true);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildButtonGrid(List<Widget> buttons) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const columns = 3;
        const spacing = 10.0;
        final itemWidth = (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: buttons.map((b) => SizedBox(width: itemWidth, child: b)).toList(),
        );
      },
    );
  }

  Widget _sectionHeader(IconData icon, String title) {
    return Row(
      children: [
        Icon(icon, size: 20, color: AppColors.pressedBlueLight),
        const SizedBox(width: 8),
        Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
      ],
    );
  }

  List<Widget> _buildTargetSection(
    dynamic ic, {
    required IconData icon,
    required String title,
    required List<Map<String, dynamic>> items,
    required String emptyText,
    required Widget Function(Map<String, dynamic>) builder,
  }) {
    return [
      const SizedBox(height: 28),
      _sectionHeader(icon, title),
      const SizedBox(height: 12),
      if (items.isEmpty && emptyText.isNotEmpty)
        _emptyCard(emptyText)
      else if (items.isNotEmpty)
        _buildButtonGrid(items.map(builder).toList()),
    ];
  }

  Widget _emptyCard(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Text(
        text,
        style: const TextStyle(color: AppColors.textSecondary),
        textAlign: TextAlign.center,
      ),
    );
  }
}
