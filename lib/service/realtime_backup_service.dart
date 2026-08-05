import 'package:reiri_app_core/reiri_app_core.dart';

/// Tracks the continuous `db_wr` subscription and its connection lifecycle.
class RealtimeBackupService {
  final RealtimeDbBackup command;

  bool _started = false;
  bool _active = false;

  RealtimeBackupService({RealtimeDbBackup? command})
    : command = command ?? RealtimeDbBackup();

  bool get isStarted => _started;
  bool get isActive => _active;

  bool tryStart({
    required bool localDatabaseReady,
    required bool controllerReady,
  }) {
    if (!localDatabaseReady || !controllerReady || _started) return false;
    _started = true;
    final started = command.start();
    if (started) {
      app.requestController(command);
    } else {
      _started = false;
    }
    return started;
  }

  bool handleControllerResponse(Map<String, dynamic>? data) {
    if (data == null) return false;
    _active = true;
    return true;
  }

  void handleDisconnected() {
    _started = false;
    _active = false;
  }
}
