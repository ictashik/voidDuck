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

  /// The plane's actual row stride, in bytes — NOT assumed to equal [width].
  /// camera_android_camerax has been observed padding rows wider than the
  /// image for memory alignment; feeding ML Kit a hardcoded `bytesPerRow:
  /// width` when the real stride is larger silently misaligns every row
  /// after the first, which is exactly the shape of bug that shows up native
  /// -side as a null/out-of-bounds crash rather than a Dart exception.
  final int bytesPerRow;

  FrameData({
    required this.bytes,
    required this.width,
    required this.height,
    required this.rotationDegrees,
    required this.bytesPerRow,
    required this.capturedAt,
  });

  /// Build a [FrameData] from a [CameraImage] that was requested in
  /// `ImageFormatGroup.nv21`. The Android plugin delivers a single plane
  /// with the full NV21 buffer; we copy it and let the original go.
  factory FrameData.from(CameraImage image, int rotationDegrees) {
    final plane = image.planes.first;
    final bytes = Uint8List.fromList(plane.bytes);
    return FrameData(
      bytes: bytes,
      width: image.width,
      height: image.height,
      rotationDegrees: rotationDegrees,
      bytesPerRow: plane.bytesPerRow,
      capturedAt: DateTime.now(),
    );
  }
}