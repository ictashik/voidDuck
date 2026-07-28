import 'dart:async';

import 'package:flutter/material.dart';

import '../debug/debug_bus.dart';
import 'tuning_panel.dart';

/// Skeleton debug overlay required by every build (CLAUDE.md "Debug overlay").
///
/// Toggled by triple-tapping the top-left corner. Semi-transparent, small,
/// dismissible. Every field listed in CLAUDE.md has a row here; stages that
/// have not been wired yet show "—". When a stage starts producing a value it
/// just calls `DebugBus.instance.put(key, value)` and the row lights up here —
/// no overlay edits needed.
///
/// This is the human's only window into why something looks wrong, so it lives
/// in every build from scaffold onward.
class DebugOverlay extends StatefulWidget {
  final Widget child;

  const DebugOverlay({super.key, required this.child});

  @override
  State<DebugOverlay> createState() => _DebugOverlayState();
}

class _DebugOverlayState extends State<DebugOverlay> {
  bool _open = false;
  int _taps = 0;
  Timer? _resetTimer;
  int _tab = 0; // 0 = Debug, 1 = Tuning

  static const double _tapZone = 64.0;
  static const Duration _multiTapWindow = Duration(milliseconds: 500);
  static const TextStyle _kLabel = TextStyle(
    color: Color(0xCCFFFFFF),
    fontSize: 10,
    height: 1.15,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  void _handleTap() {
    _taps++;
    _resetTimer?.cancel();
    _resetTimer = Timer(_multiTapWindow, () => _taps = 0);
    if (_taps >= 3) {
      _taps = 0;
      _resetTimer?.cancel();
      setState(() => _open = !_open);
    }
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        // Invisible triple-tap hot zone in the top-left corner.
        Positioned(
          left: 0,
          top: 0,
          width: _tapZone,
          height: _tapZone,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _handleTap,
          ),
        ),
        if (_open) _buildPanel(context),
      ],
    );
  }

  Widget _buildPanel(BuildContext context) {
    final width = _tab == 0 ? 280.0 : 340.0;
    final maxH = MediaQuery.of(context).size.height * 0.8;
    return Positioned(
      left: 8,
      top: 8,
      width: width,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Material(
          color: const Color(0x80000000),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    _tabButton(0, 'DEBUG'),
                    const SizedBox(width: 8),
                    _tabButton(1, 'TUNING'),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => setState(() => _open = false),
                      child: const Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(Icons.close, size: 12, color: Color(0xCCFFFFFF)),
                      ),
                    ),
                  ],
                ),
                const Divider(height: 6, color: Color(0x44FFFFFF)),
                Flexible(
                  child: _tab == 0
                      ? AnimatedBuilder(
                          animation: DebugBus.instance,
                          builder: (context, _) => SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: _sections(),
                            ),
                          ),
                        )
                      : const SingleChildScrollView(child: TuningPanel()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tabButton(int i, String label) {
    final active = _tab == i;
    return GestureDetector(
      onTap: () => setState(() => _tab = i),
      child: Text(
        label,
        style: TextStyle(
          color: active ? const Color(0xFFFFFFFF) : const Color(0x66FFFFFF),
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  List<Widget> _sections() {
    // The keys mirror the required overlay fields from CLAUDE.md. Stages fill
    // these in as they come online; until then we show "—".
    return [
      _section('PetState', [
        _row('PetState', 'PetState'),
        _row('Seconds in state', 'StateSeconds'),
        _row('Face lock', 'FaceLock'),
      ]),
      _section('ML Kit (raw)', [
        _row('Face center', 'FaceCenter'),
        _row('Face size', 'FaceSize'),
        _row('Head euler Z', 'HeadEulerZ'),
        _row('Smiling prob', 'SmilingProb'),
        _row('Left eye open', 'LeftEyeOpen'),
        _row('Right eye open', 'RightEyeOpen'),
      ]),
      _section('Gaze', [
        _row('LookX smooth / raw', 'LookX'),
        _row('LookY smooth / raw', 'LookY'),
      ]),
      _section('Camera', [
        _row('Lens', 'CameraLens'),
        _row('Achieved fps', 'AchievedFps'),
        _row('Target fps', 'TargetFps'),
      ]),
      _section('Display', [
        _row('Brightness', 'Brightness'),
      ]),
      _section('Renderer', [
        _row('Eyelid frame (L / R)', 'EyelidFrame'),
      ]),
      _section('Mind', [
        _row('Interest meter', 'Interest'),
        _row('Mood scalar', 'MoodScalar'),
      ]),
      _section('Anim log', [
        _row('Last 5 anims', 'AnimLog'),
      ]),
    ];
  }

  Widget _section(String title, List<Widget> rows) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              color: Color(0x99FFFFFF),
              fontSize: 9,
              letterSpacing: 1.0,
              fontWeight: FontWeight.w600,
            ),
          ),
          ...rows,
        ],
      ),
    );
  }

  Widget _row(String label, String key) {
    final v = DebugBus.instance.get(key);
    return Padding(
      padding: const EdgeInsets.only(top: 1),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(text: '$label: ', style: _kLabel),
            TextSpan(
              text: v == null ? '—' : v.toString(),
              style: _kLabel.copyWith(color: const Color(0xFFFFFFFF)),
            ),
          ],
        ),
      ),
    );
  }
}