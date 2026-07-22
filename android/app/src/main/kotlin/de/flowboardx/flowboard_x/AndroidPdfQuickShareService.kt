package de.flowboardx.flowboard_x

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/** Opens Android's system sharesheet (including Quick Share) for an exported PDF. */
internal class AndroidPdfQuickShareService(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val shareInProgress = AtomicBoolean(false)

    @Volatile
    private var disposed = false

    init {
        channel.setMethodCallHandler(::handleMethodCall)
    }

    fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            result.error("service_closed", "Die Android-Freigabe wurde beendet.", null)
            return
        }
        when (call.method) {
            "isSupported" -> result.success(true)
            "sharePdf" -> sharePdf(call, result)
            else -> result.notImplemented()
        }
    }

    private fun sharePdf(call: MethodCall, result: MethodChannel.Result) {
        val sourcePath = call.argument<String>("sourcePath")
        val suggestedName = call.argument<String>("suggestedName")
        val chooserTitle = call.argument<String>("chooserTitle")
            ?.trim()
            ?.take(MAX_CHOOSER_TITLE_LENGTH)
            ?.takeIf(String::isNotEmpty)
            ?: DEFAULT_CHOOSER_TITLE
        if (sourcePath.isNullOrBlank() || suggestedName.isNullOrBlank()) {
            result.error("invalid_arguments", "Exportpfad oder Dateiname fehlt.", null)
            return
        }
        if (!shareInProgress.compareAndSet(false, true)) {
            result.error("share_in_progress", "Es läuft bereits eine Android-Freigabe.", null)
            return
        }

        Thread({
            var sessionDirectory: File? = null
            try {
                val source = validateSource(sourcePath)
                val safeName = safePdfName(suggestedName)
                val shareRoot = File(activity.cacheDir, SHARE_CACHE_DIRECTORY)
                if (!shareRoot.exists() && !shareRoot.mkdirs()) {
                    throw ShareException(
                        "cache_unavailable",
                        "Der Freigabe-Cache konnte nicht angelegt werden.",
                    )
                }
                cleanupExpiredShares(shareRoot)
                sessionDirectory = File(shareRoot, UUID.randomUUID().toString())
                if (!sessionDirectory.mkdirs()) {
                    throw ShareException(
                        "cache_unavailable",
                        "Die Freigabedatei konnte nicht vorbereitet werden.",
                    )
                }
                val sharedFile = File(sessionDirectory, safeName)
                source.inputStream().buffered(COPY_BUFFER_SIZE).use { input ->
                    sharedFile.outputStream().buffered(COPY_BUFFER_SIZE).use { output ->
                        input.copyTo(output, COPY_BUFFER_SIZE)
                        output.flush()
                    }
                }
                if (sharedFile.length() != source.length()) {
                    throw ShareException(
                        "copy_failed",
                        "Die PDF-Datei konnte nicht vollständig vorbereitet werden.",
                    )
                }
                if (disposed) {
                    sessionDirectory.deleteRecursively()
                    shareInProgress.set(false)
                    return@Thread
                }
                val directoryToRetain = sessionDirectory
                activity.runOnUiThread {
                    if (disposed) {
                        directoryToRetain.deleteRecursively()
                        shareInProgress.set(false)
                        return@runOnUiThread
                    }
                    try {
                        launchSharesheet(sharedFile, safeName, chooserTitle)
                        result.success(true)
                    } catch (error: Throwable) {
                        Log.e(TAG, "Could not open Android sharesheet", error)
                        directoryToRetain.deleteRecursively()
                        result.error(
                            "sharesheet_unavailable",
                            "Die Android-Freigabe konnte nicht geöffnet werden.",
                            null,
                        )
                    } finally {
                        shareInProgress.set(false)
                    }
                }
            } catch (error: ShareException) {
                sessionDirectory?.deleteRecursively()
                reportError(result, error.code, error.message)
            } catch (error: Throwable) {
                Log.e(TAG, "Could not prepare PDF for sharing", error)
                sessionDirectory?.deleteRecursively()
                reportError(
                    result,
                    "share_failed",
                    "Die PDF-Datei konnte nicht für die Freigabe vorbereitet werden.",
                )
            }
        }, "flowboard-pdf-quick-share").start()
    }

    private fun validateSource(sourcePath: String): File {
        val canonical = runCatching { File(sourcePath).canonicalFile }.getOrNull()
            ?: throw ShareException("invalid_source", "Die Exportdatei ist ungültig.")
        val allowedRoots = listOf(activity.cacheDir, activity.filesDir).mapNotNull { root ->
            runCatching { root.canonicalFile }.getOrNull()
        }
        val isInsideAppStorage = allowedRoots.any { root ->
            canonical.path == root.path || canonical.path.startsWith(root.path + File.separator)
        }
        if (!isInsideAppStorage || !canonical.isFile) {
            throw ShareException("invalid_source", "Die Exportdatei ist ungültig.")
        }
        val length = canonical.length()
        if (length < PDF_SIGNATURE.size || length > MAX_PDF_BYTES) {
            throw ShareException("invalid_source", "Die Exportdatei ist leer oder zu groß.")
        }
        val signature = ByteArray(PDF_SIGNATURE.size)
        val bytesRead = FileInputStream(canonical).use { it.read(signature) }
        if (bytesRead != PDF_SIGNATURE.size || !signature.contentEquals(PDF_SIGNATURE)) {
            throw ShareException("invalid_pdf", "Die Exportdatei ist keine gültige PDF-Datei.")
        }
        return canonical
    }

    private fun launchSharesheet(sharedFile: File, safeName: String, chooserTitle: String) {
        val contentUri = FileProvider.getUriForFile(
            activity,
            "${activity.packageName}.fileprovider",
            sharedFile,
        )
        val sendIntent = Intent(Intent.ACTION_SEND).apply {
            type = PDF_MIME_TYPE
            putExtra(Intent.EXTRA_STREAM, contentUri)
            putExtra(Intent.EXTRA_TITLE, safeName)
            putExtra(Intent.EXTRA_SUBJECT, safeName)
            clipData = ClipData.newUri(activity.contentResolver, safeName, contentUri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        activity.startActivity(Intent.createChooser(sendIntent, chooserTitle))
    }

    private fun reportError(result: MethodChannel.Result, code: String, message: String) {
        activity.runOnUiThread {
            shareInProgress.set(false)
            if (!disposed) result.error(code, message, null)
        }
    }

    private fun cleanupExpiredShares(root: File) {
        val cutoff = System.currentTimeMillis() - SHARE_CACHE_MAX_AGE_MILLIS
        root.listFiles()?.forEach { child ->
            if (child.lastModified() in 1 until cutoff) {
                runCatching { child.deleteRecursively() }
                    .onFailure { Log.w(TAG, "Could not clean an expired shared PDF", it) }
            }
        }
    }

    private fun safePdfName(value: String): String {
        var name = value
            .replace(Regex("[\\\\/\\u0000-\\u001F\\u007F]"), "_")
            .trim()
        if (name.isEmpty()) name = DEFAULT_FILE_NAME
        if (!name.lowercase().endsWith(PDF_EXTENSION)) name += PDF_EXTENSION
        if (name.length > MAX_FILE_NAME_LENGTH) {
            name = name.take(MAX_FILE_NAME_LENGTH - PDF_EXTENSION.length) + PDF_EXTENSION
        }
        return name
    }

    private class ShareException(
        val code: String,
        override val message: String,
    ) : Exception(message)

    private companion object {
        const val CHANNEL_NAME = "de.flowboardx/pdf_quick_share"
        const val TAG = "FlowboardQuickShare"
        const val SHARE_CACHE_DIRECTORY = "quick_share"
        const val DEFAULT_CHOOSER_TITLE = "PDF teilen"
        const val DEFAULT_FILE_NAME = "Flowboard.pdf"
        const val PDF_EXTENSION = ".pdf"
        const val PDF_MIME_TYPE = "application/pdf"
        const val MAX_FILE_NAME_LENGTH = 120
        const val MAX_CHOOSER_TITLE_LENGTH = 80
        const val MAX_PDF_BYTES = 1_073_741_824L
        const val COPY_BUFFER_SIZE = 256 * 1024
        const val SHARE_CACHE_MAX_AGE_MILLIS = 24L * 60L * 60L * 1_000L
        val PDF_SIGNATURE = byteArrayOf(0x25, 0x50, 0x44, 0x46, 0x2D)
    }
}
