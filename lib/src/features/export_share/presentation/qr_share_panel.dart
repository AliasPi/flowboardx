import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../application/pdf_share_controller.dart';

/// Large-display friendly status and QR panel for [PdfShareController].
final class QrSharePanel extends StatelessWidget {
  const QrSharePanel({
    required this.controller,
    this.onRetry,
    this.onClose,
    super.key,
  });

  final PdfShareController controller;
  final VoidCallback? onRetry;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final state = controller.state;
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        child: switch (state.phase) {
          PdfSharePhase.idle => _IdleView(onClose: onClose),
          PdfSharePhase.exporting => _ProgressView(
            key: const ValueKey('exporting'),
            title: 'PDF wird erstellt',
            progress: state.exportProgress?.fraction,
            subtitle: state.exportProgress == null
                ? null
                : 'Seite ${state.exportProgress!.pageIndex + 1} '
                      'von ${state.exportProgress!.pageCount}',
          ),
          PdfSharePhase.startingServer => const _ProgressView(
            key: ValueKey('server'),
            title: 'Lokale Freigabe wird gestartet',
          ),
          PdfSharePhase.sharing => _SharingView(
            key: const ValueKey('sharing'),
            state: state,
            onStop: controller.stop,
          ),
          PdfSharePhase.expired => _MessageView(
            key: const ValueKey('expired'),
            icon: Icons.timer_off_outlined,
            title: 'Freigabe beendet',
            message: state.message ?? 'Der Freigabezeitraum ist abgelaufen.',
            primaryLabel: onRetry == null ? null : 'Erneut freigeben',
            onPrimary: onRetry,
            onClose: onClose,
          ),
          PdfSharePhase.failed => _MessageView(
            key: const ValueKey('failed'),
            icon: Icons.wifi_off_rounded,
            title: 'Freigabe nicht möglich',
            message: state.message ?? 'Bitte prüfe die WLAN-Verbindung.',
            primaryLabel: onRetry == null ? null : 'Erneut versuchen',
            onPrimary: onRetry,
            onClose: onClose,
          ),
        },
      );
    },
  );
}

final class _IdleView extends StatelessWidget {
  const _IdleView({this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) => _PanelFrame(
    key: const ValueKey('idle'),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.qr_code_2_rounded, size: 72, color: Color(0xFF8A9AA8)),
        const SizedBox(height: 16),
        Text(
          'Keine Freigabe aktiv',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (onClose != null) ...[
          const SizedBox(height: 24),
          TextButton(onPressed: onClose, child: const Text('Schließen')),
        ],
      ],
    ),
  );
}

final class _ProgressView extends StatelessWidget {
  const _ProgressView({
    required this.title,
    this.progress,
    this.subtitle,
    super.key,
  });

  final String title;
  final double? progress;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => _PanelFrame(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 60,
          height: 60,
          child: CircularProgressIndicator(value: progress, strokeWidth: 5),
        ),
        const SizedBox(height: 24),
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        if (subtitle != null) ...[
          const SizedBox(height: 8),
          Text(subtitle!, style: Theme.of(context).textTheme.bodyLarge),
        ],
      ],
    ),
  );
}

final class _SharingView extends StatelessWidget {
  const _SharingView({required this.state, required this.onStop, super.key});

  final PdfShareState state;
  final Future<void> Function() onStop;

  @override
  Widget build(BuildContext context) {
    final url = state.shareUrl!;
    final colorScheme = Theme.of(context).colorScheme;
    return _PanelFrame(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'PDF lokal teilen',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text(
            'QR-Code mit einem Gerät im selben WLAN scannen.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 22),
          Semantics(
            label: 'QR-Code zum Herunterladen der PDF',
            image: true,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: QrImageView(
                  data: url.toString(),
                  version: QrVersions.auto,
                  size: 244,
                  padding: EdgeInsets.zero,
                  eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: Colors.black,
                  ),
                  dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: Colors.black,
                  ),
                  errorCorrectionLevel: QrErrorCorrectLevel.M,
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: SelectableText(
                  url.toString(),
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Adresse kopieren',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: url.toString()));
                  if (context.mounted) {
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                      const SnackBar(content: Text('Download-Adresse kopiert')),
                    );
                  }
                },
                icon: const Icon(Icons.copy_rounded),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            state.downloadCount == 1
                ? '1 Download'
                : '${state.downloadCount} Downloads',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: onStop,
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Text('Freigabe beenden'),
          ),
        ],
      ),
    );
  }
}

final class _MessageView extends StatelessWidget {
  const _MessageView({
    required this.icon,
    required this.title,
    required this.message,
    this.primaryLabel,
    this.onPrimary,
    this.onClose,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) => _PanelFrame(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 64, color: Theme.of(context).colorScheme.error),
        const SizedBox(height: 18),
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 22),
        Wrap(
          spacing: 12,
          children: [
            if (onClose != null)
              TextButton(onPressed: onClose, child: const Text('Schließen')),
            if (onPrimary != null && primaryLabel != null)
              FilledButton(onPressed: onPrimary, child: Text(primaryLabel!)),
          ],
        ),
      ],
    ),
  );
}

final class _PanelFrame extends StatelessWidget {
  const _PanelFrame({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minWidth: 380, maxWidth: 520),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF20252B),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0xFF3A424B)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 28,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Padding(padding: const EdgeInsets.all(32), child: child),
    ),
  );
}
