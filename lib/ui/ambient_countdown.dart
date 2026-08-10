import 'package:flutter/material.dart';

import 'stage_theme.dart';

/// Small block progress bar counting down to the next ambient tick — a
/// "tqdm"-style readout, blocky rather than a smooth bar, sitting in the
/// stage's bottom chrome strip just left of the status dot.
///
/// v0.14 restyle: phosphor-white blocks at rest; the whole bar flips to
/// hazard red while the span being counted is a conversation-window hold
/// (red = the alert state of "ambient is on hold"), replacing the old coral.
class AmbientCountdown extends StatelessWidget {
  /// 0 at the start of the current wait span, 1 right as it's about to fire.
  final double progress;

  /// True while the span being counted down is a conversation-window hold
  /// rather than a normal ambient wait.
  final bool conversationMode;

  static const _segments = 10;
  static const _segmentSize = 6.0;
  static const _segmentGap = 2.0;

  const AmbientCountdown({
    super.key,
    required this.progress,
    this.conversationMode = false,
  });

  @override
  Widget build(BuildContext context) {
    final filled = (progress.clamp(0.0, 1.0) * _segments).floor();
    final onColor =
        conversationMode ? StageColors.hazard : StageColors.phosSoft;
    final offColor = conversationMode
        ? StageColors.hazard.withValues(alpha: 0.25)
        : StageColors.phosMute.withValues(alpha: 0.35);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(_segments, (i) {
        final on = i < filled;
        return Container(
          width: _segmentSize,
          height: _segmentSize,
          margin: const EdgeInsets.only(right: _segmentGap),
          color: on ? onColor : offColor,
        );
      }),
    );
  }
}
