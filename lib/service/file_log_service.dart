import 'dart:io';

/// Singleton that appends timestamped lines to a daily log file at the backup
/// root path.  Call [init] once the backup root is known; all [log] calls
/// before [init] are silently ignored.
class FileLogService {
  static final FileLogService _instance = FileLogService._();
  FileLogService._();
  factory FileLogService() => _instance;

  String? _logPath;

  /// Sets the active log file to `{rootPath}\backup_YYYY-MM-DD.log`.
  /// Safe to call more than once (e.g. if the path changes or date rolls over).
  void init(String rootPath) {
    final now = DateTime.now();
    final date =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    _logPath = '$rootPath\\backup_$date.log';
    _write('=== Session started ===');
  }

  /// Writes [message] to the log file and the debug console.
  void log(String message) {
    print(message);
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
