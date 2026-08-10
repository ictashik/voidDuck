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
import 'ui/crt_overlay.dart';
import 'ui/debug_overlay.dart';
import 'ui/permission_gate.dart';
import 'ui/reaction_status_indicator.dart';
import 'ui/recording_indicator.dart';
import 'ui/stage_theme.dart';
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
        scaffoldBackgroundColor: StageColors.crt,
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

  // Visitor alert (v0.16): a second face enters the frame while the owner
  // is being tracked. Debounced over consecutive multi-face frames, then a
  // cooldown so a sustained visitor doesn't re-trigger every poll. On fire:
  // a 'visitor' Reaction Engine call ("who is that?") plus a full-screen
  // red/white attention blink (the VisitorAlert widget). Gated on
  // PetState.tracking so a passing crowd in an empty room doesn't set it
  // off — the alert means "someone else is HERE, right now, while you are
  // here too."
  int _visitorStreak = 0;
  DateTime? _visitorCooldownUntil;
  bool _visitorAlertActive = false;

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
        _onFaceSnapshot(s);
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

  /// Visitor detection, per face snapshot (v0.16): count consecutive frames
  /// with 2+ faces while the owner is stably present and the stage is
  /// Tracking, then fire the visitor trigger + attention blink. Every other
  /// condition (cooldown, engine busy, voice flow live) resets the streak —
  /// the debounce only counts a clean, unopposed multi-face stretch.
  void _onFaceSnapshot(FaceSnapshot s) {
    final now = DateTime.now();
    final cooling = _visitorCooldownUntil != null &&
        now.isBefore(_visitorCooldownUntil!);
    final armed = s.stableFacePresent &&
        s.faceCount >= 2 &&
        _petState.state == PetState.tracking &&
        !cooling &&
        !_engineBusy &&
        _voicePhase == VoiceRecordingPhase.idle;
    if (armed) {
      _visitorStreak++;
      if (_visitorStreak >= Tuning.get('visitor_debounce_frames').round()) {
        _visitorStreak = 0;
        _armVisitorCooldown();
        unawaited(_fireVisitorAlert());
      }
    } else {
      _visitorStreak = 0;
    }
    _publishVisitorState(now);
  }

  void _armVisitorCooldown() {
    _visitorCooldownUntil = DateTime.now().add(
      Duration(seconds: Tuning.get('visitor_cooldown_s').round()),
    );
    _publishVisitorState(DateTime.now());
  }

  /// The visitor attention-blink itself (no Reaction Engine involvement —
  /// that's `_fireRealTrigger('visitor')`'s job): flip the stage's alert
  /// overlay on; VisitorAlert self-turns off after its blinks elapse. The
  /// blink runs even if the engine call ends up skipped (busy/no frame) —
  /// the alert is about the moment, the reaction is about the content.
  Future<void> _fireVisitorAlert() async {
    if (!mounted) return;
    setState(() => _visitorAlertActive = true);
    await _fireRealTrigger('visitor');
  }

  void _publishVisitorState(DateTime now) {
    final cooling = _visitorCooldownUntil;
    if (cooling != null && now.isBefore(cooling)) {
      DebugBus.instance.put('VisitorState',
          'cooldown ${cooling.difference(now).inSeconds}s');
    } else if (_visitorStreak > 0) {
      DebugBus.instance.put('VisitorState', 'counting $_visitorStreak');
    } else {
      DebugBus.instance.put('VisitorState', 'armed');
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
        'visitor' => PromptContext.forVisitor(
            name: name,
            lapSeconds: lapSeconds,
            totalSeconds: totalSeconds,
            recentTexts: _recentTexts,
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
          'visitor' => 90,
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
        backgroundColor: StageColors.crt,
        body: Stack(
          children: [
            _body(),
            // Stage chrome: terminal register strips at top and bottom
            // (example.html's topbar/botbar, carrying the readouts that used
            // to float as four separate corner widgets).
            _topChrome(),
            _bottomChrome(),
            // CRT texture over everything but the debug overlay.
            const CrtOverlay(),
            // Visitor attention blink (v0.16): full-screen red/white flashes,
            // above the CRT texture, below the debug overlay. Self-dismissing.
            if (_visitorAlertActive)
              VisitorAlert(
                blinks: Tuning.get('visitor_alert_blinks').round(),
                blinkMs: Tuning.get('visitor_alert_blink_ms').round(),
                onDone: () {
                  if (mounted) setState(() => _visitorAlertActive = false);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Top terminal strip: unit ID, live camera/voice status, PetState, and
  /// the thermal + session readouts (which used to float top-left and
  /// top-right).
  Widget _topChrome() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: AnimatedBuilder(
        animation: DebugBus.instance,
        builder: (context, _) {
          final state = _petState.state;
          final absent =
              state != PetState.tracking && state != PetState.waking;
          final tempC = _deviceTempC;
          final hot = tempC != null &&
              tempC >= Tuning.get('device_temp_warn_c');
          return Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: const BoxDecoration(
              color: StageColors.crt2,
              border: Border(bottom: BorderSide(color: StageColors.rule)),
            ),
            child: Row(
              children: [
                const Text(
                  '⬤',
                  style: TextStyle(color: StageColors.hazard, fontSize: 8),
                ),
                const SizedBox(width: 6),
                Text(
                  'VOIDDUCK',
                  style: StageText.labelStrong.copyWith(letterSpacing: 0.2),
                ),
                const SizedBox(width: 8),
                const Text('· DESK COMPANION', style: StageText.label),
                const Spacer(),
                _voiceChromeLabel(),
                const SizedBox(width: 14),
                if (state == PetState.sleeping)
                  _BlinkText(
                    text: 'STATE · SLEEPING',
                    style: StageText.labelRed,
                    blinkMs: 700,
                  )
                else
                  Text(
                    'STATE · ${_stateLabel(state)}',
                    style: absent ? StageText.labelRed : StageText.labelStrong,
                  ),
                const Spacer(),
                Text(
                  'TEMP ${tempC == null ? '—' : '${tempC.toStringAsFixed(0)}°C'}',
                  style: hot ? StageText.labelRed : StageText.label,
                ),
                const SizedBox(width: 14),
                _sessionReadout(),
              ],
            ),
          );
        },
      ),
    );
  }

  /// The voice-flow readout in the top strip: idle shows the camera as
  /// live; the recording flow shows which stage it's in (red, blinking for
  /// REC) — the terminal's "channel is in use" tell.
  Widget _voiceChromeLabel() {
    switch (_voicePhase) {
      case VoiceRecordingPhase.countdown:
        return Text('ARM · $_countdownValue', style: StageText.labelRed);
      case VoiceRecordingPhase.recording:
        return _BlinkText(
          text: '● REC',
          style: StageText.labelRed.copyWith(fontSize: 11),
          blinkMs: 400,
        );
      case VoiceRecordingPhase.transcribing:
        return const Text('STT', style: StageText.labelRed);
      case VoiceRecordingPhase.replying:
        return const Text('SYNTH', style: StageText.labelRed);
      case VoiceRecordingPhase.idle:
        return const Text('CAM ▮ LIVE', style: StageText.label);
    }
  }

  /// `session_min / today_min` — the persisted lapSeconds/totalSeconds
  /// tracking (CLAUDE.md's persistence carve-out), now in the top strip
  /// instead of a floating corner label.
  Widget _sessionReadout() {
    final lapMin = (_petState.lapSeconds / 60).floor();
    final totalMin = (_petState.totalSeconds / 60).floor();
    return Text(
      'SESS ${lapMin.toString().padLeft(2, '0')} · DAY ${totalMin.toString().padLeft(2, '0')}',
      style: StageText.label,
    );
  }

  String _stateLabel(PetState state) {
    switch (state) {
      case PetState.tracking:
        return 'TRACKING';
      case PetState.waking:
        return 'WAKING';
      case PetState.idle:
        return 'IDLE';
      case PetState.dimming:
        return 'DIMMING';
      case PetState.sleeping:
        return 'SLEEPING';
    }
  }

  /// Bottom terminal strip: build/serial info + state seconds on the left,
  /// the ambient countdown and status square on the right (which used to
  /// float bottom-right).
  Widget _bottomChrome() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: AnimatedBuilder(
        animation: DebugBus.instance,
        builder: (context, _) {
          return Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: const BoxDecoration(
              color: StageColors.crt2,
              border: Border(top: BorderSide(color: StageColors.rule)),
            ),
            child: Row(
              children: [
                Text(
                  'BUILD v0.16 · IN STATE ${_petState.stateSeconds.toString().padLeft(3, '0')}s',
                  style: StageText.label,
                ),
                const Spacer(),
                _ambientCountdown(),
                const SizedBox(width: 12),
                ReactionStatusIndicator(phase: _phase),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Block countdown to the next ambient tick, in the bottom strip just
  /// left of the status square. Hidden outside Tracking — ambient doesn't
  /// fire then, and the away banner already covers that state. During an
  /// active gesture conversation window the span this counts against has
  /// already been stretched to match (see `_armAmbientTimer`).
  Widget _ambientCountdown() {
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
    return AmbientCountdown(
      progress: progress,
      conversationMode: conversing,
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
        // Terminal "STT running" readout — types itself with the same CRT
        // reveal character as the banner, then holds with a blinking caret.
        return Center(
          child: TypewriterBanner(
            text: 'TRANSCRIBING…',
            style: const TextStyle(
              fontFamily: StageText.mono,
              fontWeight: FontWeight.w700,
              fontSize: 22,
              letterSpacing: 2,
              color: StageColors.phosSoft,
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
                TypewriterBanner(
                  text: '"${_pendingTranscript ?? ''}"',
                  style: const TextStyle(
                    fontFamily: StageText.mono,
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                    color: StageColors.phosSoft,
                  ),
                ),
                const SizedBox(height: 20),
                TypewriterBanner(
                  text: 'THINKING…',
                  style: const TextStyle(
                    fontFamily: StageText.mono,
                    fontWeight: FontWeight.w700,
                    fontSize: 22,
                    letterSpacing: 2,
                    color: StageColors.phos,
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
        return Padding(
          padding: const EdgeInsets.only(top: 30, bottom: 30),
          child: Row(
            children: [
              // Zone 1: the emoji, framed as the stage's specimen glyph
              // (example.html `.ascii-frame` brackets).
              Expanded(
                flex: 1,
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        '[',
                        style: TextStyle(
                          fontFamily: StageText.mono,
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                          color: StageColors.hazard,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        shown.emoji,
                        style: const TextStyle(fontSize: 88),
                      ),
                      const SizedBox(width: 10),
                      const Text(
                        ']',
                        style: TextStyle(
                          fontFamily: StageText.mono,
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                          color: StageColors.hazard,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Zones 2-4: the banner. Away (Idle/Dimming) renders as a
              // hazard alert box instead of a plain line — the stage's
              // "operator absent" state; Sleeping shows emoji only.
              Expanded(
                flex: 3,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: away
                      ? _awayAlertBox()
                      : TypewriterBanner(
                          text: shown.text,
                          longForm: shown.longForm,
                          style: TextStyle(
                            fontFamily: StageText.mono,
                            fontWeight: FontWeight.w700,
                            fontSize: shown.longForm ? 22 : 34,
                            color: StageColors.phos,
                          ),
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Idle/Dimming banner: hazard-striped alert box with a red
  /// `[ OPERATOR ABSENT ]` frame label — the stage's way of saying the
  /// signal is gone, in the same register as example.html's alert slide.
  Widget _awayAlertBox() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      decoration: BoxDecoration(
        border: Border.all(color: StageColors.hazard),
        borderRadius: BorderRadius.zero,
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _HazardStripePainter()),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _BlinkText(
                text: '[ OPERATOR ABSENT ]',
                style: const TextStyle(
                  fontFamily: StageText.mono,
                  fontSize: 11,
                  letterSpacing: 0.24,
                  fontWeight: FontWeight.w700,
                  color: StageColors.hazard,
                ),
                blinkMs: 700,
              ),
              const SizedBox(height: 12),
              Text(
                '${Tuning.userName.toUpperCase()} IS AWAY',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: StageText.mono,
                  fontWeight: FontWeight.w700,
                  fontSize: 26,
                  letterSpacing: 1,
                  color: StageColors.phos,
                ),
              ),
            ],
          ),
        ],
      ),
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
          borderRadius: BorderRadius.zero,
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

/// Hard-stepped blink (example.html `.blink`), for the few red state labels
/// that are allowed to move on this stage: sleeping state, REC, and the
/// away alert's frame label. Stepped, not eased — the aesthetic is
/// mechanical.
class _BlinkText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final int blinkMs;

  const _BlinkText({
    required this.text,
    required this.style,
    this.blinkMs = 500,
  });

  @override
  State<_BlinkText> createState() => _BlinkTextState();
}

class _BlinkTextState extends State<_BlinkText> {
  Timer? _timer;
  bool _on = true;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(Duration(milliseconds: widget.blinkMs), (_) {
      setState(() => _on = !_on);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: _on ? 1.0 : 0.3,
      child: Text(widget.text, style: widget.style),
    );
  }
}

/// Diagonal hazard stripes at low alpha — the alert-box fill from
/// example.html's `repeating-linear-gradient(135deg, ...)`, drawn once
/// (static, `shouldRepaint` false).
class _HazardStripePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = StageColors.hazard.withValues(alpha: 0.08)
      ..strokeWidth = 18;
    final step = 36.0;
    for (var x = -size.height; x < size.width + size.height; x += step) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _HazardStripePainter oldDelegate) => false;
}

/// The visitor attention blink (v0.16): full-screen hazard-red / phosphor-
/// white alternating flashes, purely mechanical (stepped, no easing — the
/// stage's motion rules). Alternates `blinks * 2` phases at `blinkMs` each,
/// then calls [onDone] so the stage can clear the active flag. Sits above
/// the CRT texture but below the debug overlay, and eats no pointer events.
class VisitorAlert extends StatefulWidget {
  final int blinks;
  final int blinkMs;
  final VoidCallback onDone;

  const VisitorAlert({
    super.key,
    required this.blinks,
    required this.blinkMs,
    required this.onDone,
  });

  @override
  State<VisitorAlert> createState() => _VisitorAlertState();
}

class _VisitorAlertState extends State<VisitorAlert> {
  Timer? _timer;
  int _phase = 0;

  @override
  void initState() {
    super.initState();
    final total = widget.blinks * 2;
    _timer = Timer.periodic(Duration(milliseconds: widget.blinkMs), (t) {
      _phase++;
      if (_phase >= total) {
        t.cancel();
        widget.onDone();
        return;
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final red = _phase.isEven;
    return Positioned.fill(
      child: IgnorePointer(
        child: ColoredBox(
          color: red
              ? StageColors.hazard.withValues(alpha: 0.85)
              : StageColors.phos.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}
