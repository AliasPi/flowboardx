package de.flowboardx.flowboard_x

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.os.Build
import android.util.Rational
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Pure transition policy kept separate from Android calls for JVM tests. */
internal data class CountdownPictureInPicturePolicy(
    val sdkInt: Int,
    val deviceHasFeature: Boolean,
) {
    val isSupported: Boolean
        get() = sdkInt >= 26 && deviceHasFeature

    val usesAutomaticEnter: Boolean
        get() = isSupported && sdkInt >= 31

    fun shouldEnterFromUserLeave(timerActive: Boolean, alreadyInPictureInPicture: Boolean): Boolean =
        isSupported && timerActive && !alreadyInPictureInPicture
}

/**
 * Keeps a running countdown visible when the user goes Home or switches apps.
 *
 * Android 12+ performs the transition through `autoEnterEnabled`, which also
 * gives the system its smooth gesture animation. Android 8 through 11 enter
 * explicitly from [onUserLeaveHint]. No overlay permission or foreground
 * service is involved.
 */
@RequiresApi(Build.VERSION_CODES.O)
class AndroidCountdownPictureInPictureService(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val policy = CountdownPictureInPicturePolicy(
        sdkInt = Build.VERSION.SDK_INT,
        deviceHasFeature = activity.packageManager.hasSystemFeature(
            PackageManager.FEATURE_PICTURE_IN_PICTURE,
        ),
    )

    private var timerActive = false
    private var disposed = false

    init {
        channel.setMethodCallHandler(::handleMethodCall)
        updatePictureInPictureParameters()
    }

    fun onUserLeaveHint() {
        if (disposed || policy.usesAutomaticEnter) return
        if (!policy.shouldEnterFromUserLeave(timerActive, isInPictureInPictureMode())) return
        try {
            activity.enterPictureInPictureMode(buildParameters())
        } catch (_: IllegalArgumentException) {
            // Device-specific PiP constraints must never prevent app leaving.
        } catch (_: IllegalStateException) {
            // The activity may already be stopping or not yet fully resumed.
        } catch (_: SecurityException) {
            // Defensive fallback for vendor-specific PiP policy restrictions.
        }
    }

    fun onPictureInPictureModeChanged(inPictureInPicture: Boolean) {
        if (disposed) return
        channel.invokeMethod(METHOD_PICTURE_IN_PICTURE_CHANGED, inPictureInPicture)
    }

    fun dispose() {
        if (disposed) return
        timerActive = false
        updatePictureInPictureParameters()
        disposed = true
        channel.setMethodCallHandler(null)
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            METHOD_GET_STATE -> result.success(currentState())
            METHOD_SET_TIMER_ACTIVE -> {
                val active = call.argument<Boolean>("active")
                if (active == null) {
                    result.error("invalid_arguments", "Timer-Aktivzustand fehlt.", null)
                    return
                }
                timerActive = active
                updatePictureInPictureParameters()
                result.success(currentState())
            }

            METHOD_ENTER_NOW -> result.success(enterPictureInPictureNow())

            else -> result.notImplemented()
        }
    }

    private fun currentState(): Map<String, Boolean> = mapOf(
        "supported" to policy.isSupported,
        "inPictureInPicture" to isInPictureInPictureMode(),
    )

    private fun isInPictureInPictureMode(): Boolean =
        Build.VERSION.SDK_INT >= 24 && activity.isInPictureInPictureMode

    private fun updatePictureInPictureParameters() {
        if (!policy.isSupported) return
        try {
            activity.setPictureInPictureParams(buildParameters())
        } catch (_: IllegalArgumentException) {
            // Keep the ordinary full-screen timer if a vendor rejects params.
        } catch (_: IllegalStateException) {
            // Safe during engine/activity teardown.
        }
    }

    private fun enterPictureInPictureNow(): Boolean {
        if (!policy.shouldEnterFromUserLeave(timerActive, isInPictureInPictureMode())) {
            return isInPictureInPictureMode()
        }
        return try {
            activity.enterPictureInPictureMode(buildParameters())
        } catch (_: IllegalArgumentException) {
            false
        } catch (_: IllegalStateException) {
            false
        } catch (_: SecurityException) {
            false
        }
    }

    private fun buildParameters(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(16, 9))
        if (Build.VERSION.SDK_INT >= 31) {
            builder.setAutoEnterEnabled(timerActive)
            builder.setSeamlessResizeEnabled(false)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            builder.setTitle("Timer")
        }
        return builder.build()
    }

    companion object {
        private const val CHANNEL_NAME = "de.flowboardx/countdown_picture_in_picture"
        private const val METHOD_GET_STATE = "getState"
        private const val METHOD_SET_TIMER_ACTIVE = "setTimerActive"
        private const val METHOD_ENTER_NOW = "enterNow"
        private const val METHOD_PICTURE_IN_PICTURE_CHANGED = "pictureInPictureChanged"
    }
}
