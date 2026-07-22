/// Runs one PDF picker/preview/import workflow at a time and guarantees that
/// native preview resources are released before the selected file is copied.
///
/// This ordering matters on Windows: PDFium may retain a file handle for the
/// lifetime of the preview document. Trying to stream the same source file
/// into the document asset directory before disposing that handle can fail on
/// some PDFs or PDFium builds. Keeping the coordinator generic makes the
/// lifecycle deterministic and independently testable without loading native
/// PDFium in a unit test.
final class PdfImportCoordinator {
  bool _running = false;

  bool get isRunning => _running;

  /// Returns `null` when the picker/preview is cancelled or another PDF
  /// workflow is already active. Exceptions from opening, selecting,
  /// releasing, or importing are forwarded after best-effort cleanup.
  Future<TResult?> run<TPreview, TSelection, TResult>({
    required Future<TPreview?> Function() openPreview,
    required Future<TSelection?> Function(TPreview preview) selectPages,
    required Future<void> Function(TPreview preview) disposePreview,
    required Future<TResult> Function(
      TPreview releasedPreview,
      TSelection selection,
    )
    importSelection,
  }) async {
    if (_running) return null;
    _running = true;
    TPreview? preview;
    Object? primaryError;
    StackTrace? primaryStackTrace;
    try {
      preview = await openPreview();
      if (preview == null) return null;
      final selection = await selectPages(preview);
      if (selection == null) return null;

      // PdfDocument.dispose is intentionally awaited before importing. The
      // following asset copy can therefore never race a PDFium file handle.
      final releasedPreview = preview;
      await disposePreview(releasedPreview);
      preview = null;
      return await importSelection(releasedPreview, selection);
    } catch (error, stackTrace) {
      primaryError = error;
      primaryStackTrace = stackTrace;
    } finally {
      if (preview != null) {
        try {
          await disposePreview(preview);
        } catch (cleanupError, cleanupStackTrace) {
          primaryError ??= cleanupError;
          primaryStackTrace ??= cleanupStackTrace;
        }
      }
      _running = false;
    }
    Error.throwWithStackTrace(primaryError!, primaryStackTrace!);
  }
}
