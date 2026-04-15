import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class PttButton extends StatelessWidget {
  final String label;
  final bool online;
  final bool active;
  final bool enabled;
  final bool isLatch;
  final Color? userColor;
  final double volume;
  final ValueChanged<double>? onVolumeChanged;
  final VoidCallback onPttStart;
  final VoidCallback onPttStop;
  final VoidCallback onTap; // for latch mode
  final VoidCallback onToggleLatch;

  const PttButton({
    super.key,
    required this.label,
    required this.online,
    required this.active,
    required this.enabled,
    required this.isLatch,
    this.userColor,
    this.volume = 1.0,
    this.onVolumeChanged,
    required this.onPttStart,
    required this.onPttStop,
    required this.onTap,
    required this.onToggleLatch,
  });

  @override
  Widget build(BuildContext context) {
    // Use userColor for online border if available
    final onlineBorder = userColor ?? AppColors.connectedBlueGrey;

    final topColor = active
        ? AppColors.pressedBlueLight
        : online
            ? AppColors.connectedBlueGreyLight
            : AppColors.disconnectedGreyLight;
    final bottomColor = active
        ? AppColors.pressedBlueDark
        : online
            ? AppColors.connectedBlueGreyDark
            : AppColors.disconnectedGreyDark;
    final borderColor = active
        ? AppColors.pressedBlueLight
        : online
            ? onlineBorder
            : AppColors.disconnectedGreyDark;
    final borderWidth = active ? 2.5 : (online ? 2.5 : 1.2);
    final sectionColor = active
        ? AppColors.pressedBlueDark
        : online
            ? AppColors.connectedBlueGreyDark
            : AppColors.disconnectedGreyDark;
    final labelColor = active
        ? AppColors.textPrimary
        : online
            ? AppColors.textPrimary
            : const Color(0xFF6B737D);
    final statusColor = active
        ? Colors.white
        : online
            ? onlineBorder
            : const Color(0xFF4A5058);
    final helperColor = active
        ? AppColors.textPrimary.withValues(alpha: 0.88)
        : online
            ? AppColors.textSecondary
            : const Color(0xFF555D66);

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
            // ===== Zone 1: PTT =====
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
                        ? [topColor, bottomColor]
                        : [
                            topColor.withValues(alpha: 0.7),
                            bottomColor.withValues(alpha: 0.7),
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
                              color: labelColor,
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
                                Icon(Icons.mic, size: 14, color: Colors.white.withValues(alpha: 0.9)),
                                const SizedBox(width: 4),
                                Text(
                                  'TALKING',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1,
                                    color: AppColors.textPrimary.withValues(alpha: 0.9),
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
