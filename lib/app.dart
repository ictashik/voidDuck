import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'debug/debug_bus.dart';
import 'gaze/gaze_controller.dart';
import 'render/pixel_eyes.dart';
import 'state/pet_state.dart';
import 'state/pet_state_controller.dart';
import 'tuning/tuning.dart';
import 'vision/camera_service.dart';
import 'vision/face_tracker.dart';
import 'ui/debug_overlay.dart';
import 'ui/permission_gate.dart';

class VoidDuckApp extends StatelessWidget {
  const VoidDuckApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VoidDuck',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Colors.black,
          surface: Colors.black,
          onSurface: Colors.white,
        ),
      ),
      home: const _Stage(),
    );
  }
}

class _Stage extends StatefulWidget {
  const _Stage();

  @override
  State<_Stage> createState() => _StageState();
}

enum _PermissionState { unknown, denied, granted, permanently }

class _StageState extends State<_Stage> {
  late final CameraService _camera;
  late final FaceTracker _tracker;
  late final PetStateController _petState;
  final GazeController _gaze = GazeController();
  StreamSubscription<FaceSnapshot>? _sub;
  Timer? _gazeTicker;
  _PermissionState _perm = _PermissionState.unknown;
  String? _error;
  bool _faceHere = false;
  bool _blink = false;
  bool _smiling = false;
  bool _startled = false;
  int _startleStreak = 0;
  DateTime? _startleCooldownUntil;

  static const _gazeTick = Duration(milliseconds: 16);
  double _lastRawX = 0;
  double _lastRawY = 0;
  double _lastRawTiltDeg = 0;
  double _tiltRad = 0;
  double _proxScale = 1.0;
  double _breathePhase = 0;

  @override
  void initState() {
    super.initState();
    _camera = CameraService();
    _tracker = FaceTracker(_camera);
    _petState = PetStateController(setTargetFps: _camera.setTargetFps);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final status = await Permission.camera.status;
    setState(() {
      _perm = status.isGranted
          ? _PermissionState.granted
          : status.isPermanentlyDenied
              ? _PermissionState.permanently
              : _PermissionState.denied;
    });
    if (_perm == _PermissionState.granted) {
      await _startPipeline();
    }
  }

  Future<void> _requestPermission() async {
    final status = await Permission.camera.request();
    setState(() {
      _error = null;
      _perm = status.isGranted
          ? _PermissionState.granted
          : status.isPermanentlyDenied
              ? _PermissionState.permanently
              : _PermissionState.denied;
    });
    if (_perm == _PermissionState.granted) {
      await _startPipeline();
    } else if (_perm == _PermissionState.permanently) {
      setState(() => _error =
          'Camera permission permanently denied. Re-enable it from system settings.');
    }
  }

  Future<void> _startPipeline() async {
    try {
      await _camera.start();
      _tracker.start();
      _petState.start();
      _sub = _tracker.snapshots.listen((s) {
        _petState.onFacePresence(s.stableFacePresent);
        final justAcquired = s.stableFacePresent && !_faceHere;
        _gaze.onSnapshot(s, justAcquired: justAcquired);
        if (s.stableFacePresent) {
          _lastRawX = s.lookX;
          _lastRawY = s.lookY;
          _lastRawTiltDeg = s.headTiltDeg;
        }

        final eyeClosed = Tuning.get('eye_closed');
        final blink = s.stableFacePresent &&
            (s.leftEyeOpen < eyeClosed || s.rightEyeOpen < eyeClosed);

        // Smile: hysteresis, not a single threshold (spec Section 5).
        final smileOn = Tuning.get('smile_on');
        final smileOff = Tuning.get('smile_off');
        if (s.stableFacePresent) {
          if (!_smiling && s.smilingProb > smileOn) {
            _smiling = true;
          } else if (_smiling && s.smilingProb < smileOff) {
            _smiling = false;
          }
        } else {
          _smiling = false;
        }

        _updateStartle(s);

        if (s.stableFacePresent != _faceHere || blink != _blink) {
          setState(() {
            _faceHere = s.stableFacePresent;
            _blink = blink;
          });
        }
      });
      _gazeTicker = Timer.periodic(_gazeTick, (_) {
        final dt = _gazeTick.inMicroseconds / 1e6;
        _gaze.tick(dt);
        _tickTilt(dt);
        _tickBreathing(dt);
        _tickProximityEase(dt);
        DebugBus.instance.put('LookX',
            '${_gaze.x.toStringAsFixed(2)} (raw ${_lastRawX.toStringAsFixed(2)})');
        DebugBus.instance.put('LookY',
            '${_gaze.y.toStringAsFixed(2)} (raw ${_lastRawY.toStringAsFixed(2)})');
        final state = _resolveEyelidState();
        DebugBus.instance.put(
            'EyelidFrame', '${state.name} / ${state.name}');
        setState(() {});
      });
    } catch (e, st) {
      FlutterError.reportError(FlutterErrorDetails(
        exception: e,
        stack: st,
        context: DiagnosticsNode.message('_Stage._startPipeline'),
      ));
      setState(() => _error = 'Camera failed to start: $e');
    }
  }

  /// Proximity/startle debounce + cooldown (spec Section 5), mirroring the
  /// same consecutive-frames pattern FaceTracker uses for face presence.
  void _updateStartle(FaceSnapshot s) {
    final proxOn = Tuning.get('prox_startle_on');
    final proxOff = Tuning.get('prox_startle_off');
    final now = DateTime.now();
    if (!_startled) {
      if (s.stableFacePresent && s.faceSizeRatio > proxOn) {
        _startleStreak++;
        final needed = Tuning.get('debounce_startle').round();
        final cooldownOver =
            _startleCooldownUntil == null || now.isAfter(_startleCooldownUntil!);
        if (_startleStreak >= needed && cooldownOver) {
          _startled = true;
          _startleStreak = 0;
        }
      } else {
        _startleStreak = 0;
      }
    } else {
      if (!s.stableFacePresent || s.faceSizeRatio < proxOff) {
        _startled = false;
        final cooldownS = Tuning.get('startle_cooldown_s');
        _startleCooldownUntil =
            now.add(Duration(milliseconds: (cooldownS * 1000).round()));
      }
    }
  }

  void _tickTilt(double dt) {
    final maxDeg = Tuning.get('tilt_max_deg');
    final targetRad =
        _lastRawTiltDeg.clamp(-maxDeg, maxDeg) * math.pi / 180.0;
    final smoothing = Tuning.get('tilt_smoothing').clamp(0.0, 0.98);
    _tiltRad += (targetRad - _tiltRad) * (1 - smoothing);
  }

  void _tickBreathing(double dt) {
    _breathePhase += 2 * math.pi * Tuning.get('breathe_rate_hz') * dt;
  }

  void _tickProximityEase(double dt) {
    final target =
        _startled ? Tuning.get('startle_dilate_scale') : 1.0;
    final maxDelta = Tuning.get('startle_ease_rate') * dt;
    final diff = target - _proxScale;
    if (diff.abs() <= maxDelta) {
      _proxScale = target;
    } else {
      _proxScale += diff.sign * maxDelta;
    }
  }

  EyelidState _resolveEyelidState() {
    if (_petState.state == PetState.waking) return EyelidState.wide;
    if (_blink) return EyelidState.closed;
    if (_startled) return EyelidState.wide;
    if (_smiling) return EyelidState.squint;
    return EyelidState.open;
  }

  @override
  void dispose() {
    _sub?.cancel();
    _gazeTicker?.cancel();
    _petState.stop();
    _tracker.stop();
    _camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DebugOverlay(
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _body(),
      ),
    );
  }

  Widget _body() {
    if (_perm != _PermissionState.granted) {
      return PermissionGate(
        onGrant: _requestPermission,
        errorText: _error,
      );
    }
    // Stage 5 body: the pixel-art eye pair (CLAUDE.md "Rendering Approach").
    // Each socket is a static code-defined grid painted by EyePairPainter;
    // the pupil inside each socket is the one element positioned
    // continuously every frame from the damped-gaze spring, never
    // frame-snapped (non-negotiable #6).
    //
    // Sized off the available viewport rather than a fixed constant so it
    // fills most of the screen regardless of device — a desk pet you can
    // barely see at a glance has failed at being a desk pet.
    final breatheScale =
        1 + math.sin(_breathePhase) * Tuning.get('breathe_amplitude');
    final pairScale = _proxScale * breatheScale;
    final eyelidState = _resolveEyelidState();
    return Stack(
      children: [
        Center(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = constraints.biggest.shortestSide * 0.92;
              final pairOffset = Offset(
                _gaze.x.clamp(-1.0, 1.0) * size * 0.03,
                _gaze.y.clamp(-1.0, 1.0) * size * 0.03,
              );
              return AnimatedOpacity(
                duration: const Duration(milliseconds: 400),
                opacity: _faceHere ? 1.0 : 0.3,
                child: SizedBox(
                  width: size,
                  height: size,
                  child: CustomPaint(
                    painter: EyePairPainter(
                      leftState: eyelidState,
                      rightState: eyelidState,
                      pupilX: _gaze.x.clamp(-1.0, 1.0),
                      pupilY: _gaze.y.clamp(-1.0, 1.0),
                      pairRotation: _tiltRad,
                      pairScale: pairScale,
                      pairOffset: pairOffset,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Positioned(
          left: 8,
          bottom: 8,
          child: Text(
            'face ${_faceHere ? "found" : "searching"}',
            style: const TextStyle(color: Color(0x33FFFFFF), fontSize: 11),
          ),
        ),
      ],
    );
  }
}
