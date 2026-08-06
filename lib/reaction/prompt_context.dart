import 'dart:math';

import 'conversation_turn.dart';

/// Builds the Reaction Engine's system prompt for real triggers (spec
/// "What alive means now"). Circadian mood, no-repeat context, and rare
/// events all live here as prompt text rather than procedural animation —
/// the model calibrates tone itself instead of us hand-coding tiers.
class PromptContext {
  PromptContext._();

  static final Random _rng = Random();

  static const _persona =
      'You are a small offline desk companion with a screen for a face. '
      'React briefly to what you actually notice in the camera image: one '
      'emoji and a short line of text, under 100 characters. If the image '
      'shows handwritten or printed text held up to the camera, read and '
      'respond to that instead of describing the general scene.';

  /// Time-of-day tone bias (CLAUDE.md: "cheap, still fits, no procedural
  /// animation required"). Uses the device's local clock.
  static String _circadianMood([DateTime? now]) {
    final hour = (now ?? DateTime.now()).hour;
    if (hour >= 0 && hour < 5) {
      return 'It is the middle of the night. Sound groggy and low-energy, '
          'maybe a little put out at being looked at right now.';
    } else if (hour < 9) {
      return 'It is early morning. Sound sleepy but brightening up, like '
          "you're still waking up too.";
    } else if (hour < 17) {
      return 'It is the middle of the day. Sound alert and a bit '
          'energetic.';
    } else if (hour < 22) {
      return 'It is evening. Sound relaxed and easygoing, winding down.';
    }
    return 'It is late at night. Sound tired, keep it low-key.';
  }

  /// What's actually invoking this call, spelled out so the model doesn't
  /// have to guess from the image alone. Grounding this explicitly is what
  /// fixed the gesture trigger reading as "someone waved hello" — an open
  /// palm toward a camera is visually ambiguous between "hi" and "look at
  /// this", and only the *trigger* disambiguates it, not the pixels.
  static String _triggerExplainer(String trigger) {
    switch (trigger) {
      case 'gesture':
        return 'You were invoked because an automatic hand-gesture '
            'detector saw a deliberate Victory (peace-sign) gesture aimed '
            'at the camera, held steady for about a second.';
      case 'ambient':
      default:
        return 'You were invoked by a periodic timer that fires every so '
            'often while someone is present at the desk — a routine '
            '"notice something" check, not triggered by anything the '
            'person did.';
    }
  }

  /// This device sits mounted on a desk, pointed at someone who is almost
  /// always working at a computer when the ambient tick fires. Without this,
  /// "person looking at a screen" reads as a novel observation every time;
  /// with it, the model can skip past the obvious and go for something with
  /// actual personality.
  static const _deskContext =
      "This sits on a desk aimed at someone who is almost certainly working "
      "at a computer right now. Most of what you see will just be them "
      "looking at a monitor, typing, thinking, slouching, looking tired or "
      "focused — that's the normal state of affairs, not something worth "
      "remarking on flatly. Have some personality about it — dry, funny, "
      "observational — rather than just describing what's in frame.";

  static String _breakNudge(int lapMinutes) {
    if (lapMinutes < 30) return '';
    return "\n\nThey've been at this for over half an hour straight without "
        'a break. If it fits naturally, gently nudge them to stretch or '
        "step away for a moment — don't be nagging or make it a big deal, "
        'just a passing suggestion at most.';
  }

  /// Their name is threaded through as light-touch context, not a mandate
  /// — forcing it into every line reads as robotic fast.
  static String _nameLine(String name) {
    return "Their name is $name. You can use it occasionally, especially "
        "when greeting them, but don't force it into every single line.";
  }

  static String _sessionContext({
    required double lapSeconds,
    required double totalSeconds,
  }) {
    final lapMin = (lapSeconds / 60).round();
    final totalMin = (totalSeconds / 60).round();
    return "They've been at the desk for about $lapMin minute"
        "${lapMin == 1 ? '' : 's'} this session; $totalMin minute"
        '${totalMin == 1 ? '' : 's'} at the desk so far today.';
  }

  static String _noRepeat(List<String> recentTexts) {
    if (recentTexts.isEmpty) return '';
    final lines = recentTexts.map((t) => '- "$t"').join('\n');
    return '\n\nDo not repeat these recent lines, in wording or in idea:\n'
        '$lines';
  }

  /// True roughly 1-in-300 ambient ticks (spec: "creates folklore" — same
  /// rationale as the retired rare-events system, now just a prompt swap).
  static bool rollRareEvent() => _rng.nextInt(300) == 0;

  static const _rareEventFraming =
      "This is a rare moment — say something a little stranger, funnier, or "
      "more philosophical than your usual one-liner, as if something about "
      "right now briefly struck you as odd.";

  /// Renders the shared gesture/voice history (spec Section 4.4) as an
  /// actual chat-style transcript — oldest turn first, both sides labeled —
  /// rather than the flat "you already said these things" list of just the
  /// assistant's own past replies this used to be. Without the user's side
  /// of each turn, a follow-up reply had nothing to anchor "this" or "that"
  /// against; with it, the model can actually track what it's continuing.
  static String _transcriptBlock(List<ConversationTurn> history) {
    if (history.isEmpty) return '';
    final lines = history.map((t) => t.line).join('\n');
    return '\n\nHere is the conversation so far, oldest first:\n$lines\n'
        'Treat what comes next as the next turn in this same conversation, '
        'not a first encounter.';
  }

  /// Framing for the deliberate `Victory` gesture trigger (spec Section
  /// 4.2.3, "the debugging listen" carried forward from earlier versions;
  /// this used to be `Open_Palm` — that gesture now starts the voice-
  /// recording flow instead, see [forVoice]): someone held up a peace sign —
  /// and probably something along with it — on purpose. The critical
  /// disambiguation (not a wave/greeting) is deliberately the *last* thing
  /// before the tool-call instruction gets appended in reaction_engine.dart,
  /// not folded in earlier alongside circadian/session filler — a small
  /// model weights instructions closest to the generation point most
  /// heavily, and putting it early got ignored in practice.
  ///
  /// [conversationHistory] is the shared gesture/voice transcript (spec
  /// Section 4.4) — for this trigger's own turns specifically, the "user"
  /// side is still a placeholder rather than real captured text (nothing
  /// OCRs the image), but voice turns interleaved in the same history do
  /// carry a real transcript, and either way the model gets the actual
  /// back-and-forth instead of just its own past lines.
  static String forGesture({
    required String name,
    required double lapSeconds,
    required double totalSeconds,
    required List<String> recentTexts,
    List<ConversationTurn> conversationHistory = const [],
  }) {
    final continuation = _transcriptBlock(conversationHistory);
    return '$_persona\n\n${_triggerExplainer('gesture')} ${_nameLine(name)}'
        '\n\n${_circadianMood()} ${_sessionContext(lapSeconds: lapSeconds, totalSeconds: totalSeconds)}'
        '${_noRepeat(recentTexts)}'
        '$continuation'
        '\n\nIMPORTANT: do not say hello, do not mention the peace sign or '
        'the hand at all — this is not a greeting. Look past the hand: '
        "react to whatever is next to it, behind it, or held alongside it "
        "(their face, the desk, an object, a note). If nothing else is "
        "visible, react to the desk scene around them instead of the "
        "hand.\n\n"
        "If they are holding up something with actual writing on it — a "
        "note, a whiteboard, a question — READ it and give a real, direct "
        "answer to what it actually asks or says. Never just describe that "
        'writing is present (do not say things like "question on screen" '
        'or "a note is visible" — that is not a reaction, it is a refusal '
        "to engage). Someone is standing there waiting on this, so keep it "
        "short, but answering for real matters more than being brief — "
        "aim for well under 60 characters.";
  }

  /// Framing for the `Open_Palm` voice-recording trigger (spec Section 4.4):
  /// someone deliberately sat through a 3-2-1 countdown and spoke, so
  /// [transcript] is a real, literal record of what they said — the first
  /// trigger where that's true (every other trigger only ever had the
  /// image to go on). Deliberately doesn't reuse [_persona]'s "under 100
  /// characters" framing: this is the one call where a longer, real answer
  /// is the point, not a quip.
  ///
  /// [conversationHistory] is the same shared transcript [forGesture] reads/
  /// writes — spoken and image-triggered turns interleave in one ongoing
  /// exchange rather than being tracked separately, since the human can
  /// switch modalities mid-conversation.
  static String forVoice({
    required String name,
    required double lapSeconds,
    required double totalSeconds,
    required List<String> recentTexts,
    required String transcript,
    List<ConversationTurn> conversationHistory = const [],
  }) {
    final continuation = _transcriptBlock(conversationHistory);
    return 'You are a small offline desk companion with a screen for a '
        'face. The person just spoke to you directly, on purpose — they '
        'held up an open palm, waited through a countdown, and said '
        'something real, not a passing glance at the camera. '
        '${_nameLine(name)}'
        '\n\n${_circadianMood()} ${_sessionContext(lapSeconds: lapSeconds, totalSeconds: totalSeconds)}'
        '${_noRepeat(recentTexts)}'
        '$continuation'
        '\n\nWhat they said (transcribed on-device from their voice; it may '
        'contain small transcription errors, so use your best judgment '
        'about what they likely meant): "$transcript"'
        '\n\nIf the transcript is empty, garbled, or clearly not real '
        'words, say so honestly and briefly rather than inventing an '
        "answer to a question they didn't actually ask. Otherwise, "
        'respond to them directly and conversationally, like you\'re '
        'actually talking with them right now. This reply can be longer '
        'than your usual one-liner — a real, substantive answer, up to '
        'about 100 words, not just a quip.';
  }

  /// Framing for the periodic ambient tick during `Tracking`.
  static String forAmbient({
    required String name,
    required double lapSeconds,
    required double totalSeconds,
    required List<String> recentTexts,
    bool rareEvent = false,
  }) {
    final lapMinutes = (lapSeconds / 60).round();
    final framing = rareEvent ? _rareEventFraming : _deskContext;
    return '$_persona\n\n${_triggerExplainer('ambient')} ${_nameLine(name)}'
        '\n\n${_circadianMood()} ${_sessionContext(lapSeconds: lapSeconds, totalSeconds: totalSeconds)}'
        '\n\n$framing'
        '${_breakNudge(lapMinutes)}'
        '${_noRepeat(recentTexts)}';
  }
}
