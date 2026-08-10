import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import '../debug/debug_bus.dart';
import '../tuning/tuning.dart';
import 'camera_service.dart';
import 'frame_data.dart';

/// One frame's selected face, in normalized metrics ready for any downstream
/// layer (Rive, PetState, gaze smoothing) to consume. No Rive/brightness
/// knowledge — this is pure ML Kit output.
class FaceSnapshot {
  /// Raw, single-frame detection result — flickers frame to frame.
  final bool facePresent;

  /// Debounced presence (spec Section 4.4: N consecutive frames in the new
  /// condition before a state-relevant transition fires). Anything driving
  /// UI/state (icons, PetState later) should read this, not [facePresent].
  final bool stableFacePresent;
  final double lookX; // -1..1 (left of frame is +1 on front cam, mirror)
  final double lookY;
  final double faceSizeRatio; // 0..~1, bbox area / frame area
  final double headTiltDeg;
  final double smilingProb;
  final double leftEyeOpen;
  final double rightEyeOpen;
  final int width;
  final int height;

  /// How many faces ML Kit found on this frame. The selected face (largest
  /// bbox) drives everything else; a count of 2+ is what the visitor alert
  /// keys on — someone else entered the frame while the owner is present.
  final int faceCount;

  // Raw bbox center in ML Kit image coords (post-rotation applied by ML Kit).
  final double rawCenterX;
  final double rawCenterY;
  final double rawBoxW;
  final double rawBoxH;

  const FaceSnapshot({
    required this.facePresent,
    this.stableFacePresent = false,
    required this.lookX,
    required this.lookY,
    required this.faceSizeRatio,
    required this.headTiltDeg,
    required this.smilingProb,
    required this.leftEyeOpen,
    required this.rightEyeOpen,
    required this.width,
    required this.height,
    required this.rawCenterX,
    required this.rawCenterY,
    required this.rawBoxW,
    required this.rawBoxH,
    this.faceCount = 0,
  });

  static FaceSnapshot empty(int width, int height) => FaceSnapshot(
        facePresent: false,
        lookX: 0,
        lookY: 0,
        faceSizeRatio: 0,
        headTiltDeg: 0,
        smilingProb: 0,
        leftEyeOpen: 1,
        rightEyeOpen: 1,
        width: width,
        height: height,
        rawCenterX: 0,
        rawCenterY: 0,
        rawBoxW: 0,
        rawBoxH: 0,
      );

  FaceSnapshot withStable(bool stable) => FaceSnapshot(
        facePresent: facePresent,
        stableFacePresent: stable,
        lookX: lookX,
        lookY: lookY,
        faceSizeRatio: faceSizeRatio,
        headTiltDeg: headTiltDeg,
        smilingProb: smilingProb,
        leftEyeOpen: leftEyeOpen,
        rightEyeOpen: rightEyeOpen,
        width: width,
        height: height,
        rawCenterX: rawCenterX,
        rawCenterY: rawCenterY,
        rawBoxW: rawBoxW,
        rawBoxH: rawBoxH,
        faceCount: faceCount,
      );
}

/// Runs the offline [FaceDetector] on every frame the [CameraService] emits,
/// selects the largest bounding box (spec Section 4.3), and publishes a
/// [FaceSnapshot] + raw overlay values.
class FaceTracker {
  FaceTracker(this._camera) {
    _detector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: true, // smiling + eye-open probs
        enableLandmarks: false,
        enableContours: false,
        enableTracking: false,
        performanceMode: FaceDetectorMode.fast,
        minFaceSize: 0.10,
      ),
    );
  }

  final CameraService _camera;
  late final FaceDetector _detector;
  StreamSubscription<FrameData>? _sub;

  final _snapshotController = StreamController<FaceSnapshot>.broadcast();
  Stream<FaceSnapshot> get snapshots => _snapshotController.stream;

  int _framesProcessed = 0;
  DateTime _firstFrameAt = DateTime.fromMillisecondsSinceEpoch(0);

  // Debounce state (spec Section 4.4): N consecutive frames in the new
  // condition before the stable presence flag flips.
  bool _stablePresent = false;
  int _presentStreak = 0;
  int _absentStreak = 0;

  void start() {
    _sub = _camera.frames.listen(_process);
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    await _detector.close();
  }

  Future<void> _process(FrameData frame) async {
    // Visibility for the stride-mismatch theory: if bytesPerRow ever
    // diverges from width, that's the padding this fix accounts for: if it
    // never diverges on this device, the crash has a different cause.
    DebugBus.instance.put(
      'FrameStride',
      '${frame.width}w bytes/row=${frame.bytesPerRow} '
          '(${frame.bytesPerRow == frame.width ? "match" : "PADDED"})',
    );
    final input = InputImage.fromBytes(
      bytes: frame.bytes,
      metadata: InputImageMetadata(
        size: Size(frame.width.toDouble(), frame.height.toDouble()),
        rotation: InputImageRotationValue.fromRawValue(
                frame.rotationDegrees ~/ 90 * 90) ??
            InputImageRotation.rotation0deg,
        format: InputImageFormat.nv21,
        bytesPerRow: frame.bytesPerRow,
      ),
    );
    try {
      final faces = await _detector.processImage(input);
      final raw = _select(faces, frame);
      final snap = raw.withStable(_debounce(raw.facePresent));
      _publishToOverlay(snap);
      _snapshotController.add(snap);
    } catch (e, st) {
      FlutterError.reportError(FlutterErrorDetails(
        exception: e,
        stack: st,
        context: DiagnosticsNode.message('FaceTracker._process'),
      ));
      DebugBus.instance.put('LastError', e.toString());
    }
  }

  /// Spec Section 4.4: a state-relevant transition only fires after N
  /// consecutive frames in the new condition, so a single missed/spurious
  /// detection can't flicker downstream state.
  bool _debounce(bool rawPresent) {
    if (rawPresent) {
      _presentStreak++;
      _absentStreak = 0;
      if (!_stablePresent &&
          _presentStreak >= Tuning.get('debounce_face_gained').round()) {
        _stablePresent = true;
      }
    } else {
      _absentStreak++;
      _presentStreak = 0;
      if (_stablePresent &&
          _absentStreak >= Tuning.get('debounce_face_lost').round()) {
        _stablePresent = false;
      }
    }
    return _stablePresent;
  }

  FaceSnapshot _select(List<Face> faces, FrameData frame) {
    if (faces.isEmpty) {
      return FaceSnapshot.empty(frame.width, frame.height);
    }
    // Largest bounding box wins (spec 4.3).
    Face best = faces.first;
    double bestArea = 0;
    for (final f in faces) {
      final b = f.boundingBox;
      final area = (b.width * b.height).abs();
      if (area > bestArea) {
        bestArea = area;
        best = f;
      }
    }

    final b = best.boundingBox;
    final cx = b.center.dx;
    final cy = b.center.dy;
    final frameArea = (frame.width * frame.height).toDouble();
    final faceArea = (b.width * b.height).abs();
    final halfW = frame.width / 2;
    final halfH = frame.height / 2;
    // Mirror LookX — front camera is a mirror, so user moving right makes the
    // image move right; we want the duck to look the user's *actual* direction.
    final lookX = ((halfW - cx) / halfW).clamp(-1.0, 1.0);
    final lookY = ((cy - halfH) / halfH).clamp(-1.0, 1.0);

    return FaceSnapshot(
      facePresent: true,
      lookX: lookX,
      lookY: lookY,
      faceSizeRatio: frameArea > 0 ? faceArea / frameArea : 0.0,
      headTiltDeg: best.headEulerAngleZ ?? 0.0,
      smilingProb: best.smilingProbability ?? 0.0,
      leftEyeOpen: best.leftEyeOpenProbability ?? 1.0,
      rightEyeOpen: best.rightEyeOpenProbability ?? 1.0,
      width: frame.width,
      height: frame.height,
      rawCenterX: cx,
      rawCenterY: cy,
      rawBoxW: b.width,
      rawBoxH: b.height,
      faceCount: faces.length,
    );
  }

  void _publishToOverlay(FaceSnapshot s) {
    final bus = DebugBus.instance;
    bus.put('FaceLock',
        '${s.stableFacePresent ? "locked" : "searching"} (raw ${s.facePresent ? "yes" : "no"}, streak ${s.facePresent ? _presentStreak : _absentStreak})');
    bus.put('FaceCount', '${s.faceCount}');
    if (s.facePresent) {
      bus.put('FaceCenter',
          '(${s.rawCenterX.round()}, ${s.rawCenterY.round()})');
      bus.put('FaceSize', '${s.rawBoxW.round()}x${s.rawBoxH.round()}');
      bus.put('HeadEulerZ', s.headTiltDeg.toStringAsFixed(1));
      bus.put('SmilingProb', s.smilingProb.toStringAsFixed(2));
      bus.put('LeftEyeOpen', s.leftEyeOpen.toStringAsFixed(2));
      bus.put('RightEyeOpen', s.rightEyeOpen.toStringAsFixed(2));
      bus.put('LookX',
          '${s.lookX.toStringAsFixed(2)} (raw ${s.lookX.toStringAsFixed(2)})');
      bus.put('LookY',
          '${s.lookY.toStringAsFixed(2)} (raw ${s.lookY.toStringAsFixed(2)})');
    } else {
      bus.put('FaceCenter', '— none');
      bus.put('FaceSize', '—');
      bus.put('HeadEulerZ', '—');
      bus.put('SmilingProb', '—');
      bus.put('LeftEyeOpen', '—');
      bus.put('RightEyeOpen', '—');
      bus.put('LookX', '—');
      bus.put('LookY', '—');
    }

    _framesProcessed++;
    final now = DateTime.now();
    if (_firstFrameAt.millisecondsSinceEpoch == 0) {
      _firstFrameAt = now;
    } else if (_framesProcessed % 15 == 0) {
      final elapsed = now.difference(_firstFrameAt).inMicroseconds;
      final fps = elapsed > 0
          ? (_framesProcessed * 1000000 / elapsed).toStringAsFixed(1)
          : '0';
      bus.put('AchievedFps', fps);
    }
  }
}