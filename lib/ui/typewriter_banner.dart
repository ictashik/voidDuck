import 'dart:async';

import 'package:flutter/material.dart';

import '../tuning/tuning.dart';

/// Zones 2-4 of the four-zone layout (spec Section 3): the pixel-font
/// banner. Centered, wraps to multiple lines rather than truncating or
/// scrolling — for the short ambient/gesture quip, which always fits.  New
/// text types on one character at a time; once fully typed a trailing
/// cursor blinks in place and the line just sits there until the next
/// reaction replaces it.
///
/// [longForm] (spec Section 4.4, the voice trigger's ~100-word reply) is a
/// distinct, longer response mode from the short quip — long enough to
/// overflow this zone's height at the short form's centered/no-scroll
/// layout, so this switches to left-aligned text inside a scroll view that
/// auto-follows the reveal as it types, instead of trying to shrink a
/// paragraph down to one screen's worth of pixel font.
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

class _TypewriterBannerState extends State<TypewriterBanner> {
  Timer? _revealTimer;
  Timer? _blinkTimer;
  int _visibleChars = 0;
  bool _cursorOn = true;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _startReveal();
  }

  void _followScroll() {
    if (!widget.longForm || !_scrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
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
    _revealTimer?.cancel();
    _blinkTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _startReveal() {
    _revealTimer?.cancel();
    _blinkTimer?.cancel();
    _visibleChars = 0;
    _cursorOn = true;
    if (widget.text.isEmpty) {
      setState(() {});
      return;
    }
    final charsPerSecond =
        Tuning.get('banner_reveal_chars_per_s').clamp(1.0, 60.0);
    final stepMs = (1000 / charsPerSecond).round().clamp(10, 1000);
    _revealTimer = Timer.periodic(Duration(milliseconds: stepMs), (timer) {
      setState(() => _visibleChars++);
      _followScroll();
      if (_visibleChars >= widget.text.length) {
        timer.cancel();
        _startBlink();
      }
    });
    setState(() {});
  }

  void _startBlink() {
    final blinkMs = Tuning.get('banner_cursor_blink_ms').round().clamp(100, 2000);
    _blinkTimer = Timer.periodic(Duration(milliseconds: blinkMs), (_) {
      setState(() => _cursorOn = !_cursorOn);
    });
  }

  @override
  Widget build(BuildContext context) {
    final full = widget.text;
    if (full.isEmpty) return const SizedBox.shrink();

    final shown = full.substring(0, _visibleChars.clamp(0, full.length));
    final revealDone = _visibleChars >= full.length;

    final richText = RichText(
      textAlign: widget.longForm ? TextAlign.left : TextAlign.center,
      text: TextSpan(
        style: widget.style,
        children: [
          TextSpan(text: shown),
          if (revealDone)
            TextSpan(
              text: '_',
              style: widget.style.copyWith(
                color: _cursorOn
                    ? widget.style.color
                    : widget.style.color?.withValues(alpha: 0),
              ),
            ),
        ],
      ),
    );

    if (!widget.longForm) {
      return Center(child: richText);
    }
    // Long-form (voice reply): left-aligned paragraph in a scroll view that
    // auto-follows the reveal, since a ~100-word reply routinely overflows
    // this zone's height at a size anyone could actually read.
    return SingleChildScrollView(
      controller: _scrollController,
      child: Align(alignment: Alignment.topLeft, child: richText),
    );
  }
}
