import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Non-identifying application and runtime facts attached to a diagnostic
/// session. Device identifiers, account information and locale are
/// intentionally not collected.
class DiagnosticSessionMetadata {
  const DiagnosticSessionMetadata({
    required this.appVersion,
    required this.buildNumber,
    required this.platform,
    required this.platformVersion,
    required this.buildMode,
  });

  final String appVersion;
  final String buildNumber;
  final String platform;
  final String platformVersion;
  final String buildMode;

  static Future<DiagnosticSessionMetadata> resolve({
    Duration packageLookupTimeout = const Duration(seconds: 2),
  }) async {
    String appVersion = 'unknown';
    String buildNumber = 'unknown';
    try {
      final package = await PackageInfo.fromPlatform().timeout(
        packageLookupTimeout,
      );
      appVersion = package.version;
      buildNumber = package.buildNumber;
    } on Object {
      // Diagnostics must remain available if package metadata cannot be read.
    }

    return DiagnosticSessionMetadata(
      appVersion: _safeToken(appVersion),
      buildNumber: _safeToken(buildNumber),
      platform: _safeToken(Platform.operatingSystem),
      platformVersion: _safePlatformVersion(Platform.operatingSystemVersion),
      buildMode: kReleaseMode
          ? 'release'
          : kProfileMode
          ? 'profile'
          : 'debug',
    );
  }

  static String _safeToken(String value) {
    final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9._+\-]'), '_');
    if (cleaned.isEmpty) return 'unknown';
    return cleaned.substring(0, cleaned.length.clamp(0, 64));
  }

  static String _safePlatformVersion(String value) {
    // OS version strings are useful for graphics/input regressions, while
    // machine names, file paths and long vendor fingerprints are not.
    final firstLine = value.split(RegExp(r'[\r\n]')).first;
    final withoutPaths = firstLine
        .replaceAll(RegExp(r'[A-Za-z]:[\\/][^\s]+'), '<path>')
        .replaceAll(
          RegExp(r'/(?:Users|home|data|storage|sdcard)/[^\s]+'),
          '<path>',
        );
    final cleaned = withoutPaths.replaceAll(
      RegExp(r'[^A-Za-z0-9 ._+\-()/]'),
      '_',
    );
    if (cleaned.isEmpty) return 'unknown';
    return cleaned.substring(0, cleaned.length.clamp(0, 120));
  }
}
