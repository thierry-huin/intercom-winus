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

  bool _ringDialogOpen = false;
  Future<void> _maybeShowIncomingRingDialog(IntercomProvider ic) async {
    if (_ringDialogOpen) return;
    _ringDialogOpen = true;
    final ring = ic.incomingRing;
    if (ring == null) {
      _ringDialogOpen = false;
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.notifications_active, color: Colors.amber.shade400, size: 40),
        title: const Text('Attention'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${ring['fromDisplayName']} is calling your attention',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            if ((ring['reason'] as String?)?.isNotEmpty == true) ...[
              const SizedBox(height: 8),
              Text(
                ring['reason'] as String,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              ic.dismissIncomingRing();
              Navigator.of(ctx).pop();
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
    _ringDialogOpen = false;
  }

  Widget _buildTargetButton(
    IntercomProvider ic,
    String type,
    int id,
    String label,
    bool online, {
    Color? color,
    bool isAdmin = false,
    bool isBridge = false,
  }) {
    final talking = ic.isTalkingTo(type, id);
    final latch = ic.isLatch(type, id);
    // Top strip (with green RX feedback) is shown for every regular user
    // target. Bridges and groups never get one because we don't track an
    // "is this peer talking right now" state for them. The strip is also
    // interactive (bell + RING + tap) only on admin / superuser sessions;
    // regular users see the same passive strip purely as the RX indicator.
    final showTopStrip = type == 'user' && !isBridge;
    final topStripInteractive = isAdmin && showTopStrip;
    // Bright-green top strip when *this* user is currently talking to us.
    // Multiple users can transmit simultaneously, so we light up every
    // matching button (replaces the old single "Receiving audio from X"
    // banner above the grid). The provider keeps the id in the set for 3 s
    // after the user stops talking so the listener has time to spot it.
    final receiving = showTopStrip && ic.incomingFromUserIds.contains(id);
    return PttButton(
      label: label,
      online: online,
      active: talking,
      receiving: receiving,
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
      showTopStrip: showTopStrip,
      topStripInteractive: topStripInteractive,
      onRing: topStripInteractive ? () => ic.ringUser(id) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final ic = context.watch<IntercomProvider>();

    // Incoming-ring modal: show a blocking dialog when _incomingRing is set.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ic.incomingRing != null && ModalRoute.of(context)?.isCurrent == true) {
        _maybeShowIncomingRingDialog(ic);
      }
      if (ic.ringFeedback != null) {
        final msg = ic.ringFeedback!;
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ));
        ic.clearRingFeedback();
      }
    });

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: AppColors.backgroundAlt,
        foregroundColor: AppColors.textPrimary,
        title: Row(
          children: [
            Image.asset('assets/winus_logo.png', width: 26, height: 26),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(auth.user?['display_name'] ?? 'Winus Intercom', style: const TextStyle(fontSize: 16)),
                const Text('v3.4.3', style: TextStyle(fontSize: 10, color: AppColors.textSecondary)),
              ],
            ),
          ],
        ),
        actions: [
          // "Call in progress" chip — shown while the OS has taken audio
          // focus away (GSM, WhatsApp, FaceTime…). Disappears as soon as
          // the intercom mic is reacquired.
          if (ic.callInterruption)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.orange.shade900.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.orange.shade700),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.call, size: 14, color: Colors.orange.shade200),
                  const SizedBox(width: 6),
                  Text('Call in progress',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.orange.shade100)),
                ],
              ),
            ),
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
          // Refresh user / group list. Pulls /api/rooms/my-targets again so
          // a user created (or a permission granted) by the admin while
          // we're connected appears immediately without having to log out.
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh users / groups',
            onPressed: ic.connected
                ? () async {
                    try {
                      final r = await ic.refreshTargets();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).hideCurrentSnackBar();
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(
                            'Refreshed: ${r.users} users, ${r.groups} groups'),
                        duration: const Duration(seconds: 2),
                        behavior: SnackBarBehavior.floating,
                      ));
                    } catch (e) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text('Refresh failed: $e'),
                        duration: const Duration(seconds: 3),
                        behavior: SnackBarBehavior.floating,
                      ));
                    }
                  }
                : null,
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
                          ? (ic.rttMs != null
                              ? '${ic.rttMs!.round()} ms'
                              : '— ms')
                          : ic.connected ? 'Loading...' : 'Connecting...',
                  style: TextStyle(
                    fontSize: 12,
                    color: ic.micMuted ? Colors.red.shade300 : null,
                  ),
                ),
              ],
            ),
          ),
          // Settings (gear) — opens the bottom-sheet with mic/speaker pickers,
          // column count, and hide-offline toggle.
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => _showSettingsSheet(context, ic),
          ),
          // Info — opens the bundled user manual.
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'User manual',
            onPressed: () => Navigator.pushNamed(context, '/manual'),
          ),
          if (auth.isAdmin)
            IconButton(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              icon: const Icon(Icons.admin_panel_settings),
              tooltip: 'Admin',
              onPressed: () => Navigator.pushNamed(context, '/admin'),
            ),
          IconButton(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
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
                        await context.read<AuthProvider>().logout();
                        if (context.mounted) Navigator.pushReplacementNamed(context, '/');
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
            // (The old "Receiving audio from X" banner has been removed —
            // the active speaker is now signalled by the bright-green top
            // half of their PTT button.)

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

            // Users section (non-bridge) — "hide offline" removes non-online
            // entries; they reappear automatically when the user connects.
            ..._buildTargetSection(
              ic,
              icon: Icons.person,
              title: 'Users',
              items: ic.userTargets
                  .where((u) => u['role'] != 'bridge')
                  .where((u) => !ic.hideOfflineUsers ||
                      ic.onlineUserIds.contains(u['id']))
                  .toList(),
              emptyText: 'No user permissions',
              builder: (u) {
                final id = u['id'] as int;
                return _buildTargetButton(ic, 'user', id,
                    u['display_name'] ?? 'User $id', ic.onlineUserIds.contains(id),
                    color: _parseColor(u['color'] as String?),
                    isAdmin: auth.isAdmin);
              },
            ),

            // Bridges section — same hide-offline rule as Users.
            ...(() {
              final bridges = ic.userTargets
                  .where((u) => u['role'] == 'bridge')
                  .where((u) => !ic.hideOfflineUsers ||
                      ic.onlineUserIds.contains(u['id']))
                  .toList();
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
                      color: _parseColor(u['color'] as String?),
                      isAdmin: auth.isAdmin,
                      isBridge: true);
                },
              );
            })(),

            // Groups section — hide groups whose members are all offline
            // (fall back to showing the group if member_ids is empty).
            ..._buildTargetSection(
              ic,
              icon: Icons.group,
              title: 'Groups',
              items: ic.groupTargets
                  .where((g) => !ic.hideOfflineUsers ||
                      ic.groupHasOnlineMember(g['id'] as int))
                  .toList(),
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

  Widget _buildButtonGrid(List<Widget> buttons, int columns) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 10.0;
        final itemWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: buttons
              .map((b) => SizedBox(width: itemWidth, child: b))
              .toList(),
        );
      },
    );
  }

  /// Bottom-sheet with mic/speaker pickers, column count, and the hide-offline
  /// toggle. Lives on the screen instead of the provider because it's pure
  /// UI state management over values already exposed by [IntercomProvider].
  void _showSettingsSheet(BuildContext context, IntercomProvider ic) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return AnimatedPadding(
          duration: const Duration(milliseconds: 150),
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: StatefulBuilder(
            builder: (ctx, setSt) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: AppColors.border,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Row(
                      children: const [
                        Icon(Icons.settings, color: AppColors.pressedBlueLight),
                        SizedBox(width: 8),
                        Text('Settings',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 18),

                    // ---- Mic picker ----
                    if (ic.audioInputs.isNotEmpty) ...[
                      const Text('Microphone',
                          style: TextStyle(
                              color: AppColors.textSecondary, fontSize: 12)),
                      const SizedBox(height: 6),
                      _settingsDropdown<String>(
                        icon: Icons.mic,
                        value: ic.audioInputs.any((d) =>
                                d['deviceId'] == ic.selectedInputId)
                            ? ic.selectedInputId
                            : ic.audioInputs.first['deviceId'],
                        items: ic.audioInputs
                            .map((d) => DropdownMenuItem<String>(
                                  value: d['deviceId'],
                                  child: Text(d['label'] ?? '?',
                                      overflow: TextOverflow.ellipsis),
                                ))
                            .toList(),
                        onChanged: (v) {
                          if (v != null) {
                            ic.switchInputDevice(v);
                            setSt(() {});
                          }
                        },
                      ),
                      const SizedBox(height: 12),
                    ],

                    // ---- Speaker picker ----
                    if (ic.audioOutputs.isNotEmpty) ...[
                      const Text('Speaker',
                          style: TextStyle(
                              color: AppColors.textSecondary, fontSize: 12)),
                      const SizedBox(height: 6),
                      _settingsDropdown<String>(
                        icon: Icons.volume_up,
                        value: ic.audioOutputs.any((d) =>
                                d['deviceId'] == ic.selectedOutputId)
                            ? ic.selectedOutputId
                            : ic.audioOutputs.first['deviceId'],
                        items: ic.audioOutputs
                            .map((d) => DropdownMenuItem<String>(
                                  value: d['deviceId'],
                                  child: Text(d['label'] ?? '?',
                                      overflow: TextOverflow.ellipsis),
                                ))
                            .toList(),
                        onChanged: (v) {
                          if (v != null) {
                            ic.switchOutputDevice(v);
                            setSt(() {});
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                    ],

                    const Divider(color: AppColors.border, height: 1),
                    const SizedBox(height: 14),

                    // ---- Columns slider ----
                    Row(
                      children: [
                        const Icon(Icons.grid_view,
                            size: 18, color: AppColors.textSecondary),
                        const SizedBox(width: 8),
                        const Text('Columns',
                            style: TextStyle(fontSize: 14)),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceLight,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            ic.gridColumns.toString(),
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: AppColors.pressedBlueLight),
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: ic.gridColumns.toDouble(),
                      min: 2,
                      max: 4,
                      divisions: 2,
                      label: ic.gridColumns.toString(),
                      onChanged: (v) {
                        ic.setGridColumns(v.round());
                        setSt(() {});
                      },
                    ),
                    const SizedBox(height: 6),

                    // ---- Hide offline switch ----
                    Row(
                      children: [
                        const Icon(Icons.visibility_off,
                            size: 18, color: AppColors.textSecondary),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Hide offline users',
                            style: TextStyle(fontSize: 14),
                          ),
                        ),
                        Switch(
                          value: ic.hideOfflineUsers,
                          onChanged: (v) {
                            ic.setHideOfflineUsers(v);
                            setSt(() {});
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Offline users reappear automatically when they reconnect.',
                      style:
                          TextStyle(fontSize: 11, color: AppColors.textSecondary),
                    ),

                    const SizedBox(height: 14),
                    const Divider(color: AppColors.border, height: 1),
                    const SizedBox(height: 14),

                    // ---- Sidetone slider ----
                    // Plays your own microphone back into the selected speaker
                    // so you can hear yourself while transmitting. Useful when
                    // wearing closed headsets.
                    Row(
                      children: [
                        const Icon(Icons.hearing,
                            size: 18, color: AppColors.textSecondary),
                        const SizedBox(width: 8),
                        const Text('Sidetone',
                            style: TextStyle(fontSize: 14)),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceLight,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            ic.sidetoneLevel <= 0
                                ? 'off'
                                : '${(ic.sidetoneLevel * 100).round()}%',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: AppColors.pressedBlueLight),
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: ic.sidetoneLevel,
                      min: 0.0,
                      max: 1.0,
                      divisions: 20,
                      onChanged: (v) {
                        ic.setSidetoneLevel(v);
                        setSt(() {});
                      },
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Hear yourself while you talk. Set to 0 to disable.',
                      style:
                          TextStyle(fontSize: 11, color: AppColors.textSecondary),
                    ),

                    const SizedBox(height: 14),
                    const Divider(color: AppColors.border, height: 1),
                    const SizedBox(height: 14),

                    // ---- Call ducking selector ----
                    // How much to attenuate incoming intercom audio while
                    // there's an active GSM or VoIP call. Values are in dB.
                    Row(
                      children: const [
                        Icon(Icons.call_end,
                            size: 18, color: AppColors.textSecondary),
                        SizedBox(width: 8),
                        Text('Call ducking',
                            style: TextStyle(fontSize: 14)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final entry in const [
                          [0, '0 dB'],
                          [-3, '-3 dB'],
                          [-6, '-6 dB'],
                          [-12, '-12 dB'],
                          [-60, 'Mute'],
                        ])
                          ChoiceChip(
                            label: Text(entry[1] as String),
                            selected: ic.callDuckDb == entry[0] as int,
                            onSelected: (_) {
                              ic.setCallDuckDb(entry[0] as int);
                              setSt(() {});
                            },
                            selectedColor: AppColors.pressedBlue,
                            backgroundColor: AppColors.surfaceLight,
                            labelStyle: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: ic.callDuckDb == entry[0]
                                  ? Colors.white
                                  : AppColors.textSecondary,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Intercom audio is attenuated by this amount while a '
                      'phone/WhatsApp/FaceTime call is active.',
                      style:
                          TextStyle(fontSize: 11, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _settingsDropdown<T>({
    required IconData icon,
    required T? value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.connectedBlueGreyLight),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<T>(
                value: value,
                isExpanded: true,
                isDense: true,
                items: items,
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
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
        _buildButtonGrid(
          items.map(builder).toList(),
          (ic as IntercomProvider).gridColumns,
        ),
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
