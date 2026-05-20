import 'dart:io';

import 'package:reiri_app_core/reiri_app_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:reiri_db_backup_tool/lib/initial_backup_constants.dart';
import 'package:reiri_db_backup_tool/model/backup_metadata.dart';
import 'package:reiri_db_backup_tool/service/backup_metadata_service.dart';
import 'package:reiri_db_backup_tool/service/file_log_service.dart';

/// Orchestrates the TEMP DB / MAIN DB routing logic described in the system design.
///
/// Flow when a gap is detected:
///   1. [onConnected] → gaps found → real-time writes routed to TEMP DB.
///   2. Regular backup (gap-fill) runs and writes missing records to MAIN DB.
///   3. [flushTempToMain] → all TEMP records appended to MAIN in one transaction.
///   4. [switchToMainDb] → real-time routes back to MAIN DB; TEMP deleted.
///
/// When no gap: [onConnected] returns an empty list and real-time stays on MAIN DB.
class RecoveryService {
  final BackupMetadataService _meta = BackupMetadataService();

  String _mainDbDir = '';
  String _tempDbDir = '';
  String _macDir = '';

  bool get hasActiveGap =>
      _meta.current.backupState == BackupState.realtimeTemp;

  BackupMetadata get metadata => _meta.current;

  /// Call once after the backup folder and MAC are known.
  Future<void> init({
    required String rootPath,
    required String safeMac,
  }) async {
    _macDir = '$rootPath\\$safeMac';
    _mainDbDir = '$_macDir\\$kInitialBackupDbFolderName';
    _tempDbDir = '$_macDir\\$kTempDbFolderName';
    await _meta.init(_macDir);

    // Resume an in-progress flush that was interrupted by a crash.
    if (_meta.current.flushStatus == FlushStatus.inProgress) {
      FileLogService().log('[Recovery] Resuming interrupted flush on startup');
      await _doFlush();
    }
  }

  /// Call when the WebSocket connection becomes ready.
  ///
  /// Always stages [app.db] on the TEMP directory first so any live records
  /// that arrive during gap computation land in TEMP, not MAIN.  After gap
  /// detection:
  ///   • gaps found  → keep routing to TEMP; gap-fill + flush runs later.
  ///   • no gaps     → switch straight back to MAIN (TEMP is empty at this
  ///                   point and the switchover is instant).
  ///
  /// Returns only the **newly** detected gaps. The full merged gap list
  /// (including carry-overs from previous sessions) is available via
  /// [metadata.detectedGaps].
  Future<List<GapRange>> onConnected() async {
    final tConnect = DateTime.now();

    // Remember the pre-connect state so we can log whether we are resuming.
    final wasInTemp = _meta.current.backupState == BackupState.realtimeTemp;

    // Route new records to TEMP immediately — before gap detection — so no
    // live data can land in MAIN while the async gap computation runs.
    await _stageTempDb();

    final newGaps = await _meta.recordConnect(tConnect);
    final allGaps = _meta.current.detectedGaps;

    if (allGaps.isNotEmpty) {
      // Confirm TEMP as the active write target and persist the flush state.
      await _meta.markFlushInProgress(_tempDbDir);
      if (wasInTemp) {
        FileLogService().log(
            '[Recovery] Resuming existing TEMP DB (${allGaps.length} gap(s) pending)');
      } else {
        FileLogService().log(
            '[Recovery] Gap detected (${allGaps.length} DBs affected). Routing real-time → TEMP DB');
      }
    } else {
      // No gap: TEMP staging is not needed, switch straight back to MAIN.
      await switchToMainDb();
      FileLogService().log('[Recovery] No gaps — real-time stays on MAIN DB');
    }

    return newGaps;
  }

  /// Redirects [app.db] to TEMP without updating flush metadata.
  /// Used to stage incoming writes while gap detection runs synchronously.
  Future<void> _stageTempDb() async {
    final dir = Directory(_tempDbDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    await _closeAllDbs();
    await app.setDbPath(_tempDbDir);
    await _openAllDbs();
  }

  /// Call when the WebSocket connection drops or the app is about to close.
  Future<void> onDisconnected() async {
    await _meta.recordDisconnect();
    FileLogService().log('[Recovery] Disconnect recorded at ${_meta.current.disconnectedAt}');
  }

  /// Closes MAIN DB handles, switches the global SQLite path to TEMP,
  /// opens / initialises all DB files there, and persists the flush state.
  Future<void> _openTempDb() async {
    final dir = Directory(_tempDbDir);
    if (!await dir.exists()) await dir.create(recursive: true);

    await _closeAllDbs();
    await app.setDbPath(_tempDbDir);
    await _openAllDbs();
    await _meta.markFlushInProgress(_tempDbDir);
    FileLogService().log('[Recovery] TEMP DB opened at $_tempDbDir');
  }

  /// Flushes all records from TEMP DB into MAIN DB (one transaction per file),
  /// then switches real-time back to MAIN DB and deletes TEMP.
  Future<void> flushTempToMain() async {
    if (!hasActiveGap) return;
    FileLogService().log('[Recovery] Starting TEMP → MAIN flush');
    await _doFlush();
  }

  Future<void> _doFlush() async {
    try {
      // Must operate on MAIN DB files while TEMP DB files hold the real-time data.
      // Close app.db first so SQLite files are not locked.
      await _closeAllDbs();

      for (final dbFile in kInitialBackupDbFiles) {
        final mainPath = '$_mainDbDir\\$dbFile';
        final tempPath = '$_tempDbDir\\$dbFile';

        if (!await File(tempPath).exists()) {
          FileLogService().log('[Recovery] TEMP file not found, skipping: $dbFile');
          continue;
        }
        if (!await File(mainPath).exists()) {
          FileLogService().log('[Recovery] MAIN file not found, skipping: $dbFile');
          continue;
        }

        await _flushSingleDb(mainPath, tempPath);
      }

      await _meta.markFlushCompleted();
      FileLogService().log('[Recovery] Flush complete — switching to MAIN DB');

      await switchToMainDb();

      // Delete TEMP folder after a successful switch.
      final tempDir = Directory(_tempDbDir);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
        FileLogService().log('[Recovery] TEMP DB deleted');
      }
    } catch (e) {
      FileLogService().log('[Recovery] Flush failed: $e');
      // Leave state as inProgress so next launch can retry.
      rethrow;
    }
  }

  /// Appends all rows from [tempPath] into [mainPath] using SQLite ATTACH.
  /// Wrapped in a single transaction — if the app crashes mid-way, the
  /// COMMIT never fires and MAIN DB is unchanged (safe to retry).
  Future<void> _flushSingleDb(String mainPath, String tempPath) async {
    final db = await databaseFactoryFfi.openDatabase(
      mainPath,
      options: OpenDatabaseOptions(readOnly: false),
    );
    try {
      await db.execute('ATTACH ? AS temp_db', [tempPath]);

      final tables = await db.rawQuery(
        "SELECT name FROM temp_db.sqlite_master "
        "WHERE type='table' AND name NOT LIKE 'sqlite_%'",
      );

      await db.transaction((txn) async {
        for (final row in tables) {
          final tableName = row['name'] as String;
          await txn.execute(
            'INSERT OR IGNORE INTO "$tableName" SELECT * FROM temp_db."$tableName"',
          );
          FileLogService().log('[Recovery] Flushed table "$tableName" from ${mainPath.split('\\').last}');
        }
      });

      await db.execute('DETACH temp_db');
    } finally {
      await db.close();
    }
  }

  /// Redirects [app.db] back to MAIN DB.  Call after [flushTempToMain] or
  /// when the user manually dismisses a gap (e.g. gap-fill was done elsewhere).
  Future<void> switchToMainDb() async {
    await app.setDbPath(_mainDbDir);
    await _openAllDbs();
    FileLogService().log('[Recovery] Switched to MAIN DB at $_mainDbDir');
  }

  /// Writes [records] (from a `*_db_backup` controller response) into the
  /// MAIN DB for [dbType].  Opens a dedicated SQLite connection by absolute
  /// path so it does not interfere with [app.db], which points to TEMP during
  /// gap recovery.
  Future<void> fillGapInMainDb(String dbType, List<dynamic> records) async {
    if (records.isEmpty) return;
    final dbFile = _dbTypeToFile(dbType);
    final mainPath = '$_mainDbDir\\$dbFile';
    if (!await File(mainPath).exists()) {
      FileLogService().log('[Recovery] Gap-fill: MAIN file missing, skip $dbFile');
      return;
    }

    // Open MAIN file by full path — does NOT affect app.db (TEMP path).
    final rawDb = await databaseFactoryFfi.openDatabase(
      mainPath,
      options: OpenDatabaseOptions(readOnly: false),
    );
    final mainDb = ReiriDb();
    mainDb.db[dbType] = rawDb;
    try {
      switch (dbType) {
        case 'trend':
          await mainDb.initTrendDb();
          await mainDb.addTrendData(records);
        case 'meter':
          await mainDb.initMeterDb();
          await mainDb.addMeterData(records);
        case 'optime':
          await mainDb.initOptimeDb();
          await mainDb.addOptimeData(records);
        case 'ppd':
          await mainDb.initPpdDb();
          await mainDb.addPpdData(records);
        case 'history':
          await mainDb.initHistoryDb();
          await mainDb.addHistoryData(records);
      }
      FileLogService().log('[Recovery] Gap-fill: wrote ${records.length} record(s) → $dbFile');
    } catch (e) {
      FileLogService().log('[Recovery] Gap-fill: write error for $dbFile: $e');
    } finally {
      await rawDb.close();
      mainDb.db.remove(dbType);
    }
  }

  /// Maps a DB filename (e.g. `'trend.db'`) to its short type key.
  static String? fileToDbType(String file) => switch (file) {
    'trend.db'   => 'trend',
    'meter.db'   => 'meter',
    'optime.db'  => 'optime',
    'ppd.db'     => 'ppd',
    'history.db' => 'history',
    _            => null,
  };

  static String _dbTypeToFile(String type) => switch (type) {
    'trend'   => 'trend.db',
    'meter'   => 'meter.db',
    'optime'  => 'optime.db',
    'ppd'     => 'ppd.db',
    'history' => 'history.db',
    _         => throw ArgumentError('Unknown DB type: $type'),
  };

  /// Computes the next off-peak time (03:00).
  /// Returns today's 03:00 when called between midnight and 02:59,
  /// and tomorrow's 03:00 at any other time.
  static DateTime nextOffPeakTime() {
    final now = DateTime.now();
    final todayAt3 = DateTime(now.year, now.month, now.day, 3, 0);
    return now.isBefore(todayAt3)
        ? todayAt3
        : todayAt3.add(const Duration(days: 1));
  }

  // ── helpers ────────────────────────────────────────────────────────────────

  Future<void> _openAllDbs() async {
    if (app.db == null) return;
    await app.db!.openHistoryDb(); await app.db!.initHistoryDb();
    await app.db!.openMeterDb();   await app.db!.initMeterDb();
    await app.db!.openOptimeDb();  await app.db!.initOptimeDb();
    await app.db!.openPpdDb();     await app.db!.initPpdDb();
    await app.db!.openTrendDb();   await app.db!.initTrendDb();
  }

  /// Close all open DB handles held by [ReiriDb].
  Future<void> _closeAllDbs() async {
    final reiriDb = app.db;
    if (reiriDb == null) return;
    for (final db in reiriDb.db.values) {
      try { await db.close(); } catch (_) {}
    }
    reiriDb.db.clear();
  }
}
