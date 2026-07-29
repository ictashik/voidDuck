import 'package:flutter/material.dart';

/// Small pixel-block progress bar counting down to the next ambient tick —
/// a "tqdm"-style readout, blocky rather than a smooth bar to match the
/// rest of the stage's pixel-font aesthetic. Sits just left of the
/// Reaction Engine status dot.
class AmbientCountdown extends StatelessWidget {
  /// 0 at the start of the current wait span, 1 right as it's about to fire.
  final double progress;

  /// True while the span being counted down is a conversation-window hold
  /// rather than a normal ambient wait — rendered in the banner's coral
  /// accent instead of dull white so it reads as a distinct state, not just
  /// a slower tick.
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
    final onColor = conversationMode
        ? const Color(0xFFCF5867)
        : const Color(0x99FFFFFF);
    final offColor = conversationMode
        ? const Color(0x40CF5867)
        : const Color(0x2AFFFFFF);
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
