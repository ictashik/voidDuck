import 'package:flutter/material.dart';

/// The CRT-terminal stage palette and shared text styles (SKILL.md "Tactical
/// Telemetry" substrate, distilled from example.html's `:root`).
///
/// Every color on the stage lives here so the taste stays consistent:
/// black/charcoal substrate, white phosphor foreground, ONE hazard-red
/// accent, and terminal green on exactly one element (the live status dot).
class StageColors {
  StageColors._();

  /// Stage substrate. The spec says charcoal; the human's explicit call is
  /// that the stage background stays pure black — so this is the one
  /// deviation from the skill's palette, applied to the stage itself only.
  static const Color crt = Color(0xFF000000);

  /// Slightly-lifted charcoal for chrome bars and panels (example `--crt-2`).
  static const Color crt2 = Color(0xFF131312);

  /// Hairline rules: borders and grid gaps (example `--rule`).
  static const Color rule = Color(0xFF2A2A27);

  /// Stronger hairline (example `--rule-strong`).
  static const Color ruleStrong = Color(0xFF3A3A36);

  /// Primary phosphor foreground (example `--phos`).
  static const Color phos = Color(0xFFECECEA);

  /// Secondary phosphor (example `--phos-soft`).
  static const Color phosSoft = Color(0xFF9F9F9C);

  /// Muted phosphor (example `--phos-mute`).
  static const Color phosMute = Color(0xFF6A6A67);

  /// The single accent (example `--hazard`).
  static const Color hazard = Color(0xFFE61919);

  /// Hazard at low alpha for soft fills (example `--hazard-soft`).
  static const Color hazardSoft = Color(0x1FE61919);

  /// Terminal green — reserved for the status/live dot, nothing else.
  static const Color green = Color(0xFF4AF626);
}

/// Shared text styles for the terminal chrome and readouts.
class StageText {
  StageText._();

  static const String mono = 'JetBrainsMono';

  static const TextStyle label = TextStyle(
    fontFamily: mono,
    fontSize: 10.5,
    letterSpacing: 0.16,
    height: 1.2,
    color: StageColors.phosSoft,
  );

  static const TextStyle labelStrong = TextStyle(
    fontFamily: mono,
    fontSize: 10.5,
    letterSpacing: 0.16,
    height: 1.2,
    fontWeight: FontWeight.w700,
    color: StageColors.phos,
  );

  static const TextStyle labelRed = TextStyle(
    fontFamily: mono,
    fontSize: 10.5,
    letterSpacing: 0.16,
    height: 1.2,
    fontWeight: FontWeight.w700,
    color: StageColors.hazard,
  );

  /// Small uppercase section header inside panels (debug overlay, tuning).
  static const TextStyle section = TextStyle(
    fontFamily: mono,
    fontSize: 9,
    letterSpacing: 1.0,
    fontWeight: FontWeight.w600,
    color: StageColors.phosSoft,
  );

  /// Body label inside panels.
  static const TextStyle body = TextStyle(
    fontFamily: mono,
    fontSize: 10,
    height: 1.15,
    color: StageColors.phos,
  );
}
