import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Top strip on every user button. Shows the bell + RING affordance for
/// admin/superuser callers (interactive mode), or stays empty for regular
/// users. In both modes the background flips to bright green when the
/// matching peer is currently transmitting audio to us, giving the user a
/// chance to identify whose voice they hear.
class _TopStrip extends StatefulWidget {
  final bool online;
  final bool receiving;
  final bool interactive;
  final VoidCallback? onRing;
  final Color sectionColor;

  const _TopStrip({
    required this.online,
    required this.receiving,
    required this.interactive,
    required this.onRing,
    required this.sectionColor,
  });

  @override
  State<_TopStrip> createState() => _TopStripState();
}

class _TopStripState extends State<_TopStrip> {
  bool _pressed = false;

  bool get _enabled =>
      widget.interactive && widget.online && widget.onRing != null;

  void _setPressed(bool v) {
    if (!_enabled) return;
    if (_pressed == v) return;
    setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    // Bright lime → saturated green when audio is incoming. Otherwise the
    // strip mirrors the press / idle / disabled colours of the rest of the
    // button.
    const greenA = Color(0xFF1FE36A);
    const greenB = Color(0xFF13A24A);
    final Color bg;
    if (widget.receiving) {
      bg = greenA;
    } else if (!_enabled) {
      bg = widget.sectionColor.withValues(alpha: 0.95);
    } else if (_pressed) {
      bg = AppColors.pressedBlue;
    } else {
      bg = AppColors.pressedBlue.withValues(alpha: 0.28);
    }

    final fg = widget.receiving
        ? Colors.white
        : !_enabled
            ? AppColors.textSecondary.withValues(alpha: 0.6)
            : _pressed
                ? Colors.white
                : AppColors.textPrimary;

    final inner = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        gradient: widget.receiving
            ? const LinearGradient(
                colors: [greenA, greenB],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              )
            : null,
        color: widget.receiving ? null : bg,
      ),
      child: widget.interactive
          ? Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.notifications_active, size: 13, color: fg),
                const SizedBox(width: 6),
                Text(
                  'RING',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: fg,
                  ),
                ),
              ],
            )
          // Passive mode for regular users: keep the strip height so every
          // button has the same shape, but no icon and no text.
          : const SizedBox(height: 13),
    );

    if (!_enabled) return inner;
    return GestureDetector(
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onTap: widget.onRing,
      child: inner,
    );
  }
}

class PttButton extends StatelessWidget {
  final String label;
  final bool online;
  // True while the local user is currently transmitting (PTT) toward this
  // target. Paints the entire central PTT zone (name + helper line) in red.
  final bool active;
  // True while this peer is currently transmitting audio TO us. Paints the
  // top strip green so the listener can spot whose voice they hear, even
  // when several peers talk at once.
  final bool receiving;
  final bool enabled;
  final bool isLatch;
  final Color? userColor;
  final double volume;
  final ValueChanged<double>? onVolumeChanged;
  final VoidCallback onPttStart;
  final VoidCallback onPttStop;
  final VoidCallback onTap; // for latch mode
  final VoidCallback onToggleLatch;
  // Show the top strip at all. False on bridges and groups (they never have
  // their own RX/RING indication).
  final bool showTopStrip;
  // Top strip is interactive (bell + RING + tap-to-ring). Only set on admin
  // / superuser sessions; regular users see the passive strip.
  final bool topStripInteractive;
  final VoidCallback? onRing;

  const PttButton({
    super.key,
    required this.label,
    required this.online,
    required this.active,
    this.receiving = false,
    required this.enabled,
    required this.isLatch,
    this.userColor,
    this.volume = 1.0,
    this.onVolumeChanged,
    required this.onPttStart,
    required this.onPttStop,
    required this.onTap,
    required this.onToggleLatch,
    this.showTopStrip = false,
    this.topStripInteractive = false,
    this.onRing,
  });

  @override
  Widget build(BuildContext context) {
    // Use userColor for online border if available. The outer container keeps
    // its "online/offline" colours; the green RX flash lives on the top
    // strip and the red TX paints the central PTT zone.
    final onlineBorder = userColor ?? AppColors.connectedBlueGrey;

    final topColor = online
        ? AppColors.connectedBlueGreyLight
        : AppColors.disconnectedGreyLight;
    final bottomColor = online
        ? AppColors.connectedBlueGreyDark
        : AppColors.disconnectedGreyDark;
    final borderColor = online ? onlineBorder : AppColors.disconnectedGreyDark;
    final borderWidth = online ? 2.5 : 1.2;
    final sectionColor = online
        ? AppColors.connectedBlueGreyDark
        : AppColors.disconnectedGreyDark;
    final labelColor =
        online ? AppColors.textPrimary : const Color(0xFF6B737D);
    final statusColor = active
        ? Colors.white
        : online
            ? onlineBorder
            : const Color(0xFF4A5058);
    final helperColor = active
        ? Colors.white.withValues(alpha: 0.92)
        : online
            ? AppColors.textSecondary
            : const Color(0xFF555D66);

    // Whole central zone goes red while transmitting; otherwise a soft
    // top→bottom gradient on the regular blue-grey palette.
    final zone1Top = active ? AppColors.talkRed : topColor;
    final zone1Bottom = active ? AppColors.talkRedDark : bottomColor;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      transform: Matrix4.translationValues(0, active ? 4 : 0, 0),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: borderColor, width: borderWidth),
          gradient: LinearGradient(
            colors: [topColor, bottomColor],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: active ? 0.25 : 0.4),
              blurRadius: active ? 6 : 14,
              offset: Offset(0, active ? 2 : 7),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ===== Zone 0: Top strip — RING (interactive) or empty
            // (passive). Background flips to green while we're receiving
            // audio from this peer.
            if (showTopStrip) ...[
              _TopStrip(
                online: online,
                receiving: receiving,
                interactive: topStripInteractive,
                onRing: onRing,
                sectionColor: sectionColor,
              ),
              Container(height: 1, color: Colors.black.withValues(alpha: 0.2)),
            ],
            // ===== Zone 1: PTT — entire zone turns red while talking.
            GestureDetector(
              onTapDown: !isLatch && enabled ? (_) => onPttStart() : null,
              onTapUp: !isLatch && enabled ? (_) => onPttStop() : null,
              onTapCancel: !isLatch && enabled ? onPttStop : null,
              onTap: isLatch && enabled ? onTap : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: enabled
                        ? [zone1Top, zone1Bottom]
                        : [
                            zone1Top.withValues(alpha: 0.7),
                            zone1Bottom.withValues(alpha: 0.7),
                          ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Column(
                  children: [
                    Container(
                      height: 3,
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: statusColor,
                            boxShadow: online || active
                                ? [BoxShadow(color: statusColor.withValues(alpha: 0.5), blurRadius: 6)]
                                : null,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            label,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: active ? Colors.white : labelColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: active
                          ? Row(
                              key: const ValueKey('talking'),
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.mic, size: 14, color: Colors.white.withValues(alpha: 0.95)),
                                const SizedBox(width: 4),
                                Text(
                                  'TALKING',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1,
                                    color: Colors.white.withValues(alpha: 0.95),
                                  ),
                                ),
                              ],
                            )
                          : Text(
                              key: const ValueKey('idle'),
                              isLatch ? 'Tap to talk' : 'Hold to talk',
                              style: TextStyle(fontSize: 9, color: helperColor),
                            ),
                    ),
                  ],
                ),
              ),
            ),
            // ===== Divider =====
            Container(
              height: 1,
              color: Colors.black.withValues(alpha: 0.16),
            ),
            // ===== Zone 2: Volume =====
            if (onVolumeChanged != null) ...[
              Container(
                color: sectionColor.withValues(alpha: 0.9),
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 4,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                    activeTrackColor: !online
                        ? AppColors.disconnectedGreyLight
                        : volume <= 0
                            ? Colors.red.shade300
                            : (active ? AppColors.pressedBlueLight : AppColors.connectedBlueGreyLight),
                    inactiveTrackColor: Colors.black.withValues(alpha: 0.18),
                    thumbColor: !online
                        ? AppColors.disconnectedGreyLight
                        : volume <= 0
                            ? Colors.red.shade400
                            : (active ? AppColors.pressedBlueLight : AppColors.connectedBlueGreyLight),
                  ),
                  child: Slider(
                    value: volume,
                    min: 0.0,
                    max: 1.0,
                    onChanged: online ? onVolumeChanged : null,
                  ),
                ),
              ),
            ],
            // ===== Zone 3: Latch toggle =====
            Container(
              height: 1,
              color: Colors.black.withValues(alpha: 0.18),
            ),
            GestureDetector(
              onTap: onToggleLatch,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 6),
                color: isLatch
                    ? AppColors.pressedBlue.withValues(alpha: 0.2)
                    : sectionColor.withValues(alpha: 0.95),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      isLatch ? Icons.lock_outline : Icons.touch_app,
                      size: 14,
                      color: isLatch ? AppColors.textPrimary : AppColors.textSecondary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      isLatch ? 'LATCH' : 'MOMENT.',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                        color: isLatch ? AppColors.textPrimary : AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
