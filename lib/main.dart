import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'app.dart';
import 'state/pet_memory.dart';
import 'tuning/tuning.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  _bootstrap();
}

Future<void> _bootstrap() async {
  await Tuning.init();
  await PetMemory.init();
  _applySystemChrome();
  _holdWakelock();
  runApp(const VoidDuckApp());
}

Future<void> _applySystemChrome() async {
  // Landscape locked (CLAUDE.md non-negotiable #4). The activity is also
  // pinned to sensorLandscape in the manifest so the lock survives a process
  // restart before Flutter boots.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  // Edge-to-edge black scaffold; the system bars would otherwise paint a
  // faint bright line at the top/bottom and spoil the pitch-black stage.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.black,
    systemNavigationBarColor: Colors.black,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarContrastEnforced: false,
  ));
}

Future<void> _holdWakelock() async {
  try {
    await WakelockPlus.enable();
  } catch (_) {
    // On a desktop unit-test host there's no wakelock API; ignore. On a real
    // Android device this should not throw — if it does, the human reports it
    // off the overlay/test card and we look.
  }
}