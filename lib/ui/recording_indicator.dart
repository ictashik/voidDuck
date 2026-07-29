import 'package:flutter/material.dart';

/// Full-stage "mic is live" view for a voice-recording window (spec Section
/// 4.4) — a pulsing red dot plus elapsed/cap seconds, deliberately large and
/// centered rather than a corner badge, so it's obvious to anyone nearby
/// that the mic is live right now, not continuously.
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
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) => Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Color.lerp(
                  const Color(0xFF7A1F2B),
                  const Color(0xFFFF3B30),
                  _pulse.value,
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFFF3B30)
                        .withValues(alpha: 0.5 * _pulse.value),
                    blurRadius: 16,
                    spreadRadius: 4,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'LISTENING',
            style: TextStyle(
              fontFamily: 'Silkscreen',
              fontWeight: FontWeight.w700,
              fontSize: 22,
              letterSpacing: 2,
              color: Color(0xFFFFFFFF),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${widget.elapsed.inSeconds}s / ${widget.cap.inSeconds}s',
            style: const TextStyle(
              fontFamily: 'Silkscreen',
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: Color(0x99FFFFFF),
            ),
          ),
        ],
      ),
    );
  }
}
