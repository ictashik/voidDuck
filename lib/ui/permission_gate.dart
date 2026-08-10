import 'package:flutter/material.dart';

import 'stage_theme.dart';

/// A permission gate UI shown when the camera hasn't been granted yet. The
/// human taps the button; we call back into the app to request the permission.
/// We deliberately do NOT show a camera preview here — rendering the preview
/// is forbidden (non-negotiable #3), even during the grant flow.
///
/// v0.14 restyle: terminal-styled — a hazard-red `[ SENSOR ACCESS REQUIRED ]`
/// frame, mono readouts, hard 90° corners throughout.
class PermissionGate extends StatelessWidget {
  final VoidCallback onGrant;
  final String? errorText;

  const PermissionGate({
    super.key,
    required this.onGrant,
    this.errorText,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              border: Border.all(color: StageColors.hazard),
              borderRadius: BorderRadius.zero,
            ),
            child: const Text(
              'SENSOR ACCESS REQUIRED',
              style: TextStyle(
                fontFamily: StageText.mono,
                fontSize: 11,
                letterSpacing: 0.22,
                fontWeight: FontWeight.w600,
                color: StageColors.hazard,
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'I need to see you.',
            style: TextStyle(
              fontFamily: StageText.mono,
              fontSize: 18,
              letterSpacing: 1,
              fontWeight: FontWeight.w700,
              color: StageColors.phos,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'CAMERA STAYS OFF-SCREEN · NOTHING LEAVES THE DEVICE',
            style: TextStyle(
              fontFamily: StageText.mono,
              fontSize: 10.5,
              letterSpacing: 0.16,
              color: StageColors.phosMute,
            ),
          ),
          const SizedBox(height: 20),
          OutlinedButton(
            onPressed: onGrant,
            style: OutlinedButton.styleFrom(
              foregroundColor: StageColors.phos,
              side: const BorderSide(color: StageColors.phosSoft),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.zero,
              ),
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
            ),
            child: const Text(
              'GRANT CAMERA',
              style: TextStyle(
                fontFamily: StageText.mono,
                fontSize: 11,
                letterSpacing: 0.22,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (errorText != null) ...[
            const SizedBox(height: 12),
            Text(
              errorText!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: StageText.mono,
                fontSize: 10.5,
                color: StageColors.hazard,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
