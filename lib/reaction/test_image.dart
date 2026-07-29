import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// A synthetic bitmap for stage-3 of the build order: "wire up a single
/// structured call against a static test image to prove the pipeline end
/// to end before touching triggers." Drawn in-process instead of sourcing a
/// real photo asset — no licensing to track, no extra binary in the repo,
/// and a simple face-like shape is enough to exercise vision input.
Future<Uint8List> buildStaticTestImage({int size = 256}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(
    recorder,
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
  );

  canvas.drawRect(
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    Paint()..color = const Color(0xFF10151A),
  );

  final center = Offset(size / 2, size / 2);
  canvas.drawCircle(
    center,
    size * 0.32,
    Paint()..color = const Color(0xFFF2C08C),
  );

  final eyePaint = Paint()..color = const Color(0xFF1B1F24);
  canvas.drawCircle(Offset(size * 0.40, size * 0.45), size * 0.035, eyePaint);
  canvas.drawCircle(Offset(size * 0.60, size * 0.45), size * 0.035, eyePaint);

  final smilePaint = Paint()
    ..color = const Color(0xFF1B1F24)
    ..style = PaintingStyle.stroke
    ..strokeWidth = size * 0.02
    ..strokeCap = StrokeCap.round;
  canvas.drawArc(
    Rect.fromCircle(center: Offset(size / 2, size * 0.55), radius: size * 0.12),
    0.2,
    2.7,
    false,
    smilePaint,
  );

  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  return byteData!.buffer.asUint8List();
}
