import 'package:flutter/material.dart';

import 'stage_theme.dart';

/// Full-stage 3-2-1 countdown shown right after Open_Palm fires, before
/// recording actually starts (spec Section 4.4). Deliberately replaces both
/// zones rather than sitting in a corner — the point is that it's
/// unmistakable something is about to happen, not a subtle cue.
///
/// v0.14 restyle: hazard-red specimen digit on the black stage with a
/// terminal label, and each new count value lands with a quick 2-frame
/// flicker instead of a clean swap — it's the CRT warning readout of the
/// stage, not a generic UI number.
class VoiceCountdown extends StatefulWidget {
  final int value;

  const VoiceCountdown({super.key, required this.value});

  @override
  State<VoiceCountdown> createState() => _VoiceCountdownState();
}

class _VoiceCountdownState extends State<VoiceCountdown> {
  int _flickerFrames = 0;

  @override
  void didUpdateWidget(covariant VoiceCountdown old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      _flickerFrames = 2;
      // Stepped flicker on the digit: 2 frames at ~45ms each.
      Future.delayed(const Duration(milliseconds: 45), () {
        if (mounted && _flickerFrames > 0) {
          setState(() => _flickerFrames--);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final flickering = _flickerFrames > 0;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${widget.value}',
            style: TextStyle(
              fontFamily: StageText.mono,
              fontWeight: FontWeight.w700,
              fontSize: 140,
              height: 1,
              color: flickering
                  ? (DateTime.now().millisecond.isEven
                      ? StageColors.phos
                      : StageColors.hazard)
                  : StageColors.hazard,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'AUDIO LINK ARMING · ${widget.value}',
            style: const TextStyle(
              fontFamily: StageText.mono,
              fontWeight: FontWeight.w700,
              fontSize: 12,
              letterSpacing: 2,
              color: StageColors.phosSoft,
            ),
          ),
        ],
      ),
    );
  }
}
