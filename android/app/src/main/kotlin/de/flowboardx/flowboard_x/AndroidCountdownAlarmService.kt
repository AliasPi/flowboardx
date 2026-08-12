package de.flowboardx.flowboard_x

import android.media.AudioManager
import android.media.ToneGenerator
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Plays the countdown alarm on Android's alarm audio stream. */
class AndroidCountdownAlarmService(
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private var toneGenerator: ToneGenerator? = null
    private var disposed = false

    init {
        channel.setMethodCallHandler(::handleMethodCall)
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "play" -> result.success(play())
            "stop" -> {
                stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Plays one short signal. The countdown controller invokes this once per
     * second until the user acknowledges the alarm.
     */
    private fun play(): Boolean {
        if (disposed) return false
        val generator = toneGenerator ?: runCatching {
            ToneGenerator(AudioManager.STREAM_ALARM, MAX_TONE_VOLUME)
        }.getOrNull()?.also { toneGenerator = it } ?: return false
        return runCatching {
            generator.stopTone()
            generator.startTone(ToneGenerator.TONE_PROP_BEEP2, TONE_DURATION_MS)
        }.getOrDefault(false)
    }

    private fun stop() {
        if (disposed) return
        stopPlayback()
    }

    private fun stopPlayback() {
        toneGenerator?.let { value ->
            runCatching { value.stopTone() }
            runCatching { value.release() }
        }
        toneGenerator = null
    }

    fun dispose() {
        if (disposed) return
        stopPlayback()
        disposed = true
        channel.setMethodCallHandler(null)
    }

    companion object {
        private const val CHANNEL_NAME = "de.flowboardx/countdown_alarm"
        private const val MAX_TONE_VOLUME = 100
        private const val TONE_DURATION_MS = 850
    }
}
