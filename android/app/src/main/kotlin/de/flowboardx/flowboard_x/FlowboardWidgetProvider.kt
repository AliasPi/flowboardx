package de.flowboardx.flowboard_x

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import java.io.File
import java.text.DateFormat
import java.util.Date
import kotlin.math.max

class FlowboardWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        appWidgetIds.forEach { updateWidget(context, appWidgetManager, it) }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        updateWidget(context, appWidgetManager, appWidgetId)
    }

    companion object {
        const val ACTION_NEW_WHITEBOARD = "de.flowboardx.action.NEW_WHITEBOARD"
        const val ACTION_OPEN_DOCUMENT = "de.flowboardx.action.OPEN_DOCUMENT"
        const val EXTRA_DOCUMENT_ID = "documentId"

        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val component = ComponentName(context, FlowboardWidgetProvider::class.java)
            manager.getAppWidgetIds(component).forEach { updateWidget(context, manager, it) }
        }

        private fun updateWidget(
            context: Context,
            manager: AppWidgetManager,
            widgetId: Int,
        ) {
            val documents = WidgetPreferences.readDocuments(context)
            val options = manager.getAppWidgetOptions(widgetId)
            val rowCount = rowsForHeight(
                options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 180),
            )
            val compact = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, 250) < 220
            val views = RemoteViews(context.packageName, R.layout.flowboard_widget)
            views.setOnClickPendingIntent(
                R.id.widget_new_whiteboard,
                launchIntent(context, widgetId, null),
            )
            views.removeAllViews(R.id.widget_documents)
            val visibleDocuments = documents.take(rowCount)
            views.setViewVisibility(
                R.id.widget_empty,
                if (visibleDocuments.isEmpty()) View.VISIBLE else View.GONE,
            )
            visibleDocuments.forEachIndexed { index, document ->
                val row = RemoteViews(context.packageName, R.layout.flowboard_widget_document)
                row.setTextViewText(R.id.widget_document_title, document.title)
                row.setTextViewText(
                    R.id.widget_document_date,
                    DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT)
                        .format(Date(document.updatedAtEpochMillis)),
                )
                row.setViewVisibility(
                    R.id.widget_document_date,
                    if (compact) View.GONE else View.VISIBLE,
                )
                decodePreview(document.previewPath)?.let { bitmap ->
                    row.setImageViewBitmap(R.id.widget_document_preview, bitmap)
                }
                row.setOnClickPendingIntent(
                    R.id.widget_document_root,
                    launchIntent(context, widgetId * 31 + index + 1, document.id),
                )
                views.addView(R.id.widget_documents, row)
            }
            manager.updateAppWidget(widgetId, views)
        }

        private fun rowsForHeight(heightDp: Int): Int = max(1, ((heightDp - 68) / 52)).coerceAtMost(6)

        private fun launchIntent(
            context: Context,
            requestCode: Int,
            documentId: String?,
        ): PendingIntent {
            val intent = Intent(context, MainActivity::class.java).apply {
                action = if (documentId == null) ACTION_NEW_WHITEBOARD else ACTION_OPEN_DOCUMENT
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
                data = Uri.Builder()
                    .scheme("flowboardx")
                    .authority("widget")
                    .appendPath(documentId ?: "new")
                    .appendQueryParameter("request", requestCode.toString())
                    .build()
                documentId?.let { putExtra(EXTRA_DOCUMENT_ID, it) }
            }
            return PendingIntent.getActivity(
                context,
                requestCode,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        private fun decodePreview(path: String?): Bitmap? {
            if (path.isNullOrBlank()) return null
            val file = File(path)
            if (!file.isFile || file.length() > 8L * 1024 * 1024) return null
            return runCatching {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFile(file.absolutePath, bounds)
                if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
                var sampleSize = 1
                while (bounds.outWidth / sampleSize > 128 || bounds.outHeight / sampleSize > 128) {
                    sampleSize *= 2
                }
                BitmapFactory.decodeFile(
                    file.absolutePath,
                    BitmapFactory.Options().apply {
                        inSampleSize = sampleSize
                        inPreferredConfig = Bitmap.Config.RGB_565
                    },
                )
            }.getOrNull()
        }
    }
}
