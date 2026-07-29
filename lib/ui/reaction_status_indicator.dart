import 'package:flutter/material.dart';

/// Where a Reaction Engine call currently is, for the bottom-right status
/// dot. Distinct from [ReactionCallLog] (the debug overlay's history) — this
/// is a live, at-a-glance "is it doing something right now" signal visible
/// without opening the overlay at all.
enum ReactionPhase { idle, capturing, processing, success }

/// Small dot, bottom-right: dim/hidden at rest, pulses while a frame is
/// being captured or the model is thinking, flashes green when a response
/// lands, then fades back to idle. Answers "is a capturing, and processing"
/// without the human needing the debug overlay open.
class ReactionStatusIndicator extends StatefulWidget {
  final ReactionPhase phase;

  const ReactionStatusIndicator({super.key, required this.phase});

  @override
  State<ReactionStatusIndicator> createState() =>
      _ReactionStatusIndicatorState();
}

class _ReactionStatusIndicatorState extends State<ReactionStatusIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Color _colorFor(ReactionPhase phase) {
    switch (phase) {
      case ReactionPhase.idle:
        return const Color(0x00000000);
      case ReactionPhase.capturing:
        return const Color(0xFFEFEFEF);
      case ReactionPhase.processing:
        return const Color(0xFFE8A33D);
      case ReactionPhase.success:
        return const Color(0xFF4CD17A);
    }
  }

  bool get _pulsing =>
      widget.phase == ReactionPhase.capturing ||
      widget.phase == ReactionPhase.processing;

  @override
  Widget build(BuildContext context) {
    final color = _colorFor(widget.phase);
    return Positioned(
      right: 16,
      bottom: 16,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) {
          final pulseOpacity =
              _pulsing ? 0.4 + 0.6 * _pulse.value : 1.0;
          return AnimatedOpacity(
            opacity: widget.phase == ReactionPhase.idle ? 0.0 : pulseOpacity,
            duration: const Duration(milliseconds: 200),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
                boxShadow: widget.phase == ReactionPhase.idle
                    ? null
                    : [
                        BoxShadow(
                          color: color.withValues(alpha: 0.6),
                          blurRadius: 6,
                          spreadRadius: 1,
                        ),
                      ],
              ),
            ),
          );
        },
      ),
    );
  }
}
