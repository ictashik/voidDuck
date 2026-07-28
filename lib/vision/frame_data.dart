import 'dart:typed_data';

import 'package:camera/camera.dart';

/// Single-plane NV21 frame handed to ML Kit. We deliberately copy the bytes
/// into a fresh Uint8List here so the original frame buffer can be released
/// the moment fromBytes returns — nothing live is held past one frame
/// (privacy non-negotiable #2: data ephemerality).
class FrameData {
  final Uint8List bytes; // NV21
  final int width;
  final int height;
  final int rotationDegrees; // tuned via the panel — front-cam rotation varies
  final DateTime capturedAt;

  FrameData({
    required this.bytes,
    required this.width,
    required this.height,
    required this.rotationDegrees,
    required this.capturedAt,
  });

  /// Build a [FrameData] from a [CameraImage] that was requested in
  /// `ImageFormatGroup.nv21`. The Android plugin delivers a single plane
  /// with the full NV21 buffer; we copy it and let the original go.
  factory FrameData.from(CameraImage image, int rotationDegrees) {
    final bytes = Uint8List.fromList(image.planes.first.bytes);
    return FrameData(
      bytes: bytes,
      width: image.width,
      height: image.height,
      rotationDegrees: rotationDegrees,
      capturedAt: DateTime.now(),
    );
  }
}