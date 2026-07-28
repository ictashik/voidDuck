import 'package:shared_preferences/shared_preferences.dart';

/// Persisted numeric/string tuning values shared by every subsystem.
///
/// Every "magic number that affects how the duck feels" must register a
/// knob here and a slider in the tuning panel. This is the highest-leverage
/// rule in CLAUDE.md: no rebuild-required tuning.
///
/// Values are stored as `double`. Integer-ish values (frame counts, rotations
/// in degrees) are read through `.round()` helpers in the call sites.
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
    'debounce_startle': TuningSpec('Startle frames', 1, 30, 3, step: 1),

    // --- Damped gaze (aliveness layer) ---
    'layer_damped_gaze': TuningSpec('Damped gaze on', 0, 1, 1, step: 1),
    'gaze_spring_stiffness': TuningSpec('Spring stiffness', 10, 300, 90),
    'gaze_spring_damping': TuningSpec('Spring damping', 1, 40, 12),

    // --- Smile hysteresis (CLAUDE.md spec) ---
    'smile_on': TuningSpec('Smile on prob', 0, 1, 0.7),
    'smile_off': TuningSpec('Smile off prob', 0, 1, 0.5),

    // --- Blink thresholds ---
    'eye_closed': TuningSpec('Eye closed prob', 0, 1, 0.3),

    // --- Proximity (bounding box size as fraction of frame) ---
    'prox_startle_on': TuningSpec('Startle box > %', 0, 1, 0.55),
    'prox_startle_off': TuningSpec('Startle box < %', 0, 1, 0.4),
    'startle_cooldown_s': TuningSpec('Startle cooldown s', 0, 10, 2),
    'startle_dilate_scale': TuningSpec('Startle dilate scale', 1.0, 1.5, 1.15),
    'startle_ease_rate': TuningSpec('Startle ease /s', 1, 20, 6),

    // --- Head tilt -> eye-pair rotation ---
    'tilt_max_deg': TuningSpec('Max tilt deg', 5, 45, 25),
    'tilt_smoothing': TuningSpec('Tilt smoothing', 0, 1, 0.25),

    // --- Idle breathing pulse (always-on ambient, ties to no detection state) ---
    'breathe_amplitude': TuningSpec('Breathe amplitude', 0, 0.1, 0.02),
    'breathe_rate_hz': TuningSpec('Breathe rate Hz', 0.05, 1.0, 0.25),

    // --- PetState timeouts (Section 6 of spec) ---
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

    // --- Stare-break (later stage) ---
    'stare_break_min_s': TuningSpec('Stare-break min s', 1, 30, 3),
    'stare_break_max_s': TuningSpec('Stare-break max s', 1, 30, 8),

    // --- Interest meter (later stage) ---
    'interest_decay_per_s': TuningSpec('Interest decay /s', 0, 0.5, 0.03),
    'interest_refresh': TuningSpec('Interest refresh', 0, 1, 0.6),

    // --- Ambient quirk idle interval (CLAUDE.md spec Section 5) ---
    'quirk_min_s': TuningSpec('Quirk min s', 5, 300, 30),
    'quirk_max_s': TuningSpec('Quirk max s', 5, 300, 90),

    // --- Rare events (~1-in-300 chance per ambient tick) ---
    'rare_event_chance': TuningSpec('Rare-event chance', 0, 0.1, 0.0033),

    // --- Notice latency (reacquisition) ---
    'notice_latency_min_ms': TuningSpec('Notice latency min ms', 0, 3000, 200, step: 10),
    'notice_latency_max_ms': TuningSpec('Notice latency max ms', 0, 3000, 1500, step: 10),
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
    'debounce_startle': 3,
    'layer_damped_gaze': 1,
    'gaze_spring_stiffness': 90,
    'gaze_spring_damping': 12,
    'smile_on': 0.7,
    'smile_off': 0.5,
    'eye_closed': 0.3,
    'prox_startle_on': 0.55,
    'prox_startle_off': 0.4,
    'startle_cooldown_s': 2,
    'startle_dilate_scale': 1.15,
    'startle_ease_rate': 6,
    'tilt_max_deg': 25,
    'tilt_smoothing': 0.25,
    'breathe_amplitude': 0.02,
    'breathe_rate_hz': 0.25,
    'idle_timeout_s': 15,
    'dimming_timeout_s': 45,
    'sleeping_timeout_s': 90,
    'wake_ramp_s': 1,
    'bright_tracking': 1.0,
    'bright_idle': 1.0,
    'bright_dimming': 0.08,
    'bright_sleeping': 0.03,
    'bright_ramp_rate': 1.5,
    'stare_break_min_s': 3,
    'stare_break_max_s': 8,
    'interest_decay_per_s': 0.03,
    'interest_refresh': 0.6,
    'quirk_min_s': 30,
    'quirk_max_s': 90,
    'rare_event_chance': 0.0033,
    'notice_latency_min_ms': 200,
    'notice_latency_max_ms': 1500,
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