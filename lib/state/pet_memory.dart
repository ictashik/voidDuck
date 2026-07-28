import 'package:shared_preferences/shared_preferences.dart';

/// CLAUDE.md's "one persistence carve-out": exactly three values survive an
/// app restart — a last-seen-face timestamp, a mood scalar, and
/// totalSeconds. Nothing else may be added here without explicit sign-off;
/// this is a deliberately narrow store, kept separate from [Tuning]'s
/// SharedPreferences usage so the two don't get confused — tuning knobs are
/// unlimited and dev-facing, this is not.
///
/// [lastSeenFaceMs] and [moodScalar] are reserved for the circadian-mood /
/// absence-scaled-greeting layer (not yet built); only [totalSeconds] is
/// actively written today.
class PetMemory {
  PetMemory._();
  static SharedPreferences? _prefs;

  static const _kLastSeenFaceMs = 'memory_last_seen_face_ms';
  static const _kMoodScalar = 'memory_mood_scalar';
  static const _kTotalSeconds = 'memory_total_seconds';

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  static SharedPreferences get _p {
    final p = _prefs;
    if (p == null) {
      throw StateError('PetMemory.init() must be awaited before use');
    }
    return p;
  }

  static int? get lastSeenFaceMs => _p.getInt(_kLastSeenFaceMs);
  static set lastSeenFaceMs(int? v) {
    if (v == null) {
      _p.remove(_kLastSeenFaceMs);
    } else {
      _p.setInt(_kLastSeenFaceMs, v);
    }
  }

  static double get moodScalar => _p.getDouble(_kMoodScalar) ?? 0.5;
  static set moodScalar(double v) => _p.setDouble(_kMoodScalar, v);

  /// Cumulative Tracking/Idle presence time, all-time, in seconds.
  static double get totalSeconds => _p.getDouble(_kTotalSeconds) ?? 0.0;
  static set totalSeconds(double v) => _p.setDouble(_kTotalSeconds, v);
}
