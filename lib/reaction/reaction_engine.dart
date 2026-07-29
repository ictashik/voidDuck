import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';

import '../debug/debug_bus.dart';
import 'reaction.dart';

/// One row of the debug overlay's "last 5 Reaction Engine calls" log
/// (CLAUDE.md "Debug overlay" section).
class ReactionCallLog {
  final DateTime at;
  final String trigger;
  final Reaction reaction;
  final int latencyMs;
  final bool valid;
  final String? error;

  // Sub-timings within latencyMs. Not a true prefill/decode split — flutter_
  // gemma's generateChatResponse() is one blocking native call, atomic from
  // our side, so prefill-of-the-new-content and decode can't be separated
  // without switching to its streaming API (generateChatResponseAsync),
  // which has an unverified interaction with Gemma 4's SDK-parsed tool-call
  // path (see reaction_engine.dart's react() comments) — not worth risking
  // on a working integration just for instrumentation. This split answers
  // the question we actually needed answered: how much of the latency is
  // session/system-prompt setup vs. the image+generation call itself.
  final int sessionInitMs;
  final int addQueryMs;
  final int generateMs;

  const ReactionCallLog({
    required this.at,
    required this.trigger,
    required this.reaction,
    required this.latencyMs,
    required this.valid,
    required this.sessionInitMs,
    required this.addQueryMs,
    required this.generateMs,
    this.error,
  });

  String get line {
    final ts = '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}:'
        '${at.second.toString().padLeft(2, '0')}';
    final status = valid ? 'ok' : 'FALLBACK${error != null ? ": $error" : ""}';
    return '$ts $trigger -> ${reaction.emoji} "${reaction.text}" '
        '(${latencyMs}ms [init ${sessionInitMs}ms/query ${addQueryMs}ms/'
        'gen ${generateMs}ms], $status)';
  }
}

/// The on-device vision call from spec Section 4.1: one Gemma 4 E2B call per
/// trigger (`Waking` / ambient tick / gesture — wired in later stages; a
/// manual debug-overlay button exercises the same path today, per the stage-3
/// build-order step of proving this plumbing before touching triggers).
///
/// The `{emoji, text}` shape is enforced at the model-call level via
/// function-calling with `ToolChoice.required` — a single `react` tool the
/// model must call — rather than hoped for from the prompt. A throw, a
/// non-function-call response, or a malformed arguments map all resolve to
/// [Reaction.fallback]: this method never throws and never returns null, so
/// there's always something to show (CLAUDE.md non-negotiable #8).
class ReactionEngine {
  ReactionEngine._();
  static final ReactionEngine instance = ReactionEngine._();

  /// Must match the asset entry in pubspec.yaml and the bundled file in
  /// assets/models/. Bundled, never downloaded (CLAUDE.md non-negotiable #7).
  static const _modelAsset = 'models/gemma-4-E2B-it.litertlm';

  static const _reactTool = Tool(
    name: 'react',
    description:
        'Report a reaction to what you notice: one emoji and a short line '
        'of text.',
    parameters: {
      'type': 'object',
      'properties': {
        'emoji': {
          'type': 'string',
          'description': 'A single Unicode emoji capturing the reaction.',
        },
        'text': {
          'type': 'string',
          'description':
              'A short reaction to what you see, under 100 characters.',
        },
      },
      'required': ['emoji', 'text'],
    },
  );

  /// Long-form counterpart for the voice trigger (spec Section 4.4) — same
  /// tool name and shape so [_parse] needs no branching, just a longer,
  /// prompt-enforced (not schema-enforced, same as the short form) length
  /// ceiling in the `text` field's description.
  static const _voiceReplyTool = Tool(
    name: 'react',
    description: 'Report your reply to what they just said: one emoji and '
        'your response text.',
    parameters: {
      'type': 'object',
      'properties': {
        'emoji': {
          'type': 'string',
          'description': 'A single Unicode emoji capturing the reply.',
        },
        'text': {
          'type': 'string',
          'description':
              'Your conversational reply to what they said, up to about '
              '100 words.',
        },
      },
      'required': ['emoji', 'text'],
    },
  );

  bool _engineRegistered = false;
  InferenceModel? _model;
  Future<InferenceModel>? _modelLoading;

  final List<ReactionCallLog> _log = [];
  List<ReactionCallLog> get log => List.unmodifiable(_log);

  /// True once a model call has completed (success or fallback) at least
  /// once — lets the UI distinguish "never triggered yet" from "triggered
  /// and this is the result".
  bool get hasRun => _log.isNotEmpty;

  /// Loads and registers the bundled model exactly once; every call after
  /// the first reuses the resident model (a 2.4GB asset is far too slow to
  /// reload per trigger — this device stays plugged in and the model is
  /// meant to stay resident for the app's lifetime).
  Future<InferenceModel> _ensureModel() {
    final existing = _model;
    if (existing != null) return Future.value(existing);
    return _modelLoading ??= _load();
  }

  Future<InferenceModel> _load() async {
    if (!_engineRegistered) {
      await FlutterGemma.initialize(
        inferenceEngines: const [LiteRtLmEngine()],
      );
      _engineRegistered = true;
    }
    await FlutterGemma.installModel(
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
    ).fromAsset(_modelAsset).install();
    final model = await FlutterGemma.getActiveModel(
      maxTokens: 4096,
      preferredBackend: PreferredBackend.gpu,
      supportImage: true,
      maxNumImages: 1,
    );
    _model = model;
    // GPU is requested but engines may fall back silently (see
    // InferenceModel.activeBackend's doc comment) — surface what actually
    // got used so a slow call reads as "CPU fallback" rather than a mystery.
    DebugBus.instance.put(
      'ReactionBackend',
      model.activeBackend?.name ?? 'unknown',
    );
    return model;
  }

  /// Runs one reaction call.
  ///
  /// [trigger] is a short label for the debug log ("Waking" / "ambient" /
  /// "gesture" / "test") — display only, never branches behavior.
  /// [systemPrompt] carries the scene-vs-handwritten-note framing plus any
  /// circadian/absence/no-repeat context (spec Section 4.1/"What alive
  /// means now"); this method stays a dumb pipe around whatever prompt it's
  /// given.
  /// [maxOutputTokens] is a hard decode-length cap — the gesture trigger
  /// passes a much lower value than the default, since that's the one case
  /// where someone is standing there waiting on the reply and decode time
  /// (serial, one token at a time) is the dominant, most controllable cost.
  /// [userMessageText] replaces the generic "React to this." user turn —
  /// the voice trigger passes the actual transcript here, so the model sees
  /// it as what-they-said rather than buried scene-setting in the system
  /// prompt. [longForm] swaps in [_voiceReplyTool]'s ~100-word ceiling
  /// instead of the ambient/gesture one-liner's.
  Future<Reaction> react({
    required String trigger,
    required Uint8List imageBytes,
    required String systemPrompt,
    String? userMessageText,
    bool longForm = false,
    int maxOutputTokens = 200,
  }) async {
    final tool = longForm ? _voiceReplyTool : _reactTool;
    final stopwatch = Stopwatch()..start();
    var sessionInitMs = 0;
    var addQueryMs = 0;
    var generateMs = 0;
    try {
      final model = await _ensureModel();
      // ToolChoice.required is Dart-side only: neither createSession() nor
      // openSession() even accepts a toolChoice parameter, so nothing forces
      // the model at the native/decoding level to actually invoke the tool
      // — it's declared and available, but calling it is still the model's
      // own choice (confirmed by hitting exactly this: a real, on-topic
      // plain-text answer instead of a react() call). The only lever left
      // is an explicit instruction in the prompt itself.
      final effectiveSystemPrompt = '$systemPrompt\n\n'
          'You must respond by calling the react tool exactly once, with '
          'your emoji and text as its arguments. Never respond in plain '
          'text, and never call any other tool.';
      // Neither of flutter_gemma's two convenience paths works for us as-is:
      // - model.createChat()'s sessionCreator forwards temperature/topK/
      //   systemInstruction/etc. to createSession() but drops `tools`
      //   entirely, so the model never learns the `react` tool exists.
      // - model.openChat() forwards `tools` correctly, but its openSession()
      //   is a *concurrent* session, and the litertlm engine explicitly
      //   rejects image input there ("Image/audio input is not supported on
      //   concurrent (openSession) .litertlm sessions" — confirmed by
      //   hitting that exact exception).
      // So: build the InferenceChat wrapper by hand around model.
      // createSession() (the legacy singleton slot, which supports both
      // images and tools), passing `tools` ourselves. This is exactly what
      // createChat() should be doing internally.
      final chat = InferenceChat(
        sessionCreator: () => model.createSession(
          temperature: 1.0,
          topK: 64,
          topP: 0.95,
          enableVisionModality: true,
          tools: [tool],
          maxOutputTokens: maxOutputTokens,
          systemInstruction: effectiveSystemPrompt,
        ),
        maxTokens: model.maxTokens,
        supportImage: true,
        supportsFunctionCalls: true,
        tools: [tool],
        modelType: ModelType.gemma4,
        fileType: ModelFileType.litertlm,
        toolChoice: ToolChoice.required,
      );
      final sessionStopwatch = Stopwatch()..start();
      await chat.initSession();
      sessionInitMs = sessionStopwatch.elapsedMilliseconds;
      // Not closing the session manually here: it lives in model.session
      // (the "legacy singleton slot"), and the next createSession() call —
      // whenever the next trigger fires — auto-closes whatever's there
      // first. Closing it ourselves too would risk a double-close on
      // whatever that teardown does natively.
      final queryStopwatch = Stopwatch()..start();
      await chat.addQueryChunk(Message.withImage(
        text: userMessageText ?? 'React to this.',
        imageBytes: imageBytes,
        isUser: true,
      ));
      addQueryMs = queryStopwatch.elapsedMilliseconds;
      final generateStopwatch = Stopwatch()..start();
      final response = await chat.generateChatResponse();
      generateMs = generateStopwatch.elapsedMilliseconds;
      stopwatch.stop();

      final parsed = _parse(response);
      _record(
        trigger: trigger,
        reaction: parsed ?? Reaction.fallback,
        latencyMs: stopwatch.elapsedMilliseconds,
        valid: parsed != null,
        sessionInitMs: sessionInitMs,
        addQueryMs: addQueryMs,
        generateMs: generateMs,
        error: parsed == null ? _describeUnparsed(response) : null,
      );
      return parsed ?? Reaction.fallback;
    } catch (e) {
      stopwatch.stop();
      _record(
        trigger: trigger,
        reaction: Reaction.fallback,
        latencyMs: stopwatch.elapsedMilliseconds,
        valid: false,
        sessionInitMs: sessionInitMs,
        addQueryMs: addQueryMs,
        generateMs: generateMs,
        error: e.toString(),
      );
      return Reaction.fallback;
    }
  }

  Reaction? _parse(ModelResponse response) {
    if (response is! FunctionCallResponse || response.name != 'react') {
      return null;
    }
    final emoji = response.args['emoji'];
    final text = response.args['text'];
    if (emoji is! String || emoji.trim().isEmpty || text is! String) {
      return null;
    }
    return Reaction(emoji: emoji.trim(), text: text.trim());
  }

  /// Describes *why* a response didn't parse, for the debug overlay's
  /// FALLBACK log line — a bare "FALLBACK" with no context is exactly the
  /// kind of mystery CLAUDE.md says to instrument rather than guess at.
  String _describeUnparsed(ModelResponse response) {
    return switch (response) {
      TextResponse(:final token) =>
        'model returned plain text instead of calling react(): '
            '"${token.length > 80 ? '${token.substring(0, 80)}…' : token}"',
      FunctionCallResponse(:final name) =>
        'model called unexpected tool "$name" instead of react()',
      ParallelFunctionCallResponse(:final calls) =>
        'model called ${calls.length} tools in parallel instead of one react()',
      ThinkingResponse() => 'model returned only a thinking block, no reaction',
    };
  }

  void _record({
    required String trigger,
    required Reaction reaction,
    required int latencyMs,
    required bool valid,
    required int sessionInitMs,
    required int addQueryMs,
    required int generateMs,
    String? error,
  }) {
    final entry = ReactionCallLog(
      at: DateTime.now(),
      trigger: trigger,
      reaction: reaction,
      latencyMs: latencyMs,
      valid: valid,
      sessionInitMs: sessionInitMs,
      addQueryMs: addQueryMs,
      generateMs: generateMs,
      error: error,
    );
    _log.insert(0, entry);
    if (_log.length > 5) _log.removeLast();
    DebugBus.instance.put(
      'ReactionLog',
      _log.map((e) => e.line).join('\n'),
    );
  }
}
