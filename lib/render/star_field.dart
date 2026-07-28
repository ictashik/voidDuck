import 'dart:math';

import 'package:flutter/material.dart';

/// One pre-computed star: a fixed fractional position plus a fixed
/// size/brightness so the field doesn't visually shuffle every rebuild —
/// only the *count* of visible stars grows over time.
class _Star {
  const _Star(this.dx, this.dy, this.radius, this.opacity);
  final double dx; // 0..1, fraction of canvas width
  final double dy; // 0..1, fraction of canvas height
  final double radius;
  final double opacity;
}

/// Generated once with a fixed seed at first use — stable across the whole
/// app lifetime and across restarts (position doesn't depend on
/// totalSeconds, only how many of the list are currently revealed).
final List<_Star> _allStars = _generateStars(500);

List<_Star> _generateStars(int count) {
  final rnd = Random(1337);
  return List.generate(count, (_) {
    return _Star(
      rnd.nextDouble(),
      rnd.nextDouble(),
      0.6 + rnd.nextDouble() * 1.1,
      0.05 + rnd.nextDouble() * 0.12,
    );
  });
}

/// Ambient encoding of cumulative all-time presence (totalSeconds): dim
/// pixel dots seeded into the black background, roughly one per
/// star_minutes_per_star of accumulated time, capped at star_max_count.
/// Painted well behind and dimmer than the eyes so it never competes as the
/// visual focal point (spec requirement) — callers are expected to place
/// this first/lowest in the stack.
class StarFieldPainter extends CustomPainter {
  StarFieldPainter({required this.starCount});

  final int starCount;

  @override
  void paint(Canvas canvas, Size size) {
    final count = starCount.clamp(0, _allStars.length);
    final paint = Paint();
    for (var i = 0; i < count; i++) {
      final star = _allStars[i];
      paint.color = Colors.white.withValues(alpha: star.opacity);
      canvas.drawCircle(
        Offset(star.dx * size.width, star.dy * size.height),
        star.radius,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant StarFieldPainter old) =>
      old.starCount != starCount;
}
