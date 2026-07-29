package com.voidduck.voidduck

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        // Background task queue: gesture recognition is real (if small)
        // model inference and must never block the UI thread.
        val channel =
            MethodChannel(
                messenger,
                "voidduck/gesture",
                StandardMethodCodec.INSTANCE,
                messenger.makeBackgroundTaskQueue(),
            )
        channel.setMethodCallHandler(GestureBridge(applicationContext))

        // Fast, non-blocking (reads a cached sticky broadcast) — no need for
        // a background task queue here.
        MethodChannel(messenger, "voidduck/device_temp")
            .setMethodCallHandler(DeviceTempBridge(applicationContext))

        // Voice recording (CLAUDE.md non-negotiable #6): AudioRecord runs its own
        // background capture thread internally, so unlike gesture recognition this
        // channel's start/stop calls themselves are quick and don't need a
        // background task queue.
        MethodChannel(messenger, "voidduck/audio_recorder")
            .setMethodCallHandler(AudioRecorderBridge())
    }
}
