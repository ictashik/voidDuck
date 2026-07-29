import 'dart:typed_data';

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_speech/flutter_gemma_speech.dart';

/// On-device transcription for the Open_Palm voice-recording trigger
/// (CLAUDE.md non-negotiable #6 / spec Section 4.4), via `flutter_gemma`'s
/// bundled Moonshine Tiny STT model.
///
/// Moonshine Tiny's native input is a **fixed 5-second window**
/// (`moonshine_tiny_5s_f32.tflite` — confirmed in `flutter_gemma_speech`'s
/// own `padOrTrimToWindow`, which pads short clips with zeros but *trims*
/// anything longer than 5s rather than looping over it). A 30-second
/// recording is therefore chunked into consecutive 5-second slices here,
/// each transcribed separately and the results concatenated — there is no
/// larger-window or streaming variant shipped for this model.
class SpeechRecognizerService {
  SpeechRecognizerService._();
  static final SpeechRecognizerService instance = SpeechRecognizerService._();

  /// Must match the asset entries in pubspec.yaml / assets/models/.
  static const _modelAsset = 'models/moonshine_tiny_5s_f32.tflite';
  static const _tokenizerAsset = 'models/moonshine_tokenizer.json';

  static const _sampleRate = 16000;
  static const _bytesPerSample = 2; // 16-bit PCM
  static const _chunkBytes = 5 * _sampleRate * _bytesPerSample; // 5s window

  bool _backendRegistered = false;
  bool _modelInstalled = false;

  Future<void> _ensureInstalled() async {
    if (!_backendRegistered) {
      // Additive/idempotent per FlutterGemma.initialize()'s registry design
      // (registerAll on an opt-in list) — safe to call alongside
      // ReactionEngine's own initialize() for the inference engine,
      // regardless of which one happens to run first.
      await FlutterGemma.initialize(sttBackends: [LiteRtSttBackend()]);
      _backendRegistered = true;
    }
    if (!_modelInstalled) {
      // install() is itself idempotent (skips re-copying an already-
      // installed asset), so this is cheap on every call after the first —
      // just kept behind its own flag to skip the asset-lookup entirely.
      await FlutterGemma.installStt()
          .modelFromAsset(_modelAsset)
          .tokenizerFromAsset(_tokenizerAsset)
          .ofType(SttModelType.moonshine)
          .install();
      _modelInstalled = true;
    }
  }

  /// Transcribes a raw 16kHz mono 16-bit PCM clip of any length, chunked
  /// into 5-second windows under the hood. Never throws: a chunk that fails
  /// to transcribe is skipped rather than aborting the whole clip, since a
  /// partial transcript is more useful to the Reaction Engine than none.
  ///
  /// Spins up a fresh [SpeechRecognizer] (and its background isolate) for
  /// every call and closes it once done, rather than keeping one resident
  /// across every voice turn for the app's lifetime the way the Gemma
  /// session is (that one's too large — 2.4GB — to reload per call;
  /// Moonshine is small enough that per-turn reload is cheap). This is
  /// specifically to rule out the underlying worker's decode state
  /// (autoregressive token buffers, position counters) carrying over from
  /// one recording into the next as a cause of transcripts degrading over
  /// several turns — a resident recognizer was the suspect, so it's gone.
  Future<String> transcribe(Uint8List pcm16kMono) async {
    if (pcm16kMono.isEmpty) return '';
    await _ensureInstalled();
    final recognizer = await FlutterGemma.getActiveStt();
    final parts = <String>[];
    try {
      for (var offset = 0; offset < pcm16kMono.length; offset += _chunkBytes) {
        final end = (offset + _chunkBytes < pcm16kMono.length)
            ? offset + _chunkBytes
            : pcm16kMono.length;
        final chunk = pcm16kMono.sublist(offset, end);
        try {
          final text = await recognizer.transcribe(chunk);
          if (text.trim().isNotEmpty) parts.add(text.trim());
        } catch (_) {
          // Skip this chunk; keep whatever the rest of the clip yields.
        }
      }
    } finally {
      try {
        await recognizer.close();
      } catch (_) {
        // Best-effort teardown — nothing more to do if it fails too.
      }
    }
    return parts.join(' ').trim();
  }
}
