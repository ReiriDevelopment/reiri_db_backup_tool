// File purpose: Writes timestamped diagnostic messages to per-controller log files.

import 'dart:io';

import 'package:flutter/foundation.dart';

/// Appends timestamped lines to the active controller's daily log.
class FileLogService {
  static final FileLogService _instance = FileLogService._();
  FileLogService._();
  factory FileLogService() => _instance;

  String? _logPath;

  /// Selects the daily log, using the root folder when [safeMac] is empty.
  void init(String rootPath, {required String safeMac}) {
    final dir = safeMac.isEmpty
        ? '$rootPath\\backup log'
        : '$rootPath\\$safeMac\\backup log';
    try {
      Directory(dir).createSync(recursive: true);
    } catch (_) {
      // Best-effort: if creation fails we'll still attempt writes below,
      // and the silent catch in _write will skip them.
    }
    final now = DateTime.now();
    final date =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    _logPath = '$dir\\backup_$date.log';
    _write('=== Session started ===');
  }

  /// Writes [message] to the log file and the debug console.
  void log(String message) {
    debugPrint(message);
    _write(message);
  }

  void _write(String message) {
    final path = _logPath;
    if (path == null) return;
    try {
      final ts = DateTime.now().toIso8601String();
      File(path).writeAsStringSync('[$ts] $message\n', mode: FileMode.append);
    } catch (_) {}
  }
}
