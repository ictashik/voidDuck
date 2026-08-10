import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../tuning/tuning.dart';
import 'stage_theme.dart';

/// Zones 2-4 of the four-zone layout (spec Section 3): the banner. Rendered
/// in the stage's terminal mono (JetBrains Mono, v0.14 restyle) instead of
/// the old pixel font. Centered and wrapping for the short quip; left-aligned
/// auto-scrolling paragraph for long-form voice replies.
///
/// The reveal is a sci-fi flipboard (v0.15): a wave of characters locks in
/// left-to-right at the tuned reveal rate, while a window of characters
/// ahead of the wave streams as rapidly-re-randomized HAZARD-RED glyphs —
/// uncommitted data — each of which locks to phosphor white through a brief
/// flicker as the wave passes it. The whole line is subject to rare
/// horizontal tears, post-reveal ambient dims, and a red power-on garbage
/// burst when a new text arrives.
///
/// Two knobs control the character: `banner_flicker_intensity` (0 = plain
/// typewriter exactly as pre-restyle; 1 = max stream window, settle flicker,
/// tears/dims — default 0.7) and `banner_glitch_probability` (chance a
/// streaming slot shows a glitch block glyph instead of a letter). A single
/// [Timer] at a fixed cadence drives both the lock wave and the effects; the
/// tick drops to a slower idle cadence once the reveal completes.
class TypewriterBanner extends StatefulWidget {
  final String text;
  final TextStyle style;
  final bool longForm;

  const TypewriterBanner({
    super.key,
    required this.text,
    required this.style,
    this.longForm = false,
  });

  @override
  State<TypewriterBanner> createState() => _TypewriterBannerState();
}

/// A single in-flight settle flicker on a just-locked character. Only a
/// handful active at once (the most recently locked positions), so rendering
/// stays cheap even for long-form replies.
class _Flicker {
  final int index;
  int framesLeft;

  /// Red flash on lock instead of a white jitter — the last instant of
  /// "uncommitted" before the character goes phosphor.
  final bool redFlash;

  _Flicker(this.index, this.framesLeft, this.redFlash);
}

class _TypewriterBannerState extends State<TypewriterBanner> {
  static const int _revealTickMs = 24;
  static const int _idleTickMs = 120;
  static const String _streamGlyphs = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  static const String _ghostGlyphs = r'▓▒░#@%&/\<>*+=?$!';

  Timer? _tick;
  Timer? _blinkTimer;
  final Random _random = Random();
  final ScrollController _scrollController = ScrollController();

  double _revealAccum = 0;
  int _lockIndex = 0; // characters committed to phosphor white
  bool _cursorOn = true;
  bool _onIdleCadence = false;

  // CRT effect state.
  int _resyncFrames = 0; // red power-on garbage burst before the wave starts
  int _dipFrames = 0; // whole-line dim, post-reveal ambient flicker
  int _tearFrames = 0; // 1px horizontal double-draw
  final List<_Flicker> _settling = []; // just-locked chars still flickering

  @override
  void initState() {
    super.initState();
    _startReveal();
  }

  @override
  void didUpdateWidget(covariant TypewriterBanner old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      _startReveal();
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _blinkTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _startReveal() {
    _tick?.cancel();
    _blinkTimer?.cancel();
    _lockIndex = 0;
    _revealAccum = 0;
    _cursorOn = true;
    _onIdleCadence = false;
    _settling.clear();
    _tearFrames = 0;
    _dipFrames = 0;
    if (widget.text.isEmpty) {
      _resyncFrames = 0;
      setState(() {});
      return;
    }
    final intensity = Tuning.get('banner_flicker_intensity');
    // Power-on burst: brief red garbage-glyph flash before the wave draws.
    _resyncFrames = intensity > 0.01 ? 3 : 0;
    _tick = Timer.periodic(const Duration(milliseconds: _revealTickMs), (_) {
      _onTick();
    });
    setState(() {});
  }

  /// One effect-tick: advance the lock wave, roll the stochastic effects,
  /// and rebuild. Cheap mutations only — the stream glyph string is
  /// regenerated in build(), which is what makes it read as continuous
  /// flicker without any per-char state.
  void _onTick() {
    setState(() {
      final intensity = Tuning.get('banner_flicker_intensity');

      if (_resyncFrames > 0) {
        _resyncFrames--;
        return;
      }

      // Lock wave: accumulate fractional characters at the tuned rate.
      final cps = Tuning.get('banner_reveal_chars_per_s').clamp(1.0, 60.0);
      _revealAccum += cps * (_revealTickMs / 1000);
      final target = _revealAccum.floor().clamp(0, widget.text.length);
      while (_lockIndex < target) {
        if (intensity > 0.01) {
          // Settle flicker on lock; sometimes a last red flash first.
          final redFlash = _random.nextDouble() < 0.5 * intensity;
          _settling.add(
            _Flicker(_lockIndex, redFlash ? 2 : 1 + _random.nextInt(2),
                redFlash),
          );
        }
        _lockIndex++;
      }

      final done = _lockIndex >= widget.text.length && _settling.isEmpty;
      if (done) {
        // Idle cadence: only rare ambient dims/tears left to service.
        if (!_onIdleCadence) {
          _onIdleCadence = true;
          _tick!.cancel();
          _tick = Timer.periodic(const Duration(milliseconds: _idleTickMs),
              (_) => _onTick());
        }
        if (intensity > 0.01 && _random.nextDouble() < 0.02 * intensity) {
          _dipFrames = 1 + _random.nextInt(2);
        }
      } else {
        // Mid-reveal tears are rarer than post-reveal ones.
        if (intensity > 0.01 &&
            _random.nextDouble() < 0.006 * intensity) {
          _tearFrames = 1 + _random.nextInt(2);
        }
        _followScroll();
      }
      if (intensity > 0.01 && _random.nextDouble() < 0.008 * intensity) {
        _tearFrames = 1 + _random.nextInt(2);
      }
      if (_dipFrames > 0) _dipFrames--;
      if (_tearFrames > 0) _tearFrames--;
      for (final f in _settling) {
        f.framesLeft--;
      }
      _settling.removeWhere((f) => f.framesLeft <= 0);
    });
  }

  void _followScroll() {
    if (!widget.longForm || !_scrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  String _ghostGlyph() =>
      _ghostGlyphs[_random.nextInt(_ghostGlyphs.length)];

  /// One random streaming glyph: a letter/digit, or — with the glitch
  /// probability — a block glyph for chaos.
  String _streamGlyph() {
    if (_random.nextDouble() < Tuning.get('banner_glitch_probability')) {
      return _ghostGlyph();
    }
    return _streamGlyphs[_random.nextInt(_streamGlyphs.length)];
  }

  String _streamLine(int length) =>
      String.fromCharCodes(List.generate(length, (_) => _streamGlyph().codeUnitAt(0)));

  @override
  Widget build(BuildContext context) {
    final full = widget.text;
    if (full.isEmpty) return const SizedBox.shrink();

    final intensity = Tuning.get('banner_flicker_intensity');
    final lockCount = _lockIndex.clamp(0, full.length);
    final streamWindow =
        intensity > 0.01 ? (6 + 14 * intensity).round() : 0;
    final streamStart = lockCount;
    final streamEnd = (streamStart + streamWindow).clamp(0, full.length);
    final revealDone = lockCount >= full.length && _settling.isEmpty;

    final baseAlpha = _dipFrames > 0
        ? 0.55 + 0.2 * (intensity.clamp(0.0, 1.0))
        : 1.0;

    // Spans: locked prefix (split around the few settling chars) + the red
    // streaming window. Bounded span count regardless of text length.
    final spans = <TextSpan>[];
    var pos = 0;
    for (var i = 0; i < lockCount; i++) {
      final active = _settling.any((f) => f.index == i);
      if (!active) continue;
      if (pos < i) {
        spans.add(TextSpan(text: full.substring(pos, i), style: widget.style));
      }
      final f = _settling.firstWhere((e) => e.index == i);
      if (f.redFlash) {
        spans.add(TextSpan(
          text: full[i],
          style: widget.style.copyWith(color: StageColors.hazard),
        ));
      } else {
        final alpha = 0.25 + 0.75 * _random.nextDouble();
        spans.add(TextSpan(
          text: full[i],
          style: widget.style.copyWith(
            color: widget.style.color?.withValues(alpha: alpha),
          ),
        ));
      }
      pos = i + 1;
    }
    if (pos < lockCount) {
      spans.add(TextSpan(text: full.substring(pos, lockCount), style: widget.style));
    }
    if (streamStart < streamEnd) {
      spans.add(TextSpan(
        text: _streamLine(streamEnd - streamStart),
        style: widget.style.copyWith(
          color: StageColors.hazard.withValues(alpha: 0.85),
        ),
      ));
    }
    if (revealDone) {
      spans.add(TextSpan(
        text: '▌',
        style: widget.style.copyWith(
          color: _cursorOn
              ? widget.style.color
              : widget.style.color?.withValues(alpha: 0),
        ),
      ));
    }

    final richText = RichText(
      textAlign: widget.longForm ? TextAlign.left : TextAlign.center,
      text: TextSpan(
        style: widget.style,
        children: spans,
      ),
    );

    Widget content = richText;
    if (_dipFrames > 0) {
      content = Opacity(opacity: baseAlpha, child: content);
    }

    // Horizontal tear: the current line double-drawn, offset 1px at low
    // alpha, for a frame or two — a phosphor "signal wobble".
    Widget line = content;
    if (_tearFrames > 0) {
      line = Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 1,
            top: 0,
            child: Opacity(
              opacity: 0.3,
              child: IgnorePointer(child: content),
            ),
          ),
          content,
        ],
      );
    }

    if (_resyncFrames > 0) {
      final garbageLen = full.length.clamp(1, 48);
      final garbage = String.fromCharCodes(List.generate(
        garbageLen,
        (_) => _ghostGlyph().codeUnitAt(0),
      ));
      line = Opacity(
        opacity: 0.4 * _resyncFrames / 3,
        child: RichText(
          textAlign: widget.longForm ? TextAlign.left : TextAlign.center,
          text: TextSpan(
            style: widget.style.copyWith(color: StageColors.hazard),
            text: garbage,
          ),
        ),
      );
    }

    if (!widget.longForm) {
      return Center(child: line);
    }
    return SingleChildScrollView(
      controller: _scrollController,
      child: Align(alignment: Alignment.topLeft, child: line),
    );
  }
}
