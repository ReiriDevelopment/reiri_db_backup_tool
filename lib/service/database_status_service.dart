import 'dart:io';

import 'package:reiri_app_core/reiri_app_core.dart';

import 'package:reiri_db_backup_tool/lib/date_time_utils.dart';
import 'package:reiri_db_backup_tool/lib/database_record_progress.dart';
import 'package:reiri_db_backup_tool/lib/initial_backup_constants.dart';
import 'package:reiri_db_backup_tool/model/backup_database.dart';
import 'package:reiri_db_backup_tool/model/backup_log_entry.dart';
import 'package:reiri_db_backup_tool/service/file_log_service.dart';
import 'package:reiri_db_backup_tool/service/recovery_service.dart';

/// Describes the current synchronization health of a backup database.
enum DatabaseSyncStatus {
  synced,
  delayed,
  notFound,
  missingDisconnected,
  missingScheduled,
}

/// Contains the dashboard status details for one backup database.
class DatabaseStatEntry {
  final String filename;
  final String descriptionKey;
  final DateTime? lastBackup;
  final DatabaseSyncStatus status;

  const DatabaseStatEntry({
    required this.filename,
    required this.descriptionKey,
    required this.lastBackup,
    required this.status,
  });
}

/// Groups database status rows with the latest real-time backup event.
class DatabaseStatusSnapshot {
  final List<DatabaseStatEntry> entries;
  final DateTime? lastRealtimeEvent;

  const DatabaseStatusSnapshot({
    required this.entries,
    required this.lastRealtimeEvent,
  });
}

/// Builds dashboard status and logs only verified record advances.
class DatabaseStatusService {
  final RecoveryService recoveryService;
  final bool Function() isRealtimeActive;
  final bool Function() isControllerConnected;
  final void Function(List<BackupLogEntry>) addLogEntries;

  final Map<String, int> _previousLatestRecord = {};
  final Map<String, int> _previousHistoryRowId = {};
  final Map<String, DateTime> _lastConfirmedBackup = {};

  bool _loading = false;
  DateTime? _lastRealtimeEvent;

  DatabaseStatusService({
    required this.recoveryService,
    required this.isRealtimeActive,
    required this.isControllerConnected,
    required this.addLogEntries,
  });

  static List<DatabaseStatEntry> get emptyEntries => BackupDatabase.values
      .map(
        (database) => DatabaseStatEntry(
          filename: database.fileName,
          descriptionKey: database.descriptionKey,
          lastBackup: null,
          status: DatabaseSyncStatus.notFound,
        ),
      )
      .toList(growable: false);

  Future<DatabaseStatusSnapshot?> load({
    required String backupRootPath,
    required String macAddress,
    bool recordRealtimeEvents = true,
  }) async {
    if (_loading || macAddress.isEmpty) return null;
    _loading = true;
    try {
      final safeMac = macToSafeFolderName(macAddress);
      final mainDir = '$backupRootPath\\$safeMac\\$kInitialBackupDbFolderName';
      final tempDir = '$backupRootPath\\$safeMac\\$kTempDbFolderName';
      final inTempMode = recoveryService.hasActiveGap;
      final realtimeActive = isRealtimeActive();
      final checkedAt = DateTime.now();

      final entries = <DatabaseStatEntry>[];
      final pendingLogEntries = <BackupLogEntry>[];

      for (final database in BackupDatabase.values) {
        final filename = database.fileName;
        final mainFile = File('$mainDir\\$filename');
        DateTime? mainModified;
        var fileFound = false;

        if (await mainFile.exists()) {
          fileFound = true;
          mainModified = (await mainFile.stat()).modified;
        }

        DateTime? effectiveModified = mainModified;
        if (inTempMode) {
          final tempFile = File('$tempDir\\$filename');
          if (await tempFile.exists()) {
            fileFound = true;
            final tempModified = (await tempFile.stat()).modified;
            if (effectiveModified == null ||
                tempModified.isAfter(effectiveModified)) {
              effectiveModified = tempModified;
            }
          }
        }

        if (!fileFound || effectiveModified == null) {
          entries.add(
            DatabaseStatEntry(
              filename: filename,
              descriptionKey: database.descriptionKey,
              lastBackup: null,
              status: DatabaseSyncStatus.notFound,
            ),
          );
          continue;
        }

        if (realtimeActive && recordRealtimeEvents) {
          await _appendVerifiedRealtimeEvent(
            database,
            pendingLogEntries,
            checkedAt,
          );
        }

        await _seedLatestProgress(database);
        final hasGap = recoveryService.metadata.detectedGaps.any(
          (gap) => gap.dbFile == filename,
        );
        final status = hasGap
            ? (isControllerConnected()
                  ? DatabaseSyncStatus.missingScheduled
                  : DatabaseSyncStatus.missingDisconnected)
            : DatabaseSyncStatus.synced;
        entries.add(
          DatabaseStatEntry(
            filename: filename,
            descriptionKey: database.descriptionKey,
            lastBackup: _laterOf(mainModified, _lastConfirmedBackup[filename]),
            status: status,
          ),
        );
      }

      if (pendingLogEntries.any(
        (entry) => entry.result == BackupLogResult.success,
      )) {
        _lastRealtimeEvent = checkedAt;
      }
      if (pendingLogEntries.isNotEmpty) addLogEntries(pendingLogEntries);

      return DatabaseStatusSnapshot(
        entries: entries,
        lastRealtimeEvent: _lastRealtimeEvent,
      );
    } finally {
      _loading = false;
    }
  }

  Future<int?> _readLatestRecord(BackupDatabase database) async {
    if (app.db == null) return null;
    return switch (database) {
      BackupDatabase.trend => await app.db!.latestTrendData(),
      BackupDatabase.meter => app.db!.latestMeterData(),
      BackupDatabase.optime => await app.db!.latestOptimeData(),
      BackupDatabase.ppd => await app.db!.latestPpdData(),
      BackupDatabase.history => await app.db!.latestHistoryData(),
    };
  }

  Future<int?> _readLatestHistoryRowId(int latestDate) async {
    if (app.db == null || latestDate <= 0) return null;
    const months = [
      'jan',
      'feb',
      'mar',
      'apr',
      'may',
      'jun',
      'jul',
      'aug',
      'sep',
      'oct',
      'nov',
      'dec',
    ];
    final month = (latestDate % 100000000) ~/ 1000000;
    if (month < 1 || month > 12) return null;
    final db = app.db!.db['history'];
    if (db == null) return null;
    final rows = await db.rawQuery(
      'SELECT MAX(rowid) AS max_rowid FROM "${months[month - 1]}"',
    );
    return rows.first['max_rowid'] as int?;
  }

  Future<void> _seedLatestProgress(BackupDatabase database) async {
    final filename = database.fileName;
    try {
      final latest = await _readLatestRecord(database);
      if (latest == null || latest <= 0) return;
      final previous = _previousLatestRecord[filename];
      if (previous == null || latest > previous) {
        _previousLatestRecord[filename] = latest;
      }
      if (database.eventBased) {
        final rowId = await _readLatestHistoryRowId(latest);
        if (rowId != null) _previousHistoryRowId[filename] = rowId;
      }
    } catch (error) {
      FileLogService().log(
        '[RealtimeBackup] Could not inspect $filename progress: $error',
      );
    }
  }

  Future<void> _appendVerifiedRealtimeEvent(
    BackupDatabase database,
    List<BackupLogEntry> entries,
    DateTime checkedAt,
  ) async {
    final filename = database.fileName;
    try {
      final latest = await _readLatestRecord(database);
      if (latest == null || latest <= 0) return;

      final previous = _previousLatestRecord[filename];
      if (previous == null) return;
      int? rowId;
      if (database.eventBased) {
        rowId = await _readLatestHistoryRowId(latest);
      }
      final advanced = hasDatabaseRecordAdvanced(
        previousTimestamp: previous,
        latestTimestamp: latest,
        eventBased: database.eventBased,
        previousRowId: _previousHistoryRowId[filename],
        latestRowId: rowId,
      );
      if (!advanced) return;

      _previousLatestRecord[filename] = latest;
      if (rowId != null) _previousHistoryRowId[filename] = rowId;
      entries.add(
        BackupLogEntry(
          timestamp: dbIntToDateTime(latest),
          backedUpAt: checkedAt,
          type: BackupLogType.realtime,
          result: BackupLogResult.success,
          database: filename,
        ),
      );
      _lastConfirmedBackup[filename] = checkedAt;
    } catch (error) {
      FileLogService().log(
        '[RealtimeBackup] Could not inspect $filename event: $error',
      );
    }
  }

  static DateTime? _laterOf(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }
}
