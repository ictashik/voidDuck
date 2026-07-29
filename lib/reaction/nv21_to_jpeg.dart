import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Converts a raw NV21 camera frame (the format [CameraService] emits for
/// ML Kit) into JPEG bytes the Reaction Engine's vision input can read.
///
/// Runs once per trigger (`Waking` / ambient tick / gesture), never per
/// frame — the continuous ML Kit path never touches this, so the plain-Dart
/// pixel loop here is fine. Downsamples to [maxDimension] on the long edge
/// before converting: it keeps this fast, and the model doesn't need more
/// resolution than that to react to a scene.
Uint8List nv21ToJpeg({
  required Uint8List nv21,
  required int width,
  required int height,
  required int rotationDegrees,
  int maxDimension = 512,
}) {
  final longEdge = width > height ? width : height;
  final scale = longEdge > maxDimension ? (longEdge / maxDimension).ceil() : 1;
  final outWidth = (width / scale).floor();
  final outHeight = (height / scale).floor();
  final image = img.Image(width: outWidth, height: outHeight);

  final ySize = width * height;
  for (var oy = 0; oy < outHeight; oy++) {
    final y = oy * scale;
    for (var ox = 0; ox < outWidth; ox++) {
      final x = ox * scale;
      final yIndex = y * width + x;
      if (yIndex >= ySize) continue;

      final uvRow = y ~/ 2;
      final uvCol = x ~/ 2;
      final uvIndex = ySize + uvRow * width + uvCol * 2;
      if (uvIndex + 1 >= nv21.length) continue;

      final yValue = nv21[yIndex].toDouble();
      final v = nv21[uvIndex] - 128.0;
      final u = nv21[uvIndex + 1] - 128.0;

      final r = (yValue + 1.402 * v).clamp(0, 255).toInt();
      final g = (yValue - 0.344136 * u - 0.714136 * v).clamp(0, 255).toInt();
      final b = (yValue + 1.772 * u).clamp(0, 255).toInt();

      image.setPixelRgb(ox, oy, r, g, b);
    }
  }

  final upright = rotationDegrees % 360 == 0
      ? image
      : img.copyRotate(image, angle: rotationDegrees);

  return Uint8List.fromList(img.encodeJpg(upright, quality: 85));
}
