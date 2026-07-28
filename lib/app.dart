import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'debug/debug_bus.dart';
import 'gaze/gaze_controller.dart';
import 'render/pixel_robot.dart';
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
  static const _gazeTick = Duration(milliseconds: 16);
  double _lastRawX = 0;
  double _lastRawY = 0;

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
        }
        final eyeClosed = Tuning.get('eye_closed');
        final blink = s.stableFacePresent &&
            (s.leftEyeOpen < eyeClosed || s.rightEyeOpen < eyeClosed);
        DebugBus.instance.put('SpriteFrame',
            'body: rest, lens: ${blink ? "closed (blink)" : "open"}');
        if (s.stableFacePresent != _faceHere || blink != _blink) {
          setState(() {
            _faceHere = s.stableFacePresent;
            _blink = blink;
          });
        }
      });
      _gazeTicker = Timer.periodic(_gazeTick, (_) {
        _gaze.tick(_gazeTick.inMicroseconds / 1e6);
        DebugBus.instance.put('LookX',
            '${_gaze.x.toStringAsFixed(2)} (raw ${_lastRawX.toStringAsFixed(2)})');
        DebugBus.instance.put('LookY',
            '${_gaze.y.toStringAsFixed(2)} (raw ${_lastRawY.toStringAsFixed(2)})');
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
    // Stage 5 body: the pixel-art robot (CLAUDE.md "Rendering Approach").
    // Body/glasses are a static code-defined grid painted by RobotPainter;
    // the eye-dot inside the lenses is the one element positioned
    // continuously every frame from the damped-gaze spring, never
    // frame-snapped (non-negotiable #6).
    //
    // Sized off the available viewport rather than a fixed constant so it
    // fills most of the screen regardless of device — a desk pet you can
    // barely see at a glance has failed at being a desk pet.
    return Stack(
      children: [
        Center(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final robotSize =
                  constraints.biggest.shortestSide * 0.92;
              final bodyOffset = Offset(
                _gaze.x.clamp(-1.0, 1.0) * robotSize * 0.03,
                _gaze.y.clamp(-1.0, 1.0) * robotSize * 0.03,
              );
              return AnimatedOpacity(
                duration: const Duration(milliseconds: 400),
                opacity: _faceHere ? 1.0 : 0.3,
                child: SizedBox(
                  width: robotSize,
                  height: robotSize,
                  child: CustomPaint(
                    painter: RobotPainter(
                      blink: _blink,
                      eyeX: _gaze.x.clamp(-1.0, 1.0),
                      eyeY: _gaze.y.clamp(-1.0, 1.0),
                      bodyOffset: bodyOffset,
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