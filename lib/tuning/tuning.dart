import 'package:shared_preferences/shared_preferences.dart';

/// Persisted numeric/string tuning values shared by every subsystem.
///
/// Every "magic number that affects how the duck feels" must register a
/// knob here and a slider in the tuning panel. This is the highest-leverage
/// rule in CLAUDE.md: no rebuild-required tuning.
///
/// Values are stored as `double`. Integer-ish values (frame counts, minutes)
/// are read through `.round()` helpers in the call sites.
class Tuning {
  Tuning._();
  static SharedPreferences? _prefs;

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _applyDefaults();
  }

  static SharedPreferences get _p {
    final p = _prefs;
    if (p == null) {
      throw StateError('Tuning.init() must be awaited before use');
    }
    return p;
  }

  /// Apply defaults without overwriting user-set values. Called once on init
  /// and again when the tuning panel "reset to defaults" button fires after
  /// clearing keys.
  static void _applyDefaults() {
    for (final entry in _defaults.entries) {
      final key = entry.key;
      if (!_p.containsKey(key)) {
        _p.setDouble(key, entry.value);
      }
    }
  }

  static double get(String key) => _p.getDouble(key) ?? (_defaults[key] ?? 0.0);

  static void set(String key, double v) => _p.setDouble(key, v);

  static const String _userNameKey = 'user_name';
  static const String userNameDefault = 'Ashikh';

  /// The one non-numeric tuning value (spec: the human's name, used to
  /// personalize Waking greetings and the away-state banner). Kept
  /// separate from the numeric `specs`/`_defaults` machinery above rather
  /// than shoehorned into a double, and edited via its own text field in
  /// the tuning panel instead of a slider.
  static String get userName {
    final v = _p.getString(_userNameKey);
    return (v == null || v.trim().isEmpty) ? userNameDefault : v;
  }

  static set userName(String v) {
    final trimmed = v.trim();
    _p.setString(_userNameKey, trimmed.isEmpty ? userNameDefault : trimmed);
  }

  static void reset() {
    for (final key in _defaults.keys) {
      _p.remove(key);
    }
    _applyDefaults();
  }

  /// Dump current values as a Dart snippet the human can paste back so tuning
  /// becomes a conversation instead of a build queue (CLAUDE.md quote).
  static String dumpAsDart() {
    final buf = StringBuffer('/// Paste into lib/tuning.dart defaults map.\n')
      ..writeln('static const Map<String, double> _defaults = {');
    final keys = _defaults.keys.toList()..sort();
    for (final k in keys) {
      final v = get(k);
      final formatted = v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(3);
      buf.writeln("  '$k': $formatted,");
    }
    buf.writeln('};');
    return buf.toString();
  }

  /// Spec of every tunable key: min, max, suggested default, and a human label.
  /// The tuning panel iterates over this — adding a number here makes it
  /// tunable in-app with no other code change.
  static const Map<String, TuningSpec> specs = {
    // --- Camera / ML Kit pipeline ---
    'camera_rotation': TuningSpec('Camera rotation', 0, 270, 180, step: 90),
    'camera_image_width_divisor': TuningSpec('Image scale divisor', 1, 8, 2, step: 1),
    'target_fps_tracking': TuningSpec('Target fps (Tracking)', 1, 30, 15, step: 1),
    'target_fps_idle': TuningSpec('Target fps (Idle)', 1, 15, 5, step: 1),
    'target_fps_dimming': TuningSpec('Target fps (Dimming)', 1, 15, 2, step: 1),
    'target_fps_sleeping': TuningSpec('Target fps (Sleeping)', 1, 15, 1, step: 1),
    'min_face_size': TuningSpec('Min face size px', 0, 500, 24, step: 1),

    // --- Debounce (consecutive frames before a state-changing event) ---
    'debounce_face_lost': TuningSpec('Face-lost frames', 1, 30, 4, step: 1),
    'debounce_face_gained': TuningSpec('Face-gained frames', 1, 30, 3, step: 1),

    // --- PetState timeouts (spec Section 4/6) ---
    'idle_timeout_s': TuningSpec('-> Idle after s', 5, 120, 15),
    'dimming_timeout_s': TuningSpec('-> Dimming after s', 5, 180, 45),
    'sleeping_timeout_s': TuningSpec('-> Sleeping after s', 5, 300, 90),
    'wake_ramp_s': TuningSpec('Wake brightness ramp s', 0.1, 5, 1),

    // --- Brightness levels (0..1) ---
    'bright_tracking': TuningSpec('Bright Tracking', 0, 1, 1.0),
    'bright_idle': TuningSpec('Bright Idle', 0, 1, 1.0),
    'bright_dimming': TuningSpec('Bright Dimming', 0, 1, 0.08),
    'bright_sleeping': TuningSpec('Bright Sleeping', 0, 1, 0.03),
    'bright_ramp_rate': TuningSpec('Bright change / s', 0.05, 5, 1.5),

    // --- Banner (Zones 2-4, spec Section 3) ---
    'banner_reveal_chars_per_s':
        TuningSpec('Banner reveal chars/s', 2, 60, 18, step: 1),
    'banner_cursor_blink_ms':
        TuningSpec('Banner cursor blink ms', 100, 2000, 500, step: 50),

    // --- Reaction Engine triggers (spec Section 4.1) ---
    'ambient_tick_interval_s':
        TuningSpec('Ambient tick every s', 20, 900, 120, step: 5),

    // --- Gesture (Open_Palm) trigger (spec Section 4.2.3) ---
    'gesture_poll_interval_ms':
        TuningSpec('Gesture poll every ms', 100, 2000, 400, step: 50),
    'gesture_confidence_threshold':
        TuningSpec('Gesture min confidence', 0.1, 1.0, 0.6, step: 0.05),
    'gesture_debounce_frames':
        TuningSpec('Gesture debounce polls', 1, 10, 2, step: 1),
    'gesture_cooldown_s':
        TuningSpec('Gesture cooldown s', 5, 180, 20, step: 5),
    // How long a gesture/voice exchange counts as an ongoing "conversation":
    // ambient is held off and a follow-up gesture or voice trigger gets the
    // prior reply as context, instead of being treated as a fresh,
    // unrelated encounter. Bumped from 45s to 300s (5 min) now that voice
    // shares this same window — a spoken exchange plausibly has pauses
    // (thinking, typing a follow-up) longer than the old gesture-only value
    // assumed.
    'conversation_window_s':
        TuningSpec('Conversation window s', 15, 600, 300, step: 15),
    // How long an absence has to last before backFromBreak actually shows a
    // greeting. Below this, onReturn still fires (lap timer etc. still
    // reset as usual) but the reaction on screen is left alone — a glance
    // away or briefly covering the face shouldn't read as "welcome back
    // after a 16-second break".
    'min_break_greeting_s':
        TuningSpec('Min break for greeting s', 5, 600, 120, step: 5),

    // --- Voice recording (Open_Palm trigger, spec Section 4.4) ---
    // Hard cap on one recording window: Closed_Fist stops it early, this is
    // the ceiling if it never comes. Not really a technical limit of the
    // chunked-STT approach (each 5s chunk is independent), but a UX one —
    // how long anyone should reasonably be expected to talk in one go.
    'recording_max_duration_s':
        TuningSpec('Recording max duration s', 5, 60, 30, step: 5),

    // --- Device thermal readout (top-left corner) ---
    'device_temp_warn_c':
        TuningSpec('Temp warn threshold C', 30, 60, 42, step: 1),
  };

  /// Suggested defaults. MUST stay in sync with [specs].
  static const Map<String, double> _defaults = {
    // Confirmed on the target device: the front camera's sensor is mounted
    // 180° from what a naive rotation=0 assumption expects.
    'camera_rotation': 180,
    'camera_image_width_divisor': 2,
    'target_fps_tracking': 15,
    'target_fps_idle': 5,
    'target_fps_dimming': 2,
    'target_fps_sleeping': 1,
    'min_face_size': 24,
    'debounce_face_lost': 4,
    'debounce_face_gained': 3,
    'idle_timeout_s': 15,
    'dimming_timeout_s': 45,
    'sleeping_timeout_s': 90,
    'wake_ramp_s': 1,
    'bright_tracking': 1.0,
    'bright_idle': 1.0,
    'bright_dimming': 0.08,
    'bright_sleeping': 0.03,
    'bright_ramp_rate': 1.5,
    'banner_reveal_chars_per_s': 18,
    'banner_cursor_blink_ms': 500,
    'ambient_tick_interval_s': 120,
    'gesture_poll_interval_ms': 400,
    'gesture_confidence_threshold': 0.6,
    'gesture_debounce_frames': 2,
    'gesture_cooldown_s': 20,
    'conversation_window_s': 300,
    'min_break_greeting_s': 120,
    'recording_max_duration_s': 30,
    'device_temp_warn_c': 42,
  };
}

/// Specification for a tunable knob: how it should appear in the panel.
class TuningSpec {
  final String label;
  final double min;
  final double max;
  final double suggestedDefault;
  final double? step;

  const TuningSpec(this.label, this.min, this.max, this.suggestedDefault,
      {this.step});
}
