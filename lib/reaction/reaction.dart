/// The Reaction Engine's output (spec Section 4.1): a required
/// `{emoji, text}` pair, never free text. `text` is capped at ~100
/// characters by the prompt; nothing here re-enforces that length since the
/// model call itself is the enforcement point (structured/function-calling
/// output), not a Dart-side truncation.
class Reaction {
  final String emoji;
  final String text;

  /// True for the voice-trigger's reply (spec Section 4.4): a distinct,
  /// longer response mode (~100 words, prompt-capped like the short form)
  /// rather than the ambient/gesture one-liner. Purely a rendering hint —
  /// [TypewriterBanner] uses it to switch to a smaller, scrollable layout
  /// instead of the centered single-block one short quips get.
  final bool longForm;

  const Reaction({required this.emoji, required this.text, this.longForm = false});

  /// Shown whenever a call throws, times out, or returns something that
  /// doesn't fit the schema — CLAUDE.md non-negotiable #8: never a blank or
  /// error state, always *something* on screen.
  static const fallback = Reaction(emoji: '\u{1F300}', text: ''); // 🌀

  /// Fixed Sleeping-state emoji (spec Section 4.3): no text, no engine call.
  static const sleeping = Reaction(emoji: '\u{1F634}', text: ''); // 😴

  /// Shown before the first real reaction has ever fired (app just booted,
  /// no trigger has run yet). Distinct from both [fallback] and [sleeping] so
  /// the debug overlay/human can tell the three states apart at a glance.
  static const idle = Reaction(emoji: '\u{1F440}', text: ''); // 👀

  /// Cold-boot greeting — shown at app start, before any trigger has run.
  /// Static by explicit request: an LLM call here would mean waiting on the
  /// model just to say hello on launch, which isn't worth it.
  factory Reaction.bootGreeting(String name) {
    return Reaction(emoji: '\u{1F44B}', text: 'Welcome back, $name!'); // 👋
  }

  /// Return-from-absence greeting — replaces the old LLM-driven `Waking`
  /// trigger entirely (spec amendment): a human found the ~20-30s wait for
  /// an LLM-calibrated greeting not worth it for the common case of just
  /// sitting back down. Deterministic, instant, no camera frame or model
  /// call involved at all.
  factory Reaction.backFromBreak({
    required String name,
    required double absenceSeconds,
  }) {
    return Reaction(
      emoji: '\u{1F44B}', // 👋
      text: '$name is back! After a ${_formatBreak(absenceSeconds)} break.',
    );
  }

  static String _formatBreak(double seconds) {
    if (seconds < 60) {
      final s = seconds.round().clamp(1, 59);
      return '$s-second';
    } else if (seconds < 3600) {
      final m = (seconds / 60).round().clamp(1, 59);
      return '$m-minute';
    } else {
      final h = (seconds / 3600).round().clamp(1, 999);
      return '$h-hour';
    }
  }
}
