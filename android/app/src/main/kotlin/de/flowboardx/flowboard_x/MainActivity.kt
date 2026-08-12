package de.flowboardx.flowboard_x

import android.app.Activity
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.content.Intent
import android.os.Bundle
import android.os.Build
import android.view.MotionEvent
import android.view.View
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID

class MainActivity : FlutterActivity() {
    private var widgetChannel: MethodChannel? = null
    private var fileSaverChannel: MethodChannel? = null
    private var handwritingRecognitionService: AndroidHandwritingRecognitionService? = null
    private var palmInputService: AndroidPalmInputService? = null
    private var smartBoardCompatibilityService: SmartBoardCompatibilityService? = null
    private var pdfQuickShareService: AndroidPdfQuickShareService? = null
    private var countdownAlarmService: AndroidCountdownAlarmService? = null
    private var countdownPictureInPictureService: AndroidCountdownPictureInPictureService? = null
    private var pendingWidgetAction: Map<String, Any?>? = null
    private var pendingPdfSave: PendingPdfSave? = null

    private fun copyPdfToDestination(uri: android.net.Uri, pending: PendingPdfSave) {
        Thread({
            try {
                val output = contentResolver.openOutputStream(uri, "w")
                    ?: error("Der gewählte Speicherort kann nicht geöffnet werden.")
                File(pending.sourcePath).inputStream().buffered().use { input ->
                    output.buffered().use { destination ->
                        input.copyTo(destination, 256 * 1024)
                        destination.flush()
                    }
                }
                runOnUiThread { pending.result.success(uri.toString()) }
            } catch (error: Throwable) {
                runOnUiThread {
                    pending.result.error(
                        "pdf_save_failed",
                        error.message ?: "PDF konnte nicht gespeichert werden.",
                        null,
                    )
                }
            }
        }, "flowboard-pdf-save").start()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        pendingWidgetAction = takeWidgetAction(intent)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        widgetChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            WIDGET_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler(::handleWidgetMethod)
        }
        fileSaverChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FILE_SAVER_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler(::handleFileSaverMethod)
        }
        handwritingRecognitionService?.dispose()
        handwritingRecognitionService = AndroidHandwritingRecognitionService(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        palmInputService?.dispose()
        palmInputService = AndroidPalmInputService(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
        ) {
            findViewById<View>(FLUTTER_VIEW_ID)
        }
        smartBoardCompatibilityService?.dispose()
        smartBoardCompatibilityService = SmartBoardCompatibilityService(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        pdfQuickShareService = AndroidPdfQuickShareService(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        countdownAlarmService?.dispose()
        countdownAlarmService = AndroidCountdownAlarmService(
            flutterEngine.dartExecutor.binaryMessenger,
        )
        countdownPictureInPictureService?.dispose()
        countdownPictureInPictureService =
            if (
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                    packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
            ) {
                AndroidCountdownPictureInPictureService(
                    this,
                    flutterEngine.dartExecutor.binaryMessenger,
                )
            } else {
                null
            }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        widgetChannel?.setMethodCallHandler(null)
        widgetChannel = null
        fileSaverChannel?.setMethodCallHandler(null)
        fileSaverChannel = null
        handwritingRecognitionService?.dispose()
        handwritingRecognitionService = null
        palmInputService?.dispose()
        palmInputService = null
        smartBoardCompatibilityService?.dispose()
        smartBoardCompatibilityService = null
        pdfQuickShareService?.dispose()
        pdfQuickShareService = null
        countdownAlarmService?.dispose()
        countdownAlarmService = null
        countdownPictureInPictureService?.dispose()
        countdownPictureInPictureService = null
        pendingPdfSave?.result?.error(
            "engine_closed",
            "Der Speichervorgang wurde beendet.",
            null,
        )
        pendingPdfSave = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        // Observe before Flutter/Android can transform or cancel the event,
        // but preserve every mixed packet containing a stylus. Only a complete
        // touch-only stream which started next to the pen is quarantined.
        val suppressPalmRest = palmInputService?.observe(event) == true
        smartBoardCompatibilityService?.observe(event)
        if (suppressPalmRest) return true
        return super.dispatchTouchEvent(event)
    }

    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        // Stylus hover arrives here rather than through dispatchTouchEvent.
        // Observing it lets the guard reject a hand which lands just before
        // the pen tip, while the original hover packet still reaches Flutter.
        palmInputService?.observeGenericMotion(event)
        return super.dispatchGenericMotionEvent(event)
    }

    override fun onResume() {
        super.onResume()
        smartBoardCompatibilityService?.applyDrawingSurfacePolicy()
    }

    override fun onUserLeaveHint() {
        countdownPictureInPictureService?.onUserLeaveHint()
        super.onUserLeaveHint()
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        countdownPictureInPictureService?.onPictureInPictureModeChanged(
            isInPictureInPictureMode,
        )
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) smartBoardCompatibilityService?.applyDrawingSurfacePolicy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val action = takeWidgetAction(intent) ?: return
        pendingWidgetAction = action
        widgetChannel?.invokeMethod(
            METHOD_WIDGET_LAUNCH,
            action,
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    if (result == true && pendingWidgetAction?.get("eventId") == action["eventId"]) {
                        pendingWidgetAction = null
                    }
                }

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) = Unit
                override fun notImplemented() = Unit
            },
        )
    }

    @Deprecated("Android activity result compatibility for the system document picker")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_CREATE_PDF) return
        val pending = pendingPdfSave ?: return
        pendingPdfSave = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending.result.success(null)
            return
        }
        copyPdfToDestination(uri, pending)
    }

    private fun handleWidgetMethod(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "updateDocuments" -> {
                val documents = call.argument<List<Map<String, Any?>>>("documents") ?: emptyList()
                val stored = WidgetPreferences.storeDocuments(applicationContext, documents)
                FlowboardWidgetProvider.updateAll(applicationContext)
                result.success(stored)
            }

            "refreshWidgets" -> {
                FlowboardWidgetProvider.updateAll(applicationContext)
                result.success(null)
            }

            "consumeLaunchAction" -> {
                val action = pendingWidgetAction
                pendingWidgetAction = null
                result.success(action)
            }

            else -> result.notImplemented()
        }
    }

    private fun handleFileSaverMethod(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "savePdf") {
            result.notImplemented()
            return
        }
        if (pendingPdfSave != null) {
            result.error("save_in_progress", "Es läuft bereits ein Speichervorgang.", null)
            return
        }
        val sourcePath = call.argument<String>("sourcePath")
        val suggestedName = call.argument<String>("suggestedName")
        if (sourcePath.isNullOrBlank() || suggestedName.isNullOrBlank()) {
            result.error("invalid_arguments", "Exportpfad oder Dateiname fehlt.", null)
            return
        }
        val source = File(sourcePath)
        val canonical = runCatching { source.canonicalFile }.getOrNull()
        val allowedRoots = listOf(cacheDir, filesDir).mapNotNull {
            runCatching { it.canonicalFile }.getOrNull()
        }
        val allowed = canonical != null && allowedRoots.any { root ->
            canonical.path == root.path ||
                canonical.path.startsWith(root.path + File.separator)
        }
        if (!allowed || !canonical.isFile || canonical.length() <= 0L) {
            result.error("invalid_source", "Die temporäre PDF-Datei ist ungültig.", null)
            return
        }
        val safeName = suggestedName
            .replace(Regex("[\\\\/\\u0000-\\u001F\\u007F]"), "_")
            .take(120)
            .let { if (it.lowercase().endsWith(".pdf")) it else "$it.pdf" }
        pendingPdfSave = PendingPdfSave(canonical.path, result)
        try {
            startActivityForResult(
                Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "application/pdf"
                    putExtra(Intent.EXTRA_TITLE, safeName)
                },
                REQUEST_CREATE_PDF,
            )
        } catch (error: Throwable) {
            pendingPdfSave = null
            result.error(
                "picker_unavailable",
                error.message ?: "Kein Dateidialog verfügbar.",
                null,
            )
        }
    }

    private fun takeWidgetAction(intent: Intent?): Map<String, Any?>? {
        val currentIntent = intent ?: return null
        val action = when (currentIntent.action) {
            FlowboardWidgetProvider.ACTION_NEW_WHITEBOARD -> mapOf(
                "type" to "newWhiteboard",
                "eventId" to UUID.randomUUID().toString(),
            )

            FlowboardWidgetProvider.ACTION_OPEN_DOCUMENT -> {
                val documentId = currentIntent.getStringExtra(
                    FlowboardWidgetProvider.EXTRA_DOCUMENT_ID,
                ) ?: return null
                mapOf(
                    "type" to "openDocument",
                    "documentId" to documentId,
                    "eventId" to UUID.randomUUID().toString(),
                )
            }

            else -> null
        }
        if (action != null) {
            currentIntent.action = Intent.ACTION_MAIN
            currentIntent.removeExtra(FlowboardWidgetProvider.EXTRA_DOCUMENT_ID)
        }
        return action
    }

    companion object {
        private const val WIDGET_CHANNEL = "de.flowboardx/platform_widget"
        private const val FILE_SAVER_CHANNEL = "de.flowboardx/pdf_file_saver"
        private const val METHOD_WIDGET_LAUNCH = "widgetLaunch"
        private const val REQUEST_CREATE_PDF = 24071
    }

    private data class PendingPdfSave(
        val sourcePath: String,
        val result: MethodChannel.Result,
    )
}
