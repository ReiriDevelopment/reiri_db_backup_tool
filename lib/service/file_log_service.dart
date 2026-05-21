import 'dart:io';

/// Singleton that appends timestamped lines to a daily log file under the
/// per-controller `backup log` subfolder.  Call [init] once the backup root
/// and MAC are known; all [log] calls before [init] are silently ignored.
class FileLogService {
  static final FileLogService _instance = FileLogService._();
  FileLogService._();
  factory FileLogService() => _instance;

  String? _logPath;

  /// Sets the active log file to
  /// `{rootPath}\{safeMac}\backup log\backup_YYYY-MM-DD.log`, placing the
  /// log folder at the same level as `DB` and `DB_TEMP` for the controller.
  /// Creates the folder if it does not yet exist.
  ///
  /// When [safeMac] is empty (no controller selected yet) the log falls back
  /// to `{rootPath}\backup log\backup_YYYY-MM-DD.log` so logging still works
  /// during early bring-up.
  ///
  /// Safe to call more than once (e.g. if the path changes or date rolls over).
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
