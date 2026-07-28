import 'dart:async';

import 'package:screen_brightness/screen_brightness.dart';

import '../debug/debug_bus.dart';
import '../tuning/tuning.dart';
import 'pet_memory.dart';
import 'pet_state.dart';

/// The single mediator between ML Kit presence and both the display and the
/// camera/inference throttle (spec Section 6). Rive and the camera pipeline
/// both read from this; neither drives it independently.
///
/// Face presence in: call [onFacePresence] with the *debounced* signal every
/// time a new [FaceSnapshot] arrives. Everything else — timeouts, brightness
/// ramps, inference-rate throttling — runs off an internal ticker so it
/// keeps advancing even between frames.
class PetStateController {
  PetStateController({required this.setTargetFps});

  final void Function(double fps) setTargetFps;

  static const _tickInterval = Duration(milliseconds: 100);
  static const _tickSeconds = 0.1;

  PetState _state = PetState.tracking;
  double _secondsInState = 0;
  double _absenceSeconds = 0;
  double _brightness = 1.0;
  bool _stablePresent = false;
  Timer? _ticker;

  // Lap/total timers. lapSeconds resets on every Waking transition;
  // totalSeconds is cumulative across the app's lifetime and persisted
  // (CLAUDE.md's persistence carve-out, now three values).
  double _lapSeconds = 0;
  double _totalSeconds = 0;
  DateTime _lastPersistAt = DateTime.now();
  static const _persistInterval = Duration(seconds: 30);

  final List<String> _animLog = [];

  PetState get state => _state;
  double get brightness => _brightness;
  double get lapSeconds => _lapSeconds;
  double get totalSeconds => _totalSeconds;

  void start() {
    _totalSeconds = PetMemory.totalSeconds;
    setTargetFps(_targetFpsFor(_state));
    _publishDebug();
    _ticker = Timer.periodic(_tickInterval, (_) => _tick());
  }

  void stop() {
    if (_ticker == null) return; // start() was never called — nothing to flush
    _ticker?.cancel();
    _ticker = null;
    _persistTotal();
  }

  /// Called every time a new (debounced) presence reading arrives.
  void onFacePresence(bool stable) {
    _stablePresent = stable;
    if (!stable) return;

    _absenceSeconds = 0;
    switch (_state) {
      case PetState.dimming:
      case PetState.sleeping:
        _transition(PetState.waking);
        break;
      case PetState.idle:
        _transition(PetState.tracking);
        break;
      case PetState.tracking:
      case PetState.waking:
        break; // already there, or ramp already in progress
    }
  }

  void _tick() {
    _secondsInState += _tickSeconds;

    // lapSeconds/totalSeconds only accrue in the "present-ish" states.
    if (_state == PetState.tracking || _state == PetState.idle) {
      _lapSeconds += _tickSeconds;
      _totalSeconds += _tickSeconds;
    }
    if (DateTime.now().difference(_lastPersistAt) >= _persistInterval) {
      _persistTotal();
    }

    if (!_stablePresent) {
      _absenceSeconds += _tickSeconds;
      switch (_state) {
        case PetState.tracking:
          if (_absenceSeconds >= Tuning.get('idle_timeout_s')) {
            _transition(PetState.idle);
          }
          break;
        case PetState.idle:
          if (_absenceSeconds >= Tuning.get('dimming_timeout_s')) {
            _transition(PetState.dimming);
          }
          break;
        case PetState.dimming:
          if (_absenceSeconds >= Tuning.get('sleeping_timeout_s')) {
            _transition(PetState.sleeping);
          }
          break;
        case PetState.sleeping:
        case PetState.waking:
          break;
      }
    }

    if (_state == PetState.waking &&
        _secondsInState >= Tuning.get('wake_ramp_s')) {
      _transition(PetState.tracking);
    }

    _rampBrightness();
    _publishDebug();
  }

  void _transition(PetState next) {
    if (next == _state) return;
    _state = next;
    _secondsInState = 0;
    setTargetFps(_targetFpsFor(next));
    if (next == PetState.waking) {
      _lapSeconds = 0;
      _logAnim('wake (absence ${_absenceSeconds.toStringAsFixed(0)}s)');
    }
    _persistTotal();
  }

  void _persistTotal() {
    _lastPersistAt = DateTime.now();
    PetMemory.totalSeconds = _totalSeconds;
  }

  double _targetFpsFor(PetState s) {
    switch (s) {
      case PetState.tracking:
      case PetState.waking: // spec: jumps immediately to 15fps
        return Tuning.get('target_fps_tracking');
      case PetState.idle:
        return Tuning.get('target_fps_idle');
      case PetState.dimming:
        return Tuning.get('target_fps_dimming');
      case PetState.sleeping:
        return Tuning.get('target_fps_sleeping');
    }
  }

  double _targetBrightnessFor(PetState s) {
    switch (s) {
      case PetState.tracking:
      case PetState.waking: // ramps up toward full
        return Tuning.get('bright_tracking');
      case PetState.idle:
        return Tuning.get('bright_idle');
      case PetState.dimming:
        return Tuning.get('bright_dimming');
      case PetState.sleeping:
        return Tuning.get('bright_sleeping');
    }
  }

  void _rampBrightness() {
    final target = _targetBrightnessFor(_state);
    final maxDelta = Tuning.get('bright_ramp_rate') * _tickSeconds;
    final diff = target - _brightness;
    if (diff.abs() <= maxDelta) {
      _brightness = target;
    } else {
      _brightness += diff.sign * maxDelta;
    }
    // Best-effort: on a desktop test host, or a device that restricts window
    // brightness overrides, this can throw. Never let it take PetState down.
    ScreenBrightness()
        .setApplicationScreenBrightness(_brightness)
        .catchError((_) {});
  }

  void _logAnim(String label) {
    final now = DateTime.now();
    final ts = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    _animLog.insert(0, '$ts $label');
    if (_animLog.length > 5) _animLog.removeLast();
    DebugBus.instance.put('AnimLog', _animLog.join('\n'));
  }

  void _publishDebug() {
    DebugBus.instance.put('PetState', _state.name);
    DebugBus.instance.put('StateSeconds', _secondsInState.toStringAsFixed(1));
    DebugBus.instance.put('Brightness', _brightness.toStringAsFixed(2));
    DebugBus.instance.put('LapSeconds', _formatHms(_lapSeconds));
    DebugBus.instance.put('TotalSeconds', _formatHms(_totalSeconds));
  }

  static String _formatHms(double seconds) {
    final total = seconds.floor();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }
}
