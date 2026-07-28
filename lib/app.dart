import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

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
  StreamSubscription<FaceSnapshot>? _sub;
  _PermissionState _perm = _PermissionState.unknown;
  String? _error;
  bool _faceHere = false;

  @override
  void initState() {
    super.initState();
    _camera = CameraService();
    _tracker = FaceTracker(_camera);
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
      _camera.setTargetFps(Tuning.get('target_fps_tracking'));
      _tracker.start();
      _sub = _tracker.snapshots.listen((s) {
        if (s.stableFacePresent != _faceHere) {
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
    // Stage 2 body: a black stage with a tiny "FACE: yes/no" indicator so the
    // human has one visual confirmation that the pipeline is alive — the
    // overlay carries the actual numbers.
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _faceHere ? Icons.visibility : Icons.visibility_off_outlined,
            color: Color(_faceHere ? 0x66FFFFFF : 0x22FFFFFF),
            size: 28,
          ),
          const SizedBox(height: 6),
          Text(
            'face ${_faceHere ? "found" : "searching"}',
            style: const TextStyle(color: Color(0x33FFFFFF), fontSize: 11),
          ),
        ],
      ),
    );
  }
}