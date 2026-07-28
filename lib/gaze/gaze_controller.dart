import '../tuning/tuning.dart';
import '../vision/face_tracker.dart';

/// Owns the on-screen gaze position. Takes the raw per-frame [FaceSnapshot]
/// lookX/lookY as a target and simulates a damped spring toward it on its
/// own high-frequency tick, so motion stays smooth between the camera's
/// sparse ~15fps updates, trails the face, overshoots on fast movement, and
/// settles — the "Damped gaze" aliveness layer (CLAUDE.md).
///
/// Toggle via the `layer_damped_gaze` tuning knob: off snaps straight to the
/// raw target every tick with no spring dynamics, so the human can feel
/// exactly what this layer contributes.
class GazeController {
  double _targetX = 0;
  double _targetY = 0;
  double _velX = 0;
  double _velY = 0;
  double x = 0;
  double y = 0;

  void onSnapshot(FaceSnapshot s, {required bool justAcquired}) {
    if (!s.stableFacePresent) return; // hold last target while face is away
    _targetX = s.lookX;
    _targetY = s.lookY;
    if (justAcquired) {
      // Snap straight to the raw position on first lock — trailing in from
      // wherever the circle idled would read as a stray swoop, not as
      // "found you."
      x = _targetX;
      y = _targetY;
      _velX = 0;
      _velY = 0;
    }
  }

  void tick(double dt) {
    if (Tuning.get('layer_damped_gaze') < 0.5) {
      x = _targetX;
      y = _targetY;
      _velX = 0;
      _velY = 0;
      return;
    }
    final stiffness = Tuning.get('gaze_spring_stiffness');
    final damping = Tuning.get('gaze_spring_damping');
    final accX = stiffness * (_targetX - x) - damping * _velX;
    final accY = stiffness * (_targetY - y) - damping * _velY;
    _velX += accX * dt;
    _velY += accY * dt;
    x += _velX * dt;
    y += _velY * dt;
  }
}
