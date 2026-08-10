import 'package:flutter/material.dart';

import 'stage_theme.dart';

/// Where a Reaction Engine call currently is, for the bottom-chrome status
/// square. Distinct from [ReactionCallLog] (the debug overlay's history) —
/// this is a live, at-a-glance "is it doing something right now" signal
/// visible without opening the overlay at all.
enum ReactionPhase { idle, capturing, processing, success }

/// Small square in the bottom chrome strip: dark at rest, pulses phosphor
/// white while a frame is being captured or the model is thinking, flashes
/// terminal green when a response lands, then fades back to idle.
///
/// v0.14 restyle: hard 90° square, no glow (SKILL bans shadows/glow), and
/// green appears on exactly this one element of the whole stage. Capturing
/// and processing share the white pulse — the phase split is visible in the
/// debug overlay; on stage they're both just "busy".
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

  @override
  Widget build(BuildContext context) {
    final busy =
        widget.phase == ReactionPhase.capturing ||
        widget.phase == ReactionPhase.processing;
    final color = widget.phase == ReactionPhase.success
        ? StageColors.green
        : StageColors.phos;
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final pulseOpacity = busy ? 0.35 + 0.65 * _pulse.value : 1.0;
        return AnimatedOpacity(
          opacity: widget.phase == ReactionPhase.idle ? 0.0 : pulseOpacity,
          duration: const Duration(milliseconds: 200),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.zero,
              color: color,
            ),
          ),
        );
      },
    );
  }
}
