package com.voidduck.voidduck

import android.content.Context
import android.graphics.BitmapFactory
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.gesturerecognizer.GestureRecognizer
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Native bridge for the deliberate "show me something" trigger (spec
 * Section 4.2.3, Open_Palm). Runs MediaPipe's Gesture Recognizer in
 * single-image mode, invoked on demand from Dart with an already-encoded
 * JPEG frame. Camera ownership stays entirely on the Dart side (the
 * `camera` plugin owns the capture session, same as ML Kit) — this bridge
 * never opens its own, so there is exactly one thing touching the camera
 * hardware at a time.
 *
 * Registered on a background BinaryMessenger.TaskQueue (see MainActivity),
 * so recognition — a real, if small, model inference — never runs on the
 * UI thread.
 */
class GestureBridge(private val context: Context) : MethodChannel.MethodCallHandler {
    private var recognizer: GestureRecognizer? = null

    private fun ensureRecognizer(): GestureRecognizer {
        recognizer?.let { return it }
        val baseOptions =
            BaseOptions.builder()
                // Same asset-key convention as every other Flutter-declared
                // asset: pubspec's `assets/models/...` lands inside the APK
                // at `assets/flutter_assets/assets/models/...`, which is
                // exactly the path Android's own AssetManager (what
                // setModelAssetPath reads through) expects.
                .setModelAssetPath("flutter_assets/assets/models/gesture_recognizer.task")
                .build()
        val options =
            GestureRecognizer.GestureRecognizerOptions.builder()
                .setBaseOptions(baseOptions)
                .setRunningMode(RunningMode.IMAGE)
                .setNumHands(1)
                .build()
        val created = GestureRecognizer.createFromOptions(context, options)
        recognizer = created
        return created
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "recognize") {
            result.notImplemented()
            return
        }
        try {
            val bytes = call.argument<ByteArray>("jpeg")
            if (bytes == null) {
                result.error("bad_args", "missing jpeg bytes", null)
                return
            }
            val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            if (bitmap == null) {
                result.error("decode_failed", "could not decode jpeg", null)
                return
            }
            val mpImage = BitmapImageBuilder(bitmap).build()
            val recognition = ensureRecognizer().recognize(mpImage)
            val top = recognition.gestures().firstOrNull()?.firstOrNull()
            if (top == null) {
                result.success(null)
            } else {
                result.success(
                    mapOf(
                        "category" to top.categoryName(),
                        "score" to top.score().toDouble(),
                    ),
                )
            }
        } catch (e: Exception) {
            result.error("gesture_error", e.message, null)
        }
    }
}
