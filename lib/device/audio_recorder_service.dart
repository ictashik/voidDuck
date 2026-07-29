import 'package:flutter/services.dart';

/// Dart-side handle to [AudioRecorderBridge] (native `voidduck/audio_recorder`
/// channel) — the RAM-only mic capture used by the Open_Palm voice-recording
/// trigger (CLAUDE.md non-negotiable #6). Every call is Open_Palm-countdown
/// -> [start] -> ... -> [stop], never anything overlapping; the native side
/// enforces "one recording at a time" itself.
class AudioRecorderService {
  AudioRecorderService._();
  static final AudioRecorderService instance = AudioRecorderService._();

  static const _channel = MethodChannel('voidduck/audio_recorder');

  /// Begins capturing 16kHz mono 16-bit PCM. Assumes RECORD_AUDIO is already
  /// granted — callers must check permission state themselves first.
  Future<void> start() async {
    await _channel.invokeMethod('start');
  }

  /// Stops capture and returns whatever PCM bytes were captured (empty if
  /// nothing was recording). Never touches disk on either side of the
  /// channel — the clip only ever exists in RAM, same lifetime discipline as
  /// a camera frame headed to the Reaction Engine.
  Future<Uint8List> stop() async {
    final bytes = await _channel.invokeMethod<Uint8List>('stop');
    return bytes ?? Uint8List(0);
  }
}
