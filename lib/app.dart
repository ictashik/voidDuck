import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'debug/debug_bus.dart';
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
  StreamSubscription<FaceSnapshot>? _sub;
  _PermissionState _perm = _PermissionState.unknown;
  String? _error;
  bool _faceHere = false;
  double _smoothX = 0;
  double _smoothY = 0;

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
        final smoothing = Tuning.get('gaze_smoothing').clamp(0.0, 0.98);
        if (justAcquired) {
          // Snap straight to the raw position on first lock — trailing in
          // from wherever the circle idled would read as a stray swoop, not
          // as "found you."
          _smoothX = s.lookX;
          _smoothY = s.lookY;
        } else if (s.stableFacePresent) {
          _smoothX += (s.lookX - _smoothX) * (1 - smoothing);
          _smoothY += (s.lookY - _smoothY) * (1 - smoothing);
        }
        DebugBus.instance.put('LookX',
            '${_smoothX.toStringAsFixed(2)} (raw ${s.lookX.toStringAsFixed(2)})');
        DebugBus.instance.put('LookY',
            '${_smoothY.toStringAsFixed(2)} (raw ${s.lookY.toStringAsFixed(2)})');
        if (s.stableFacePresent != _faceHere || s.stableFacePresent) {
          setState(() => _faceHere = s.stableFacePresent);
        }
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
    // Stage 3 body: a plain circle standing in for the duck, following the
    // face via the smoothed LookX/LookY. Proves the pipeline end to end
    // before any Rive art exists (spec build order, Stage 3).
    return Stack(
      children: [
        AnimatedAlign(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          alignment: Alignment(
            _smoothX.clamp(-1.0, 1.0),
            _smoothY.clamp(-1.0, 1.0),
          ),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 400),
            opacity: _faceHere ? 1.0 : 0.15,
            child: Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFFEDEDED),
              ),
            ),
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