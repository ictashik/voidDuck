import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

import '../debug/debug_bus.dart';
import '../tuning/tuning.dart';
import 'frame_data.dart';

/// Owns the front camera and its image stream. The preview is never rendered
/// (non-negotiable #3: the feed runs invisibly). Frames are emitted to a
/// broadcast stream that the [FaceTracker] consumes.
///
/// Throttling is achieved by dropping frames whose timestamp falls inside the
/// current min-interval window (derived from the live tuning fps target). The
/// stream still fires for every frame the HAL delivers, but downstream code
/// only sees frames that pass the gate — so ML Kit work scales with the
/// current PetState without us restarting the camera.
class CameraService {
  CameraController? _controller;
  bool _streaming = false;

  final _framesController = StreamController<FrameData>.broadcast();
  Stream<FrameData> get frames => _framesController.stream;

  CameraController? get controller => _controller;
  bool get isStreaming => _streaming;

  /// Current minimum gap between emitted frames, in microseconds.
  int _currentMinIntervalUs = 66666; // 15fps default
  int _lastEmittedUs = 0;

  Future<void> start() async {
    if (_streaming) return;
    final cameras = await availableCameras();
    final front = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    // Aim for a high native resolution so small faces in the back of the desk
    // stay detectable. The HAL may downsample; that's fine.
    const resolution = ResolutionPreset.high;
    // Ask for NV21 directly. On Android the camera_android plugin converts
    // YUV_420_888 → NV21 server-side and ships it as a single plane, which is
    // exactly the format ML Kit's [InputImage.fromBytes] wants. This sidesteps
    // any pixelStride/rowStride confusion on our side and is more reliable on
    // the unpredictable HAL of an old phone.
    _controller = CameraController(
      front,
      resolution,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );
    await _controller!.initialize();
    await _controller!.startImageStream(_onImage);
    _streaming = true;
    DebugBus.instance.put('CameraLens',
        '${front.lensDirection.name} "${front.name}" sensor@${front.sensorOrientation}° '
        '${_controller!.value.previewSize}');
    if (kDebugMode) {
      debugPrint('Camera started: ${front.name} '
          '${_controller!.value.previewSize}');
    }
  }

  /// Called by PetState machine (stage 4) when the target fps changes.
  /// [fps] comes straight from tuning.
  void setTargetFps(double fps) {
    if (fps <= 0) {
      _currentMinIntervalUs = 1 << 31; // effectively gate everything
      DebugBus.instance.put('TargetFps', '0');
      return;
    }
    _currentMinIntervalUs = (1000000 / fps).round();
    DebugBus.instance.put('TargetFps', fps.toStringAsFixed(0));
  }

  void _onImage(CameraImage image) {
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    if (nowUs - _lastEmittedUs < _currentMinIntervalUs) {
      return; // throttled
    }
    _lastEmittedUs = nowUs;
    try {
      final rotation =
          Tuning.get('camera_rotation').round().clamp(0, 270) ~/ 90 * 90;
      final frame = FrameData.from(image, rotation);
      _framesController.add(frame);
    } catch (e, st) {
      // Never let a throw in _onImage tear down the camera stream — it would
      // silently kill the pet. Log and move on.
      FlutterError.reportError(FlutterErrorDetails(
        exception: e,
        stack: st,
        context: DiagnosticsNode.message('CameraService._onImage'),
      ));
      DebugBus.instance.put('LastError', 'CameraService: $e');
    }
  }

  Future<void> stop() async {
    if (!_streaming) return;
    _streaming = false;
    final c = _controller;
    if (c != null) {
      try {
        await c.stopImageStream();
        await c.dispose();
      } catch (_) {}
    }
    _controller = null;
  }

  void dispose() {
    stop();
    _framesController.close();
  }
}