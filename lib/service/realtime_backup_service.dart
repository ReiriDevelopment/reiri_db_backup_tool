// File purpose: Tracks the lifecycle and controller responses of real-time backups.

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

  /// Starts the controller subscription once both endpoints are ready.
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

  /// Marks real-time backup active after the controller returns a payload.
  bool handleControllerResponse(Map<String, dynamic>? data) {
    if (data == null) return false;
    _active = true;
    return true;
  }

  /// Clears lifecycle flags so reconnection can start a fresh subscription.
  void handleDisconnected() {
    _started = false;
    _active = false;
  }
}
