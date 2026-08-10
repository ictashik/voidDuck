import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The fixed CRT texture layer over the whole stage (example.html body
/// pseudo-elements, ported to a single CustomPaint):
///
/// - horizontal scanlines, 3px cycle at low alpha
/// - edge vignette
/// - sparse static phosphor noise
///
/// Everything is precomputed once into a [ui.Picture] and replayed per
/// frame, so the overlay costs a single cheap draw even on the old phone.
/// Pointer-transparent and sits above the stage content but below the debug
/// overlay, which is a sibling above this widget in the app's Stack.
class CrtOverlay extends StatelessWidget {
  const CrtOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _CrtPainter(),
        ),
      ),
    );
  }
}

class _CrtPainter extends CustomPainter {
  static final Random _noise = Random(0x0D0CE);

  Size? _cachedSize;
  ui.Picture? _picture;

  void _buildPicture(Size size) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // Scanlines: 1px dark line every 3px (example: transparent 0 2px,
    // rgba(0,0,0,0.18) 2px 3px, multiplied by the 0.55 overlay opacity).
    final linePaint = Paint()..color = const Color(0x1A000000);
    for (var y = 0.0; y < size.height; y += 3) {
      canvas.drawRect(Rect.fromLTWH(0, y + 2, size.width, 1), linePaint);
    }

    // Vignette: transparent center -> darkened edges (example radial
    // gradient at 55%).
    final vignetteRect = Offset.zero & size;
    final vignettePaint = Paint()
      ..shader = RadialGradient(
        colors: const [Color(0x00000000), Color(0x66000000)],
        stops: const [0.55, 1.0],
      ).createShader(vignetteRect);
    canvas.drawRect(vignetteRect, vignettePaint);

    // Phosphor noise: sparse static 1px dots, ~4% alpha (SKILL: opacity
    // <= 0.06). Seeded so it's deterministic per screen size.
    final noisePaint = Paint()..color = const Color(0x0AFFFFFF);
    final dotCount = (size.width * size.height / 600).round().clamp(400, 4000);
    for (var i = 0; i < dotCount; i++) {
      final x = _noise.nextDouble() * size.width;
      final y = _noise.nextDouble() * size.height;
      canvas.drawRect(Rect.fromLTWH(x, y, 1, 1), noisePaint);
    }

    _picture = recorder.endRecording();
    _cachedSize = size;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (_picture == null || _cachedSize != size) {
      _buildPicture(size);
    }
    canvas.drawPicture(_picture!);
  }

  @override
  bool shouldRepaint(covariant _CrtPainter oldDelegate) => false;
}
