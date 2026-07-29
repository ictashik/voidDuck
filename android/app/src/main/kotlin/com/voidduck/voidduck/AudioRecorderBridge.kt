package com.voidduck.voidduck

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * Native bridge for the gesture-triggered voice recording flow (CLAUDE.md
 * non-negotiable #6). Captures 16kHz mono 16-bit PCM straight into a RAM
 * buffer via [AudioRecord] — never written to disk, same "never leaves RAM"
 * discipline as camera frames — and hands the raw bytes back to Dart on
 * `stop`, ready for `flutter_gemma`'s STT `transcribe(pcm16kMono)`.
 *
 * `start`/`stop` are the only two methods, mirroring [GestureBridge]'s
 * "single MethodCallHandler, one native resource, no camera/session
 * ownership of its own" shape. A hard native-side cap (a few seconds past
 * the Dart-side 30s default) guards against the mic staying open forever if
 * the Dart timer or a `stop` call is ever lost — belt-and-suspenders for the
 * "never continuously listening" guarantee, not the primary stop mechanism.
 */
class AudioRecorderBridge : MethodChannel.MethodCallHandler {
    companion object {
        private const val SAMPLE_RATE = 16000
        private const val HARD_CAP_MS = 40_000L
    }

    private var audioRecord: AudioRecord? = null
    private var recordingThread: Thread? = null
    private val buffer = ByteArrayOutputStream()
    private val bufferLock = Object()
    @Volatile private var recording = false
    private val mainHandler = Handler(Looper.getMainLooper())
    private val hardCapRunnable = Runnable { stopInternal() }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                try {
                    startInternal()
                    result.success(null)
                } catch (e: Exception) {
                    result.error("audio_start_failed", e.message, null)
                }
            }
            "stop" -> {
                try {
                    result.success(stopInternal())
                } catch (e: Exception) {
                    result.error("audio_stop_failed", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    @SuppressLint("MissingPermission") // Dart requests RECORD_AUDIO before ever calling start.
    private fun startInternal() {
        if (recording) return
        val minBuf = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        val record = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            minBuf * 4,
        )
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            throw IllegalStateException("AudioRecord failed to initialize")
        }
        synchronized(bufferLock) { buffer.reset() }
        audioRecord = record
        recording = true
        record.startRecording()

        val readBuf = ByteArray(minBuf)
        recordingThread = Thread {
            while (recording) {
                val n = record.read(readBuf, 0, readBuf.size)
                if (n > 0) {
                    synchronized(bufferLock) { buffer.write(readBuf, 0, n) }
                }
            }
        }.also { it.start() }

        mainHandler.removeCallbacks(hardCapRunnable)
        mainHandler.postDelayed(hardCapRunnable, HARD_CAP_MS)
    }

    private fun stopInternal(): ByteArray {
        if (!recording) return ByteArray(0)
        recording = false
        mainHandler.removeCallbacks(hardCapRunnable)
        recordingThread?.join(1000)
        recordingThread = null
        audioRecord?.apply {
            stop()
            release()
        }
        audioRecord = null
        return synchronized(bufferLock) {
            val bytes = buffer.toByteArray()
            buffer.reset()
            bytes
        }
    }
}
