import 'package:flutter/material.dart';

import 'stage_theme.dart';

/// Full-stage "mic is live" view for a voice-recording window (spec Section
/// 4.4) — a blinking hazard-red square plus elapsed/cap seconds, deliberately
/// large and centered rather than a corner badge, so it's obvious to anyone
/// nearby that the mic is live right now, not continuously.
///
/// v0.14 restyle: the old glowing circle is gone — a hard 90° red square
/// blinks in stepped on/off fashion (the CRT terminal's "REC" tell), with a
/// frame label under it. No glow, no curves (SKILL geometry rules).
class RecordingIndicator extends StatefulWidget {
  final Duration elapsed;
  final Duration cap;

  const RecordingIndicator({
    super.key,
    required this.elapsed,
    required this.cap,
  });

  @override
  State<RecordingIndicator> createState() => _RecordingIndicatorState();
}

class _RecordingIndicatorState extends State<RecordingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _blink;

  @override
  void initState() {
    super.initState();
    // Stepped blink: square toggles between red and dark red.
    _blink = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _blink,
            builder: (context, _) => Container(
              width: 30,
              height: 30,
              color: Color.lerp(
                StageColors.hazard,
                StageColors.hazard.withValues(alpha: 0.35),
                _blink.value,
              ),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'REC · LISTENING',
            style: TextStyle(
              fontFamily: StageText.mono,
              fontWeight: FontWeight.w700,
              fontSize: 22,
              letterSpacing: 2,
              color: StageColors.hazard,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${widget.elapsed.inSeconds}s / ${widget.cap.inSeconds}s',
            style: const TextStyle(
              fontFamily: StageText.mono,
              fontWeight: FontWeight.w700,
              fontSize: 14,
              letterSpacing: 1,
              color: StageColors.phosSoft,
            ),
          ),
        ],
      ),
    );
  }
}
