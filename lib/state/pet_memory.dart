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
///
/// [totalSeconds] tracks the current device-local calendar day, not an
/// all-time running total (explicit sign-off, same as when the field was
/// first added) — it resets the first time it's touched after the date
/// rolls over. [_kTotalSecondsDate] is bookkeeping for that reset, not a
/// fourth independently meaningful value.
class PetMemory {
  PetMemory._();
  static SharedPreferences? _prefs;

  static const _kLastSeenFaceMs = 'memory_last_seen_face_ms';
  static const _kMoodScalar = 'memory_mood_scalar';
  static const _kTotalSeconds = 'memory_total_seconds';
  static const _kTotalSecondsDate = 'memory_total_seconds_date';

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

  /// Cumulative Tracking/Idle presence time for *today* (device-local
  /// date), in seconds. Reads as 0 once the stored date no longer matches
  /// today, even if the underlying double is still whatever yesterday left
  /// behind — [PetStateController] is the one that actually re-zeroes the
  /// live counter on rollover; this getter just keeps a stale value from
  /// ever being handed back after a restart.
  static double get totalSeconds {
    if (_p.getString(_kTotalSecondsDate) != _todayKey()) return 0.0;
    return _p.getDouble(_kTotalSeconds) ?? 0.0;
  }

  static set totalSeconds(double v) {
    _p.setDouble(_kTotalSeconds, v);
    _p.setString(_kTotalSecondsDate, _todayKey());
  }

  static String _todayKey([DateTime? now]) {
    final d = now ?? DateTime.now();
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }
}
