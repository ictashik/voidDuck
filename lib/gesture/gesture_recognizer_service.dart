import 'package:flutter/services.dart';

/// One recognized-gesture result from the native bridge.
class GestureResult {
  final String category; // e.g. "Open_Palm", "Closed_Fist", "None"
  final double score;

  const GestureResult({required this.category, required this.score});
}

/// Thin wrapper around [GestureBridge] (native, MainActivity.kt): camera
/// ownership stays entirely on the Dart side, this just hands an
/// already-encoded JPEG frame to MediaPipe's Gesture Recognizer and gets
/// back the top category, if any (spec Section 4.2.3, the Open_Palm
/// trigger — a separate on-device model from the Reaction Engine's).
class GestureRecognizerService {
  GestureRecognizerService._();
  static final GestureRecognizerService instance = GestureRecognizerService._();

  static const _channel = MethodChannel('voidduck/gesture');

  Future<GestureResult?> recognize(Uint8List jpegBytes) async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'recognize',
      {'jpeg': jpegBytes},
    );
    if (result == null) return null;
    return GestureResult(
      category: result['category'] as String,
      score: (result['score'] as num).toDouble(),
    );
  }
}
