package de.flowboardx.flowboard_x

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Applies drawing-surface hardening and exposes the documented SMART iQ setup
 * flow without depending on private SMART activities or settings keys.
 *
 * SMART's annotation layer is a privileged device feature. A regular APK
 * cannot change that setting safely, so the service only detects the hardware,
 * opens the public system settings entry point and remembers explicit user
 * confirmation.
 */
class SmartBoardCompatibilityService(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val preferences = activity.getSharedPreferences(
        PREFERENCES_NAME,
        Context.MODE_PRIVATE,
    )
    private val isSmartBoard = detectSmartBoard()
    private var disposed = false

    init {
        channel.setMethodCallHandler(::handleMethodCall)
        applyDrawingSurfacePolicy()
    }

    fun applyDrawingSurfacePolicy() {
        if (disposed) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Blocks ordinary TYPE_APPLICATION_OVERLAY windows. Privileged
            // system overlays may be exempt, which is why the per-app SMART
            // annotation setting remains the authoritative device fix.
            activity.window.setHideOverlayWindows(true)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.window.decorView.post {
                if (!disposed) disableAutomaticHandwriting(activity.window.decorView)
            }
        }
    }

    fun observe(event: MotionEvent) {
        if (disposed || !isSmartBoard || event.actionMasked != MotionEvent.ACTION_DOWN) {
            return
        }
        val actionIndex = event.actionIndex
        if (actionIndex !in 0 until event.pointerCount) return
        val toolType = event.getToolType(actionIndex)
        if (toolType != MotionEvent.TOOL_TYPE_STYLUS &&
            toolType != MotionEvent.TOOL_TYPE_ERASER
        ) {
            return
        }
        // No coordinates, pressure, document data or device identifiers leave
        // the native side. This event only proves that SMART handed the stylus
        // stream to FlowboardX instead of its annotation layer.
        channel.invokeMethod(
            METHOD_STYLUS_OBSERVED,
            mapOf(
                "tool" to if (toolType == MotionEvent.TOOL_TYPE_ERASER) {
                    "eraser"
                } else {
                    "stylus"
                },
            ),
        )
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        channel.setMethodCallHandler(null)
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            METHOD_GET_STATUS -> result.success(
                mapOf(
                    "isSmartBoard" to isSmartBoard,
                    "manufacturer" to Build.MANUFACTURER.orEmpty().take(MAX_DEVICE_LABEL_LENGTH),
                    "model" to Build.MODEL.orEmpty().take(MAX_DEVICE_LABEL_LENGTH),
                    "androidSdk" to Build.VERSION.SDK_INT,
                    "setupAcknowledged" to preferences.getBoolean(
                        KEY_SETUP_ACKNOWLEDGED,
                        false,
                    ),
                ),
            )

            METHOD_OPEN_SETTINGS -> {
                val opened = runCatching {
                    activity.startActivity(Intent(Settings.ACTION_SETTINGS))
                    true
                }.getOrDefault(false)
                result.success(opened)
            }

            METHOD_ACKNOWLEDGE_SETUP -> {
                val stored = preferences.edit()
                    .putBoolean(KEY_SETUP_ACKNOWLEDGED, true)
                    .commit()
                result.success(stored)
            }

            else -> result.notImplemented()
        }
    }

    private fun disableAutomaticHandwriting(view: View) {
        view.isAutoHandwritingEnabled = false
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) {
                disableAutomaticHandwriting(view.getChildAt(index))
            }
        }
    }

    private fun detectSmartBoard(): Boolean {
        val identity = listOf(
            Build.MANUFACTURER,
            Build.BRAND,
            Build.MODEL,
            Build.DEVICE,
            Build.PRODUCT,
        )
            .joinToString(separator = " ")
            .lowercase()
        return identity.contains("smarttech") ||
            identity.contains("smart tech") ||
            identity.split(Regex("\\s+")).any { it == "smart" }
    }

    private companion object {
        const val CHANNEL_NAME = "de.flowboardx/smart_board_compatibility"
        const val PREFERENCES_NAME = "flowboard_smart_board_compatibility"
        const val KEY_SETUP_ACKNOWLEDGED = "annotation_setup_acknowledged_v1"
        const val METHOD_GET_STATUS = "getStatus"
        const val METHOD_OPEN_SETTINGS = "openSettings"
        const val METHOD_ACKNOWLEDGE_SETUP = "acknowledgeSetup"
        const val METHOD_STYLUS_OBSERVED = "stylusObserved"
        const val MAX_DEVICE_LABEL_LENGTH = 80
    }
}
