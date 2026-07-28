import 'package:flutter/material.dart';

/// A permission gate UI shown when the camera hasn't been granted yet. The
/// human taps the button; we call back into the app to request the permission.
/// We deliberately do NOT show a camera preview here — rendering the preview
/// is forbidden (non-negotiable #3), even during the grant flow.
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
          const Icon(Icons.camera_front_outlined,
              size: 36, color: Color(0x55FFFFFF)),
          const SizedBox(height: 12),
          const Text(
            'I need to see you.',
            style: TextStyle(color: Color(0xCCFFFFFF), fontSize: 14),
          ),
          const SizedBox(height: 4),
          const Text(
            'Camera stays off-screen. Nothing leaves the device.',
            style: TextStyle(color: Color(0x44FFFFFF), fontSize: 11),
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: onGrant,
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xCCFFFFFF),
              side: const BorderSide(color: Color(0x44FFFFFF)),
            ),
            child: const Text('Grant camera'),
          ),
          if (errorText != null) ...[
            const SizedBox(height: 12),
            Text(
              errorText!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0x99FF8888), fontSize: 10),
            ),
          ],
        ],
      ),
    );
  }
}