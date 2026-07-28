import 'package:flutter/material.dart';

import 'ui/debug_overlay.dart';

/// Root widget. Stage 1 (scaffold): black background, landscape lock applied
/// from main.dart, wakelock held from main.dart, debug overlay wraps the
/// empty stage. Future stages drop the pet UI inside [DebugOverlay.child].
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
          onPrimary: Colors.black,
          secondary: Colors.black,
          onSecondary: Colors.black,
          surface: Colors.black,
          onSurface: Colors.white,
        ),
      ),
      home: const _Stage(),
    );
  }
}

class _Stage extends StatelessWidget {
  const _Stage();

  @override
  Widget build(BuildContext context) {
    // The pet renders here in later stages. For scaffold we just show a black
    // screen with a faint center marker so the human can confirm the APK
    // actually booted (and didn't hang on a splash).
    return DebugOverlay(
      child: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.energy_savings_leaf, color: Color(0x33FFFFFF), size: 28),
              SizedBox(height: 6),
              Text(
                'voidduck v0.1',
                style: TextStyle(color: Color(0x22FFFFFF), fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}