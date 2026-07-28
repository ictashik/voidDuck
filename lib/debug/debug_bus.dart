import 'package:flutter/foundation.dart';

/// A singleton bus that any subsystem (camera, ML Kit, PetState, Rive, etc.)
/// writes to. The [DebugOverlay] listens and renders whatever is here.
///
/// This is intentionally a dumb key/value mirror of the overlay's required
/// fields from CLAUDE.md. Stages that don't exist yet just leave their entries
/// unset; the overlay shows "—" for missing values so the human can see what's
/// not wired yet.
class DebugBus extends ChangeNotifier {
  DebugBus._();
  static final DebugBus instance = DebugBus._();

  final Map<String, Object> _values = {};

  /// Replace the value for [key] and notify listeners only if it changed.
  /// Numeric values are compared with a tiny epsilon so noise doesn't cause
  /// a rebuild storm when values jitter by floating-point dust.
  void put(String key, Object? value) {
    if (value == null) {
      if (_values.remove(key) != null) notifyListeners();
      return;
    }
    final old = _values[key];
    if (old == value) return;
    if (old is num && value is num && (old - value).abs() < 1e-6) return;
    _values[key] = value;
    notifyListeners();
  }

  Object? get(String key) => _values[key];
  bool contains(String key) => _values.containsKey(key);
  int get length => _values.length;
  Iterable<MapEntry<String, Object>> get entries => _values.entries;
}