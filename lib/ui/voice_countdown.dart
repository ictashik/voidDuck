import 'package:flutter/material.dart';

/// Full-stage 3-2-1 countdown shown right after Open_Palm fires, before
/// recording actually starts (spec Section 4.4). Deliberately replaces both
/// zones rather than sitting in a corner — the point is that it's
/// unmistakable something is about to happen, not a subtle cue.
class VoiceCountdown extends StatelessWidget {
  final int value;

  const VoiceCountdown({super.key, required this.value});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$value',
            style: const TextStyle(
              fontFamily: 'Silkscreen',
              fontWeight: FontWeight.w700,
              fontSize: 140,
              color: Color(0xFFCF5867),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'GET READY…',
            style: TextStyle(
              fontFamily: 'Silkscreen',
              fontWeight: FontWeight.w700,
              fontSize: 18,
              letterSpacing: 2,
              color: Color(0x99FFFFFF),
            ),
          ),
        ],
      ),
    );
  }
}
