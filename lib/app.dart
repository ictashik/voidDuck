import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'debug/debug_bus.dart';
import 'device/audio_recorder_service.dart';
import 'device/device_temp_service.dart';
import 'gesture/gesture_recognizer_service.dart';
import 'reaction/conversation_turn.dart';
import 'reaction/nv21_to_jpeg.dart';
import 'reaction/prompt_context.dart';
import 'reaction/reaction.dart';
import 'reaction/reaction_engine.dart';
import 'reaction/speech_recognizer_service.dart';
import 'reaction/test_image.dart';
import 'state/pet_state.dart';
import 'state/pet_state_controller.dart';
import 'tuning/tuning.dart';
import 'ui/ambient_countdown.dart';
import 'ui/debug_overlay.dart';
import 'ui/permission_gate.dart';
import 'ui/reaction_status_indicator.dart';
import 'ui/recording_indicator.dart';
import 'ui/typewriter_banner.dart';
import 'ui/voice_countdown.dart';
import 'vision/camera_service.dart';
import 'vision/face_tracker.dart';

/// Where the Open_Palm voice-recording flow currently is (spec Section 4.4)
/// — orthogonal to [PetState], same "separate small enum, not a 6th PetState
/// value" precedent as [ReactionPhase], since none of PetState's brightness/
/// fps/timeout logic needs to know about it. `replying` covers the whole
/// span from "transcript is ready" to "the reply actually landed" — without
/// it, the stage would fall back to whatever reaction was on screen before
/// this trigger for the several seconds the model takes to generate,
/// which reads as the flow having silently abandoned what was just said.
enum VoiceRecordingPhase { idle, countdown, recording, transcribing, replying }

class VoidDuckApp extends StatelessWidget {
  const VoidDuckApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VoidDuck',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Colors.black,
          surface: Colors.black,
          onSurface: Colors.white,
        ),
      ),
      home: const _Stage(),
    );
  }
}

class _Stage extends StatefulWidget {
  const _Stage();

  @override
  State<_Stage> createState() => _StageState();
}

enum _PermissionState { unknown, denied, granted, permanently }

/// Four-zone stage (spec Section 3): Zone 1 is the emoji, Zones 2-4 are the
/// pixel-font banner. The camera/ML Kit/PetState pipeline is unchanged from
/// earlier versions (build-order step 1) — it still exists purely to drive
/// `PetState` transitions and brightness; nothing here renders it directly
/// anymore, since the eyes/gaze/breathing renderer it used to feed is
/// retired (spec Section 7).
class _StageState extends State<_Stage> with WidgetsBindingObserver {
  late final CameraService _camera;
  late final FaceTracker _tracker;
  late final PetStateController _petState;
  StreamSubscription<FaceSnapshot>? _sub;
  _PermissionState _perm = _PermissionState.unknown;
  String? _error;

  // Holds whatever the last reaction was — either a real Reaction Engine
  // call (ambient/gesture) or a static one (boot greeting, return-from-
  // absence). Always something on screen (CLAUDE.md non-negotiable #8).
  Reaction _reaction = Reaction.bootGreeting(Tuning.userName);
  ReactionPhase _phase = ReactionPhase.idle;
  Timer? _phaseResetTimer;

  // Guards every Reaction Engine call — debug TEST REACTION, Waking, and
  // ambient tick alike — so at most one runs at a time. There is exactly one
  // resident model session (the "legacy singleton slot" in
  // reaction_engine.dart); an overlapping second call would race the first
  // for it rather than run genuinely in parallel.
  bool _engineBusy = false;
  Timer? _ambientTimer;

  // Gesture polling — its own cadence, independent of the Reaction Engine
  // triggers (spec: "a separate on-device model from the Reaction Engine's,
  // don't conflate testing the two"). Debounced over a few consecutive
  // polls, then a cooldown so a held-up gesture doesn't retrigger every
  // poll while it's still up. Victory fires the image-based gesture
  // reaction (this used to be Open_Palm's job); Open_Palm now starts the
  // voice-recording flow instead; Closed_Fist is only ever polled for while
  // that flow is actively recording (see `_pollGesture`).
  Timer? _gestureTimer;
  int _victoryConsecutive = 0;
  int _openPalmConsecutive = 0;
  int _closedFistConsecutive = 0;
  DateTime? _gestureCooldownUntil;

  // Conversation mode (whiteboard/gesture/voice follow-ups): after a
  // gesture or voice reaction completes, this device treats itself as
  // "mid-conversation" until this window elapses — ambient is held off, and
  // a subsequent gesture or voice trigger gets the real back-and-forth so
  // far as continuity context instead of being treated as a brand-new
  // encounter. Both modalities share this one window/history, per spec:
  // someone can switch between showing a note and speaking mid-exchange.
  // Stored oldest-first, both sides of each turn (see ConversationTurn) —
  // not just this device's own past replies.
  DateTime? _conversationUntil;
  final List<ConversationTurn> _conversationHistory = [];

  // Open_Palm voice-recording flow (spec Section 4.4) — orthogonal to
  // PetState, same precedent as _phase/ReactionPhase above.
  VoiceRecordingPhase _voicePhase = VoiceRecordingPhase.idle;
  Timer? _countdownTimer;
  int _countdownValue = 0;
  Timer? _recordingCapTimer;
  Timer? _recordingTickTimer;
  DateTime? _recordingStartedAt;
  bool _micGranted = false;
  // What to show during `replying` — the transcript, so the human sees
  // what was heard while the reply is still generating.
  String? _pendingTranscript;

  // Ambient countdown (the bottom-right "pixel tqdm"): _ambientArmedAt and
  // _ambientNextAt bound the current wait span so the UI can show elapsed
  // fraction — including spans stretched out by an active conversation
  // window, not just the plain tuning-panel interval.
  DateTime? _ambientArmedAt;
  DateTime? _ambientNextAt;

  // Last few reaction lines, for the no-repeat prompt context (spec "What
  // alive means now": response variety without a hardcoded pool).
  final List<String> _recentTexts = [];

  // The Sleeping default is supposed to override whatever the last reaction
  // was (spec Section 4.3) — correct for real triggers, since none of them
  // can even fire while Sleeping. But the debug TEST REACTION button can be
  // tapped in any state, and a result that immediately gets masked by
  // Sleeping is a useless debug tool. So: let a fresh test result show
  // through for a short window regardless of state, then let normal
  // state-driven display resume.
  Timer? _testOverrideTimer;
  bool _testOverrideActive = false;

  // Device thermal readout (top-left corner) — independent of camera
  // permission/pipeline state, so it's scheduled straight from initState
  // rather than from _startPipeline.
  Timer? _tempTimer;
  double? _deviceTempC;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _camera = CameraService();
    _tracker = FaceTracker(_camera);
    _petState = PetStateController(
      setTargetFps: _camera.setTargetFps,
      onReturn: _onReturn,
    );
    _bootstrap();
    _scheduleTempPoll();
  }

  /// App backgrounded/inactive mid-recording (or mid-countdown): reset the
  /// voice flow cleanly rather than leaving the mic pipeline stuck (spec
  /// Section 4.4's "if interrupted... reset cleanly" requirement).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed &&
        _voicePhase != VoiceRecordingPhase.idle) {
      _abortVoiceFlow(reason: 'app backgrounded');
    }
  }

  void _scheduleTempPoll() {
    _pollTemp();
    _tempTimer?.cancel();
    _tempTimer = Timer.periodic(const Duration(seconds: 5), (_) => _pollTemp());
  }

  Future<void> _pollTemp() async {
    final tempC = await DeviceTempService.instance.getBatteryTemperatureC();
    if (mounted) setState(() => _deviceTempC = tempC);
  }

  Future<void> _bootstrap() async {
    final status = await Permission.camera.status;
    setState(() {
      _perm = status.isGranted
          ? _PermissionState.granted
          : status.isPermanentlyDenied
              ? _PermissionState.permanently
              : _PermissionState.denied;
    });
    if (_perm == _PermissionState.granted) {
      await _startPipeline();
    }
  }

  Future<void> _requestPermission() async {
    final status = await Permission.camera.request();
    setState(() {
      _error = null;
      _perm = status.isGranted
          ? _PermissionState.granted
          : status.isPermanentlyDenied
              ? _PermissionState.permanently
              : _PermissionState.denied;
    });
    if (_perm == _PermissionState.granted) {
      await _startPipeline();
    } else if (_perm == _PermissionState.permanently) {
      setState(() => _error =
          'Camera permission permanently denied. Re-enable it from system settings.');
    }
  }

  Future<void> _startPipeline() async {
    try {
      await _camera.start();
      _tracker.start();
      _petState.start();
      _sub = _tracker.snapshots.listen((s) {
        _petState.onFacePresence(s.stableFacePresent);
        // Face left frame mid-recording/countdown: reset cleanly rather
        // than leaving the flow stuck waiting on a Closed_Fist that may
        // never come back into view (spec Section 4.4).
        if (!s.stableFacePresent && _voicePhase != VoiceRecordingPhase.idle) {
          _abortVoiceFlow(reason: 'face lost');
        }
      });
      _scheduleAmbientTick();
      _scheduleGesturePoll();
      // Opportunistic, non-blocking: camera permission gates the whole app
      // (PermissionGate), but mic is optional-add-on — if denied, Open_Palm
      // just no-ops instead of blocking everything else.
      unawaited(_requestMicPermission());
    } catch (e, st) {
      FlutterError.reportError(FlutterErrorDetails(
        exception: e,
        stack: st,
        context: DiagnosticsNode.message('_Stage._startPipeline'),
      ));
      setState(() => _error = 'Camera failed to start: $e');
    }
  }

  /// Build-order step 3: prove the Reaction Engine pipeline end to end
  /// against a static generated image before wiring any real trigger.
  /// Debug-only — reachable from the overlay's DEBUG tab, not part of the
  /// Waking/ambient/gesture trio, but shares their busy-flag and phase
  /// indicator since it hits the same singleton model session.
  Future<void> _triggerTestReaction() async {
    // Also gated on the voice flow being idle (spec Section 4.4's "known
    // open issue" note): this button didn't check `_voicePhase`, so tapping
    // it mid-countdown/recording/transcribing could take `_engineBusy` for
    // itself and cause the voice trigger's own `_fireRealTrigger` call to
    // silently no-op once recording stopped — the stage would then hand
    // back to the normal view still showing whatever was on screen before
    // the person spoke, looking exactly like the reply had been dropped.
    if (_engineBusy || _voicePhase != VoiceRecordingPhase.idle) return;
    setState(() {
      _engineBusy = true;
      _phase = ReactionPhase.processing;
    });
    try {
      final bytes = await buildStaticTestImage();
      final reaction = await ReactionEngine.instance.react(
        trigger: 'test',
        imageBytes: bytes,
        systemPrompt:
            'You are a small desk companion. React briefly to what you '
            'notice in the image: one emoji and a short line of text, under '
            '100 characters. If the image shows handwritten or printed text '
            'held up to the camera, read and respond to that instead of '
            'describing the general scene.',
      );
      if (mounted) {
        setState(() {
          _reaction = reaction;
          _testOverrideActive = true;
        });
        _testOverrideTimer?.cancel();
        _testOverrideTimer = Timer(const Duration(seconds: 20), () {
          if (mounted) setState(() => _testOverrideActive = false);
        });
        _flashSuccess();
      }
    } finally {
      if (mounted) setState(() => _engineBusy = false);
    }
  }

  /// Self-rescheduling rather than `Timer.periodic` so a live tuning-panel
  /// edit to `ambient_tick_interval_s` takes effect on the very next tick
  /// instead of requiring a restart. The normal target is "interval from
  /// now", but if a gesture conversation is still active when this fires,
  /// it's pushed out to whenever that window ends instead — checked both
  /// here and again at fire time, since the window can be extended by a
  /// fresh gesture reply while this is already counting down.
  void _scheduleAmbientTick() {
    final now = DateTime.now();
    final conv = _conversationUntil;
    if (conv != null && !conv.isAfter(now)) {
      // Window elapsed with no follow-up — close out the conversation so
      // a much-later gesture starts fresh instead of dragging old context.
      _conversationUntil = null;
      _conversationHistory.clear();
    }
    final intervalMs =
        (Tuning.get('ambient_tick_interval_s') * 1000).round();
    var next = now.add(Duration(milliseconds: intervalMs));
    if (_conversationUntil != null && _conversationUntil!.isAfter(next)) {
      next = _conversationUntil!;
    }
    _armAmbientTimer(next);
  }

  /// Arms the ambient timer to fire at an explicit instant, tracking the
  /// span's start too — that's what lets the countdown widget show elapsed
  /// fraction rather than just a raw remaining-seconds number.
  ///
  /// The next span is only scheduled *after* an actual fire's reply comes
  /// back (`await`ed here), not the instant it starts — otherwise the
  /// ~20-30s generation time gets silently absorbed into the interval
  /// instead of counted on top of it, so the real gap between "reply
  /// lands" and "next check" ends up shorter than the tuning panel says.
  /// While a call is in flight the bar just holds full, since it's already
  /// reached the end of its span by the time firing starts.
  void _armAmbientTimer(DateTime at) {
    _ambientTimer?.cancel();
    _ambientArmedAt = DateTime.now();
    _ambientNextAt = at;
    final delay = at.difference(DateTime.now());
    _ambientTimer = Timer(delay.isNegative ? Duration.zero : delay, () async {
      if (!mounted) return;
      final stillConversing = _conversationUntil != null &&
          DateTime.now().isBefore(_conversationUntil!);
      // Also gated on the voice flow being idle: a full countdown ->
      // record -> transcribe -> reply cycle can run 60-90s, well past a
      // single ambient interval, and _conversationUntil isn't set for that
      // exchange until it actually finishes. Without this check, ambient
      // could fire mid-flow, steal _engineBusy from the in-flight voice
      // call, and silently drop the reply — leaving the stale pre-trigger
      // reaction on screen once the voice UI hands back to the normal view.
      if (_petState.state == PetState.tracking &&
          !stillConversing &&
          _voicePhase == VoiceRecordingPhase.idle) {
        await _fireRealTrigger('ambient');
      }
      if (!mounted) return;
      _scheduleAmbientTick();
    });
  }

  /// [PetStateController.onReturn]: fires on every return from absence —
  /// from Dimming/Sleeping via the full Waking ramp, and from a brief Idle
  /// blip too short to ever reach Dimming. Static, not an LLM call (spec
  /// amendment): a human found the ~20-30s wait for an LLM-calibrated
  /// greeting not worth it for the common case of just sitting back down.
  /// The old pre-fire-on-raw-signal optimization (starting the model call
  /// early to hide its latency) is gone along with the call it existed to
  /// hide — nothing left to pre-empt.
  ///
  /// Below `min_break_greeting_s`, this is a no-op: a glance away, or a
  /// hand briefly covering the face, was showing up as "back after a
  /// 16-second break" since `onReturn` used to fire — and greet — on
  /// *any* return, no matter how short the gap. Short gaps still reset
  /// the lap timer etc. via the controller; they just don't get a banner.
  void _onReturn(double absenceSeconds) {
    if (absenceSeconds < Tuning.get('min_break_greeting_s')) return;
    setState(() {
      _reaction = Reaction.backFromBreak(
        name: Tuning.userName,
        absenceSeconds: absenceSeconds,
      );
    });
  }

  /// Self-rescheduling for the same live-tuning reason as the ambient tick.
  void _scheduleGesturePoll() {
    _gestureTimer?.cancel();
    final intervalMs = Tuning.get('gesture_poll_interval_ms').round();
    _gestureTimer = Timer(Duration(milliseconds: intervalMs), () {
      if (!mounted) return;
      _pollGesture();
      _scheduleGesturePoll();
    });
  }

  /// Runs the native Gesture Recognizer on the camera's current frame and
  /// dispatches on which category fired (spec Section 4.2.3/4.4): `Victory`
  /// fires the existing image-based gesture reaction (this used to be
  /// Open_Palm's job); `Open_Palm` starts the voice-recording countdown;
  /// `Closed_Fist` is only ever checked while a recording is actually in
  /// flight, to stop it early. Own cadence and its own confidence/debounce/
  /// cooldown knobs — entirely independent of the Reaction Engine triggers,
  /// per the spec's explicit "don't conflate testing the two."
  Future<void> _pollGesture() async {
    if (_petState.state != PetState.tracking) return;
    _publishGestureCooldown();

    if (_voicePhase == VoiceRecordingPhase.recording) {
      // Mid-recording: the only thing worth polling for is the stop
      // gesture. Ignore Victory/Open_Palm entirely here so a re-detection
      // can't stack a second trigger on top of the one already running.
      final frame = _camera.latestFrame;
      if (frame == null) return;
      try {
        final jpeg = nv21ToJpeg(
          nv21: frame.bytes,
          width: frame.width,
          height: frame.height,
          rotationDegrees: frame.rotationDegrees,
          maxDimension: 320,
        );
        final result = await GestureRecognizerService.instance.recognize(jpeg);
        DebugBus.instance
            .put('GestureLast', result == null ? 'none' : result.category);
        DebugBus.instance.put('GestureConfidence',
            result == null ? '—' : result.score.toStringAsFixed(2));
        final threshold = Tuning.get('gesture_confidence_threshold');
        final isFist = result != null &&
            result.category == 'Closed_Fist' &&
            result.score >= threshold;
        _closedFistConsecutive = isFist ? _closedFistConsecutive + 1 : 0;
        final debounceFrames = Tuning.get('gesture_debounce_frames').round();
        if (_closedFistConsecutive >= debounceFrames) {
          _closedFistConsecutive = 0;
          _stopRecordingAndRespond();
        }
      } catch (e) {
        DebugBus.instance.put('LastError', 'Gesture: $e');
      }
      return;
    }

    // Mid-countdown or mid-transcribe: nothing to poll for right now, and
    // no new trigger should stack on top of the flow already running.
    if (_voicePhase != VoiceRecordingPhase.idle) return;

    final cooling = _gestureCooldownUntil != null &&
        DateTime.now().isBefore(_gestureCooldownUntil!);
    if (cooling || _engineBusy) return;
    final frame = _camera.latestFrame;
    if (frame == null) return;
    try {
      final jpeg = nv21ToJpeg(
        nv21: frame.bytes,
        width: frame.width,
        height: frame.height,
        rotationDegrees: frame.rotationDegrees,
        // The gesture model doesn't need much resolution and this runs far
        // more often than the Reaction Engine triggers — keep it cheap.
        maxDimension: 320,
      );
      final result = await GestureRecognizerService.instance.recognize(jpeg);
      DebugBus.instance
          .put('GestureLast', result == null ? 'none' : result.category);
      DebugBus.instance.put('GestureConfidence',
          result == null ? '—' : result.score.toStringAsFixed(2));

      final threshold = Tuning.get('gesture_confidence_threshold');
      final isVictory = result != null &&
          result.category == 'Victory' &&
          result.score >= threshold;
      final isOpenPalm = result != null &&
          result.category == 'Open_Palm' &&
          result.score >= threshold;
      _victoryConsecutive = isVictory ? _victoryConsecutive + 1 : 0;
      _openPalmConsecutive = isOpenPalm ? _openPalmConsecutive + 1 : 0;

      final debounceFrames = Tuning.get('gesture_debounce_frames').round();
      if (_victoryConsecutive >= debounceFrames) {
        _victoryConsecutive = 0;
        _openPalmConsecutive = 0;
        _armGestureCooldown();
        _fireRealTrigger('gesture');
      } else if (_openPalmConsecutive >= debounceFrames) {
        _openPalmConsecutive = 0;
        _victoryConsecutive = 0;
        _armGestureCooldown();
        _startVoiceCountdown();
      }
    } catch (e) {
      DebugBus.instance.put('LastError', 'Gesture: $e');
    }
  }

  void _armGestureCooldown() {
    final cooldownS = Tuning.get('gesture_cooldown_s');
    _gestureCooldownUntil =
        DateTime.now().add(Duration(milliseconds: (cooldownS * 1000).round()));
    _publishGestureCooldown();
  }

  /// Requests RECORD_AUDIO once, opportunistically, right after the camera
  /// pipeline starts — not mid-gesture, since prompting for a permission in
  /// the middle of a 3-2-1 countdown would be a bad way to discover it's
  /// missing. If denied, Open_Palm just no-ops (see `_beginRecording`)
  /// rather than blocking the rest of the app the way camera denial does.
  Future<void> _requestMicPermission() async {
    final status = await Permission.microphone.request();
    _micGranted = status.isGranted;
    DebugBus.instance.put('MicPermission', _micGranted ? 'granted' : 'denied');
  }

  /// Open_Palm fired: 3-2-1 on-screen countdown (spec Section 4.4), then
  /// starts recording. Independent of `_engineBusy`/conversation state —
  /// this is the start of its own flow, not a Reaction Engine call itself.
  void _startVoiceCountdown() {
    if (!mounted) return;
    setState(() {
      _voicePhase = VoiceRecordingPhase.countdown;
      _countdownValue = 3;
    });
    DebugBus.instance.put('RecordingState', 'countdown $_countdownValue');
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_countdownValue <= 1) {
        t.cancel();
        _beginRecording();
      } else {
        setState(() => _countdownValue--);
        DebugBus.instance.put('RecordingState', 'countdown $_countdownValue');
      }
    });
  }

  Future<void> _beginRecording() async {
    if (!mounted) return;
    if (!_micGranted) {
      DebugBus.instance.put('LastError', 'Mic permission not granted');
      await _abortVoiceFlow(reason: 'mic permission denied');
      return;
    }
    setState(() {
      _voicePhase = VoiceRecordingPhase.recording;
      _recordingStartedAt = DateTime.now();
    });
    DebugBus.instance.put('RecordingState', 'recording');
    try {
      await AudioRecorderService.instance.start();
    } catch (e) {
      DebugBus.instance.put('LastError', 'Recording start: $e');
      await _abortVoiceFlow(reason: 'start failed');
      return;
    }
    // Re-renders the elapsed-seconds readout in RecordingIndicator; no state
    // to update here beyond triggering a rebuild off `_recordingStartedAt`.
    _recordingTickTimer?.cancel();
    _recordingTickTimer =
        Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
    final capS = Tuning.get('recording_max_duration_s');
    _recordingCapTimer?.cancel();
    _recordingCapTimer =
        Timer(Duration(milliseconds: (capS * 1000).round()), () {
      if (_voicePhase == VoiceRecordingPhase.recording) {
        _stopRecordingAndRespond();
      }
    });
  }

  /// Closed_Fist detected, or the hard cap elapsed — stop capture,
  /// transcribe, and fire the voice trigger through the same Reaction
  /// Engine call path the gesture/ambient triggers already use (spec:
  /// reuse that machinery rather than rebuilding it).
  Future<void> _stopRecordingAndRespond() async {
    if (_voicePhase != VoiceRecordingPhase.recording) return;
    _recordingCapTimer?.cancel();
    _recordingTickTimer?.cancel();
    if (mounted) {
      setState(() => _voicePhase = VoiceRecordingPhase.transcribing);
    } else {
      _voicePhase = VoiceRecordingPhase.transcribing;
    }
    DebugBus.instance.put('RecordingState', 'transcribing');

    Uint8List pcm;
    try {
      pcm = await AudioRecorderService.instance.stop();
    } catch (e) {
      DebugBus.instance.put('LastError', 'Recording stop: $e');
      await _abortVoiceFlow(reason: 'stop failed');
      return;
    }
    final clipSeconds = pcm.length / (16000 * 2);
    DebugBus.instance.put('LastClipDurationS', clipSeconds.toStringAsFixed(1));

    String transcript;
    try {
      transcript = await SpeechRecognizerService.instance.transcribe(pcm);
    } catch (e) {
      DebugBus.instance.put('LastError', 'STT: $e');
      transcript = '';
    }
    DebugBus.instance
        .put('LastTranscript', transcript.isEmpty ? '(empty)' : transcript);

    if (transcript.trim().isEmpty) {
      await _abortVoiceFlow(reason: 'empty transcript');
      return;
    }

    // Transcript is ready — show it while the reply generates, instead of
    // falling back to whatever reaction was on screen before this trigger
    // for the several seconds the model takes. Only once the reply
    // actually lands does the flow drop back to idle and let the normal
    // display take over (now showing the new reaction).
    final trimmed = transcript.trim();
    if (mounted) {
      setState(() {
        _voicePhase = VoiceRecordingPhase.replying;
        _pendingTranscript = trimmed;
      });
    } else {
      _voicePhase = VoiceRecordingPhase.replying;
      _pendingTranscript = trimmed;
    }
    DebugBus.instance.put('RecordingState', 'replying');
    final fired = await _fireRealTrigger('voice', voiceTranscript: trimmed);
    if (!fired) {
      // The engine was busy or no camera frame was available at the exact
      // moment the reply should have fired — without this, handing back to
      // the normal view would silently show whatever reaction was on
      // screen *before* the person spoke, which reads exactly like the
      // reply got dropped (spec Section 4.4's "known open issue"). Show an
      // honest fallback instead of pretending nothing happened.
      DebugBus.instance.put('LastError', 'Voice reply dropped: engine busy or no frame');
      if (mounted) {
        setState(() => _reaction = Reaction.fallback);
      } else {
        _reaction = Reaction.fallback;
      }
    }
    if (mounted) {
      setState(() {
        _voicePhase = VoiceRecordingPhase.idle;
        _pendingTranscript = null;
      });
    } else {
      _voicePhase = VoiceRecordingPhase.idle;
      _pendingTranscript = null;
    }
    DebugBus.instance.put('RecordingState', 'idle');
  }

  /// Resets the voice-recording flow to idle, releasing the mic if it was
  /// live (spec Section 4.4's "if interrupted... reset cleanly" — covers
  /// face-lost, app-backgrounded, and this flow's own internal error paths
  /// alike, so there's exactly one place that guarantees the mic never
  /// stays stuck open).
  Future<void> _abortVoiceFlow({required String reason}) async {
    _countdownTimer?.cancel();
    _recordingCapTimer?.cancel();
    _recordingTickTimer?.cancel();
    final wasRecording = _voicePhase == VoiceRecordingPhase.recording;
    if (mounted) {
      setState(() {
        _voicePhase = VoiceRecordingPhase.idle;
        _pendingTranscript = null;
      });
    } else {
      _voicePhase = VoiceRecordingPhase.idle;
      _pendingTranscript = null;
    }
    DebugBus.instance.put('RecordingState', 'idle (interrupted: $reason)');
    if (wasRecording) {
      try {
        await AudioRecorderService.instance.stop();
      } catch (_) {
        // Nothing more to do — the goal here is just releasing the mic.
      }
    }
  }

  void _publishGestureCooldown() {
    final until = _gestureCooldownUntil;
    if (until == null || !DateTime.now().isBefore(until)) {
      DebugBus.instance.put('GestureCooldown', 'ready');
    } else {
      final remaining = until.difference(DateTime.now()).inSeconds;
      DebugBus.instance.put('GestureCooldown', '${remaining}s');
    }
  }

  /// The real Waking/ambient triggers (spec Section 4.1): grab whatever
  /// frame the camera pipeline last emitted, convert it to something the
  /// model can read, and call the Reaction Engine. Never touches disk —
  /// the JPEG only ever exists in memory, same lifetime as the NV21 frame
  /// it was built from (non-negotiable #2).
  ///
  /// Returns whether a call actually fired. Ambient/gesture callers ignore
  /// this — skipping quietly is fine there, there's already a reaction on
  /// screen. The voice trigger cannot ignore it (spec Section 4.4's "known
  /// open issue"): these same early-outs, hit right as a spoken exchange
  /// was handing off from "replying" to the normal view, were one of the
  /// ways the stage fell back to showing the pre-trigger reaction instead
  /// of a reply to what was actually said.
  Future<bool> _fireRealTrigger(String trigger, {String? voiceTranscript}) async {
    if (_engineBusy) return false;
    final frame = _camera.latestFrame;
    if (frame == null) return false;
    setState(() {
      _engineBusy = true;
      _phase = ReactionPhase.capturing;
    });
    try {
      final jpeg = nv21ToJpeg(
        nv21: frame.bytes,
        width: frame.width,
        height: frame.height,
        rotationDegrees: frame.rotationDegrees,
      );
      final rareEvent = trigger == 'ambient' && PromptContext.rollRareEvent();
      final lapSeconds = _petState.lapSeconds;
      final totalSeconds = _petState.totalSeconds;
      final name = Tuning.userName;
      final systemPrompt = switch (trigger) {
        'gesture' => PromptContext.forGesture(
            name: name,
            lapSeconds: lapSeconds,
            totalSeconds: totalSeconds,
            recentTexts: _recentTexts,
            conversationHistory: _conversationHistory,
          ),
        'voice' => PromptContext.forVoice(
            name: name,
            lapSeconds: lapSeconds,
            totalSeconds: totalSeconds,
            recentTexts: _recentTexts,
            transcript: voiceTranscript ?? '',
            conversationHistory: _conversationHistory,
          ),
        _ => PromptContext.forAmbient(
            name: name,
            lapSeconds: lapSeconds,
            totalSeconds: totalSeconds,
            recentTexts: _recentTexts,
            rareEvent: rareEvent,
          ),
      };
      if (mounted) setState(() => _phase = ReactionPhase.processing);
      // Gesture is the one synchronous trigger — someone's standing there
      // with their arm out — so it gets a lower decode cap than Waking/
      // ambient. Bumped from an earlier, tighter 60 after a real note
      // ("who are you") got answered with "question on screen" instead of
      // an actual reply — too little room was pushing the model toward
      // meta-commentary instead of engaging with the question. Voice gets
      // the highest cap of all: it's the one trigger whose reply is
      // deliberately ~100 words rather than a one-liner.
      final result = await ReactionEngine.instance.react(
        trigger: trigger,
        imageBytes: jpeg,
        systemPrompt: systemPrompt,
        userMessageText: voiceTranscript,
        longForm: trigger == 'voice',
        maxOutputTokens: switch (trigger) {
          'gesture' => 90,
          'voice' => 320,
          _ => 200,
        },
      );
      final reaction = trigger == 'voice'
          ? Reaction(emoji: result.emoji, text: result.text, longForm: true)
          : result;
      if (!mounted) return false;
      setState(() => _reaction = reaction);
      if (reaction.text.isNotEmpty) {
        _recentTexts.insert(0, reaction.text);
        if (_recentTexts.length > 5) _recentTexts.removeLast();
      }
      if (trigger == 'gesture' || trigger == 'voice') {
        // Conversation mode: keep this exchange as continuity context and
        // hold ambient off until the window elapses, so a follow-up note
        // or spoken remark gets treated as a continuation and ambient
        // doesn't step on the exchange while it's still live. Shared
        // across both modalities — someone can switch from showing a note
        // to speaking mid-conversation.
        final windowS = Tuning.get('conversation_window_s');
        _conversationUntil =
            DateTime.now().add(Duration(milliseconds: (windowS * 1000).round()));
        if (reaction.text.isNotEmpty) {
          // Both sides of the turn, oldest-first (spec: a real transcript,
          // not just this device's own past lines) — gesture has no
          // literally-captured user text, so it gets an honest placeholder
          // rather than inventing one.
          _conversationHistory.add(trigger == 'voice'
              ? ConversationTurn.user(voiceTranscript ?? '')
              : const ConversationTurn.user(
                  '[held something up to the camera]'));
          _conversationHistory.add(ConversationTurn.assistant(reaction.text));
          while (_conversationHistory.length > 8) {
            _conversationHistory.removeAt(0);
          }
        }
        _armAmbientTimer(_conversationUntil!);
      }
      _flashSuccess();
      return true;
    } finally {
      if (mounted) setState(() => _engineBusy = false);
    }
  }

  /// Green blink (bottom-right status dot) on any completed call — valid or
  /// fallback both count as "a response is back", per the human's ask.
  void _flashSuccess() {
    setState(() => _phase = ReactionPhase.success);
    _phaseResetTimer?.cancel();
    _phaseResetTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _phase = ReactionPhase.idle);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _testOverrideTimer?.cancel();
    _phaseResetTimer?.cancel();
    _ambientTimer?.cancel();
    _gestureTimer?.cancel();
    _tempTimer?.cancel();
    _countdownTimer?.cancel();
    _recordingCapTimer?.cancel();
    _recordingTickTimer?.cancel();
    if (_voicePhase == VoiceRecordingPhase.recording) {
      AudioRecorderService.instance.stop();
    }
    _petState.stop();
    _tracker.stop();
    _camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DebugOverlay(
      extraActions: [
        _DebugButton(
          label: _engineBusy ? 'RUNNING…' : 'TEST REACTION',
          onTap: (_engineBusy || _voicePhase != VoiceRecordingPhase.idle)
              ? null
              : _triggerTestReaction,
        ),
      ],
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            _body(),
            _ambientCountdown(),
            ReactionStatusIndicator(phase: _phase),
            _minutesReadout(),
            _tempReadout(),
          ],
        ),
      ),
    );
  }

  /// Pixel-block countdown to the next ambient tick, just left of the
  /// status dot. Hidden outside Tracking — ambient doesn't fire then, and
  /// the away banner already covers that state. During an active gesture
  /// conversation window the span this counts against has already been
  /// stretched to match (see `_armAmbientTimer`), so the same bar honestly
  /// reflects "ambient is on hold for the conversation" rather than
  /// ticking toward a check that's about to get skipped anyway.
  Widget _ambientCountdown() {
    return AnimatedBuilder(
      animation: DebugBus.instance,
      builder: (context, _) {
        final armedAt = _ambientArmedAt;
        final nextAt = _ambientNextAt;
        if (_petState.state != PetState.tracking ||
            armedAt == null ||
            nextAt == null) {
          return const SizedBox.shrink();
        }
        final span = nextAt.difference(armedAt).inMilliseconds;
        final elapsed = DateTime.now().difference(armedAt).inMilliseconds;
        final progress = span > 0 ? elapsed / span : 1.0;
        final conversing = _conversationUntil != null &&
            DateTime.now().isBefore(_conversationUntil!);
        return Positioned(
          right: 34,
          bottom: 18,
          child: AmbientCountdown(
            progress: progress,
            conversationMode: conversing,
          ),
        );
      },
    );
  }

  /// Small top-right `session_min / today_min` readout — the persisted
  /// lapSeconds/totalSeconds tracking (CLAUDE.md's persistence carve-out)
  /// still exists per spec Section 7; this is its plain-text replacement
  /// for the retired ring/star-field visual. totalSeconds is a per-day
  /// counter (device-local date), not all-time — the right-hand number
  /// resets at midnight instead of climbing forever.
  Widget _minutesReadout() {
    return Positioned(
      top: 12,
      right: 16,
      child: AnimatedBuilder(
        animation: DebugBus.instance,
        builder: (context, _) {
          final lapMin = (_petState.lapSeconds / 60).floor();
          final totalMin = (_petState.totalSeconds / 60).floor();
          return Text(
            '$lapMin / $totalMin',
            style: const TextStyle(
              fontFamily: 'Silkscreen',
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: Color(0xFFFFFFFF),
            ),
          );
        },
      ),
    );
  }

  /// Top-left device-thermal readout: battery temperature as a permission-
  /// free proxy for device thermal load (spec's soak-test concern, made
  /// visible instead of only discoverable via a multi-hour manual test).
  /// Dull/white normally, flips to red once at or above the tunable warn
  /// threshold.
  Widget _tempReadout() {
    final tempC = _deviceTempC;
    if (tempC == null) return const SizedBox.shrink();
    final warnC = Tuning.get('device_temp_warn_c');
    final hot = tempC >= warnC;
    return Positioned(
      top: 12,
      left: 16,
      child: Text(
        '${tempC.toStringAsFixed(0)}°C',
        style: TextStyle(
          fontFamily: 'Silkscreen',
          fontWeight: FontWeight.w700,
          fontSize: 14,
          color: hot ? const Color(0xFFFF3B30) : const Color(0x66FFFFFF),
        ),
      ),
    );
  }

  Widget _body() {
    if (_perm != _PermissionState.granted) {
      return PermissionGate(
        onGrant: _requestPermission,
        errorText: _error,
      );
    }
    // Voice-recording flow takes over both zones entirely while it's live
    // (spec Section 4.4) — a deliberate, in-progress interaction takes
    // priority over whatever the last ambient/gesture reaction was.
    switch (_voicePhase) {
      case VoiceRecordingPhase.countdown:
        return VoiceCountdown(value: _countdownValue);
      case VoiceRecordingPhase.recording:
        final capS = Tuning.get('recording_max_duration_s');
        final elapsed = _recordingStartedAt == null
            ? Duration.zero
            : DateTime.now().difference(_recordingStartedAt!);
        return RecordingIndicator(
          elapsed: elapsed,
          cap: Duration(seconds: capS.round()),
        );
      case VoiceRecordingPhase.transcribing:
        return const Center(
          child: Text(
            'TRANSCRIBING…',
            style: TextStyle(
              fontFamily: 'Silkscreen',
              fontWeight: FontWeight.w700,
              fontSize: 22,
              letterSpacing: 2,
              color: Color(0x99FFFFFF),
            ),
          ),
        );
      case VoiceRecordingPhase.replying:
        // Transcript ready, reply still generating (a few seconds) — shows
        // what was heard so the exchange doesn't look abandoned, rather
        // than silently holding the previous reaction on screen.
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '"${_pendingTranscript ?? ''}"',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'Silkscreen',
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                    color: Color(0x99FFFFFF),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'THINKING…',
                  style: TextStyle(
                    fontFamily: 'Silkscreen',
                    fontWeight: FontWeight.w700,
                    fontSize: 22,
                    letterSpacing: 2,
                    color: Color(0xFFFFFFFF),
                  ),
                ),
              ],
            ),
          ),
        );
      case VoiceRecordingPhase.idle:
        break;
    }
    // Rides on DebugBus's existing notify-on-change plumbing (PetState is
    // published there every tick) instead of adding a second polling timer
    // just to notice the Sleeping transition.
    return AnimatedBuilder(
      animation: DebugBus.instance,
      builder: (context, _) {
        // Sleeping default (spec Section 4.3): fixed emoji, no text, no
        // Reaction Engine call — zero cost while the desk is empty. Except
        // right after a debug TEST REACTION tap, which should be visible
        // regardless of state — see _testOverrideActive above.
        final sleeping =
            _petState.state == PetState.sleeping && !_testOverrideActive;
        // Idle/Dimming: no Reaction Engine call fires here either (ambient
        // only runs during Tracking), so without this the banner would just
        // show whatever reaction happened to be last on screen, stale and
        // increasingly wrong the longer nobody's there. A static "$name is
        // away" line is a zero-cost, honest replacement for that — same
        // "zero cost while desk is empty" principle as Sleeping, one step
        // earlier in the timeout ramp.
        final away = !sleeping &&
            !_testOverrideActive &&
            (_petState.state == PetState.idle ||
                _petState.state == PetState.dimming);
        final shown = sleeping
            ? Reaction.sleeping
            : away
                ? Reaction(
                    emoji: Reaction.idle.emoji,
                    text: '${Tuning.userName.toUpperCase()} is away',
                  )
                : _reaction;
        return Row(
          children: [
            // Zone 1: the emoji.
            Expanded(
              flex: 1,
              child: Center(
                child: Text(
                  shown.emoji,
                  style: const TextStyle(fontSize: 96),
                ),
              ),
            ),
            // Zones 2-4: the pixel-font banner.
            Expanded(
              flex: 3,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: TypewriterBanner(
                  text: shown.text,
                  longForm: shown.longForm,
                  // Color sampled from the "FABLE 5" marquee reference;
                  // dialed back to ~85% alpha to stay subtle against the
                  // pitch-black stage rather than reading as neon. Voice
                  // replies run smaller — a ~100-word reply at the ambient
                  // quip's 34px would mostly scroll past unread.
                  style: TextStyle(
                    fontFamily: 'Silkscreen',
                    fontWeight: FontWeight.w700,
                    fontSize: shown.longForm ? 22 : 34,
                    color: const Color(0xD9CF5867),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DebugButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;

  const _DebugButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0x44FFFFFF)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: onTap == null
                ? const Color(0x66FFFFFF)
                : const Color(0xFFFFFFFF),
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}
