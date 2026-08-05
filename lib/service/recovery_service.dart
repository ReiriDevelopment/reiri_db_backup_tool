import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:reiri_app_core/reiri_app_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:reiri_db_backup_tool/lib/initial_backup_constants.dart';
import 'package:reiri_db_backup_tool/model/backup_database.dart';
import 'package:reiri_db_backup_tool/model/backup_metadata.dart';
import 'package:reiri_db_backup_tool/service/backup_metadata_service.dart';
import 'package:reiri_db_backup_tool/service/file_log_service.dart';

/// Orchestrates the TEMP DB / MAIN DB routing logic described in the system design.
///
/// Flow when a gap is detected:
///   1. [onConnected] → gaps found → real-time writes routed to TEMP DB.
///   2. [RecoveryNotifier.runFlushNow] gap-fill from controller → [fillGapInMainDb].
///   3. Interleaved [flushTempWindowToMain] after each gap period.
///   4. [finalizeFlushedCleanup] switches to MAIN; TEMP deleted.
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

  // ── Operation serialization ─────────────────────────────────────────────
  // Every method that opens/closes [app.db] handles or opens a second SQLite
  // connection to a DB file must run through [_synchronized]. This guarantees
  // no two structural DB operations overlap — the previous code allowed gap
  // detection to run twice concurrently (from _init AND the connection
  // listener), so one path could close a handle while another was mid-open,
  // producing a use-after-close native crash (consistently on optime.db,
  // leaving a stale optime.db-journal).
  Future<void> _opChain = Future.value();

  /// Queues [action] without letting an earlier failure break the chain.
  Future<T> _synchronized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final prev = _opChain;
    _opChain = completer.future.then((_) {}, onError: (_) {});
    prev.whenComplete(() {
      action()
          .then(completer.complete)
          .catchError(
            (Object e, StackTrace s) => completer.completeError(e, s),
          );
    });
    return completer.future;
  }

  /// Call once after the backup folder and MAC are known.
  Future<void> init({required String rootPath, required String safeMac}) async {
    _macDir = '$rootPath\\$safeMac';
    _mainDbDir = '$_macDir\\$kInitialBackupDbFolderName';
    _tempDbDir = '$_macDir\\$kTempDbFolderName';

    await _meta.init(_macDir);

    // Interrupted recovery returns to pending until the controller is ready.
    // A TEMP-only merge could clear gaps before missing data is fetched.
    if (_meta.current.flushStatus == FlushStatus.inProgress) {
      FileLogService().log(
        '[Recovery] Interrupted interleaved flush found; queued for retry',
      );
      await _meta.markFlushPending(_tempDbDir);
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
  Future<List<GapRange>> onConnected() => _synchronized(_onConnectedImpl);

  Future<List<GapRange>> _onConnectedImpl() async {
    final tConnect = DateTime.now();

    // Remember the pre-connect state so we can log whether we are resuming.
    final wasInTemp = _meta.current.backupState == BackupState.realtimeTemp;

    // Route new records to TEMP immediately — before gap detection — so no
    // live data can land in MAIN while the async gap computation runs.
    await _stageTempDb();

    final newGaps = await _meta.recordConnect(tConnect);
    final allGaps = _meta.current.detectedGaps;

    if (allGaps.isNotEmpty) {
      // Keep the flush pending until the coordinator actually starts it.
      await _meta.saveTempPath(_tempDbDir);
      if (wasInTemp) {
        FileLogService().log(
          '[Recovery] Resuming existing TEMP DB (${allGaps.length} gap(s) pending)',
        );
      } else {
        FileLogService().log(
          '[Recovery] Gap detected (${allGaps.length} DBs affected). Routing real-time → TEMP DB',
        );
      }
    } else {
      // No gap: TEMP staging is not needed, switch straight back to MAIN.
      await _switchToMainDbImpl();
      FileLogService().log('[Recovery] No gaps — real-time stays on MAIN DB');
    }

    return newGaps;
  }

  /// Redirects [app.db] to TEMP without updating flush metadata.
  /// Used to stage incoming writes while gap detection runs synchronously.
  Future<void> _stageTempDb() async {
    final dir = Directory(_tempDbDir);
    final isNew = !await dir.exists();
    if (isNew) await dir.create(recursive: true);
    await _closeAllDbs();
    await app.setDbPath(_tempDbDir);
    await _openAllDbs();
    // New TEMP databases inherit MAIN point IDs; resumed ones keep their IDs.
    if (isNew) {
      // Seed with app.db closed to avoid competing FFI writers.
      // Reopen afterward so in-memory point caches use the seeded IDs.
      await _closeAllDbs();
      await _seedPointIdFromMain();
      await app.setDbPath(_tempDbDir);
      await _openAllDbs();
    }
    // TEMP starts without meter values even though point IDs are seeded.
    // Seed MAIN values so the first realtime delta has a valid baseline.
    await _seedMeterValueCache();
  }

  /// Fills missing meter cache values from MAIN without replacing newer TEMP data.
  Future<void> _seedMeterValueCache() async {
    final reiriDb = app.db;
    if (reiriDb == null) return;
    final valueCache = reiriDb.meterDb['value'];
    if (valueCache is! Map) return;

    final mainPath = '$_mainDbDir\\${BackupDatabase.meter.fileName}';
    if (!await File(mainPath).exists()) return;

    final db = await databaseFactoryFfi.openDatabase(
      mainPath,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      // Latest value per db_id (meter.id is the surrogate db_id).
      final rows = await db.rawQuery(
        'SELECT m.id AS db_id, m.value AS value FROM meter m '
        'JOIN (SELECT id, MAX(date) AS md FROM meter GROUP BY id) x '
        'ON m.id = x.id AND m.date = x.md',
      );
      int filled = 0;
      for (final r in rows) {
        final key = '${r['db_id']}';
        if (valueCache[key] == null) {
          valueCache[key] = (r['value'] as num).toDouble();
          filled++;
        }
      }
      // Use -1 when a seeded point has no MAIN value.
      final pointList = reiriDb.meterDb['pointList'];
      if (pointList is Map) {
        for (final dbId in pointList.values) {
          final key = '$dbId';
          if (valueCache[key] == null) valueCache[key] = -1;
        }
      }
      FileLogService().log(
        '[Recovery] Seeded meter value cache from MAIN ($filled point(s))',
      );
    } catch (e) {
      FileLogService().log('[Recovery] _seedMeterValueCache failed: $e');
    } finally {
      await db.close();
    }
  }

  /// Copies MAIN's point_id table into each surrogate-key TEMP DB so that
  /// realtime writes and the subsequent flush share the same db_id mapping.
  Future<void> _seedPointIdFromMain() async {
    for (final database in BackupDatabase.values.where(
      (database) => database.usesPointId,
    )) {
      final mainPath = '$_mainDbDir\\${database.fileName}';
      final tempPath = '$_tempDbDir\\${database.fileName}';
      if (!await File(mainPath).exists()) continue;
      final tempDb = await databaseFactoryFfi.openDatabase(
        tempPath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      try {
        await tempDb.execute('ATTACH ? AS main_db', [mainPath]);
        await tempDb.transaction((txn) async {
          await txn.execute('DELETE FROM point_id');
          await txn.execute(
            'INSERT INTO point_id SELECT * FROM main_db.point_id',
          );
        });
        await tempDb.execute('DETACH main_db');
        FileLogService().log(
          '[Recovery] Seeded point_id for ${database.type} from MAIN',
        );
      } catch (e) {
        FileLogService().log(
          '[Recovery] _seedPointIdFromMain failed for ${database.type}: $e',
        );
      } finally {
        await tempDb.close();
      }
    }
  }

  /// Starts the coordinated flush and releases app.db handles until finalization.
  Future<void> beginInterleavedFlush() => _synchronized(() async {
    await _meta.markFlushInProgress(_tempDbDir);
    await _closeAllDbs();
  });

  /// Persists a healthy checkpoint without changing an active gap start.
  Future<void> recordHeartbeat({DateTime? at}) =>
      _synchronized(() => _meta.recordHeartbeat(at: at));

  /// Call when the WebSocket connection drops or the app is about to close.
  /// Repeated calls preserve the earliest known start of the same gap.
  Future<void> onDisconnected({DateTime? at}) => _synchronized(() async {
    await _meta.recordDisconnect(at: at);
    FileLogService().log(
      '[Recovery] Disconnect recorded at ${_meta.current.disconnectedAt}',
    );
  });

  /// Flushes TEMP rows in [from, to) into MAIN.
  /// Point IDs are seeded from MAIN; new points are synced and patched first.
  /// History has no surrogate point IDs and uses its normalized copy path.
  Future<void> _flushSingleDbWindow(
    String mainPath,
    String tempPath,
    BackupDatabase database,
    DateTime? from,
    DateTime? to,
  ) async {
    if (database.eventBased) {
      await _flushHistoryDb(mainPath, tempPath, from: from, to: to);
      return;
    }

    // Resolve any new points before the copy so db_ids are in sync.
    await _syncNewPointsInTemp(mainPath, tempPath, database.type);

    final db = await databaseFactoryFfi.openDatabase(
      mainPath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      await db.execute('ATTACH ? AS temp_db', [tempPath]);

      // Enumerate data tables in TEMP (exclude point_id and SQLite internals).
      final tables = await db.rawQuery(
        "SELECT name FROM temp_db.sqlite_master "
        "WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name != 'point_id'",
      );

      // Ensure every TEMP table also exists in MAIN (partitioned tables like
      // y202507 may not exist yet if this is the first data for that month).
      for (final row in tables) {
        final tableName = row['name'] as String;
        final exists = await db.rawQuery(
          "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
          [tableName],
        );
        if (exists.isEmpty) {
          final schema = await db.rawQuery(
            "SELECT sql FROM temp_db.sqlite_master WHERE type='table' AND name=?",
            [tableName],
          );
          if (schema.isNotEmpty) {
            await db.execute(
              (schema.first['sql'] as String).replaceFirst(
                'CREATE TABLE',
                'CREATE TABLE IF NOT EXISTS',
              ),
            );
          }
        }
      }

      // Downloaded trend tables lack the local unique index.
      // Add a non-unique index to accelerate recovery without rejecting old rows.
      if (database == BackupDatabase.trend) {
        final timer = Stopwatch()..start();
        for (final row in tables) {
          final tableName = row['name'] as String;
          final indexName = 'idx_recovery_${tableName}_date_id';
          await db.execute(
            'CREATE INDEX IF NOT EXISTS "$indexName" '
            'ON "$tableName" (date, id)',
          );
        }
        timer.stop();
        FileLogService().log(
          '[Recovery] Trend (date, id) indexes ready for '
          '${tables.length} table(s) in ${timer.elapsedMilliseconds}ms',
        );
      }

      await db.transaction((txn) async {
        for (final row in tables) {
          final tableName = row['name'] as String;
          // Controller gap-fill values take precedence over overlapping TEMP deltas.
          // These tables need NOT EXISTS because they lack UNIQUE(date, id).
          final conditions = <String>[
            if (from != null) 't.date >= ${_toDbInt(from)}',
            if (to != null) 't.date < ${_toDbInt(to)}',
            'NOT EXISTS (SELECT 1 FROM "$tableName" m'
                ' WHERE m.date = t.date AND m.id = t.id)',
          ];
          final whereStr = conditions.isEmpty
              ? ''
              : ' WHERE ${conditions.join(' AND ')}';
          await txn.execute(
            'INSERT INTO "$tableName"'
            ' SELECT t.* FROM temp_db."$tableName" t$whereStr'
            ' ORDER BY t.date, t.id',
          );
        }
      });

      await db.execute('DETACH temp_db');
      FileLogService().log(
        '[Recovery] Flushed "${database.type}" '
        '[${from ?? "start"}, ${to ?? "end"}] (direct copy)',
      );
    } finally {
      await db.close();
    }
  }

  /// Syncs new points into MAIN and patches TEMP rows when IDs differ.
  Future<void> _syncNewPointsInTemp(
    String mainPath,
    String tempPath,
    String dbType,
  ) async {
    final mainDb = await databaseFactoryFfi.openDatabase(
      mainPath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      await mainDb.execute('ATTACH ? AS temp_db', [tempPath]);

      // Find TEMP points absent from MAIN.
      final newRows = await mainDb.rawQuery(
        'SELECT t.db_id AS temp_id, t.id AS str_id '
        'FROM temp_db.point_id t '
        'WHERE NOT EXISTS (SELECT 1 FROM point_id m WHERE m.id = t.id)',
      );

      if (newRows.isEmpty) {
        await mainDb.execute('DETACH temp_db');
        return;
      }

      // Insert new points into MAIN — trend point_id also has a `type` column.
      final cols = dbType == 'trend' ? '(id, type)' : '(id)';
      final sel = dbType == 'trend' ? 't.id, t.type' : 't.id';
      await mainDb.execute(
        'INSERT OR IGNORE INTO point_id $cols '
        'SELECT $sel FROM temp_db.point_id t '
        'WHERE NOT EXISTS (SELECT 1 FROM point_id m WHERE m.id = t.id)',
      );

      // Build remap for any assignments that diverged.
      final remap = <int, int>{}; // temp_db_id → main_db_id
      for (final p in newRows) {
        final tempId = p['temp_id'] as int;
        final strId = p['str_id'] as String;
        final r = await mainDb.rawQuery(
          'SELECT db_id FROM point_id WHERE id=?',
          [strId],
        );
        if (r.isNotEmpty) {
          final mainId = r.first['db_id'] as int;
          if (mainId != tempId) remap[tempId] = mainId;
        }
      }

      await mainDb.execute('DETACH temp_db');

      if (remap.isEmpty) {
        FileLogService().log(
          '[Recovery] Synced ${newRows.length} new point(s) for $dbType (no db_id conflict)',
        );
        return;
      }

      // Patch TEMP: update data rows and point_id to use MAIN's db_id values.
      final tempDb = await databaseFactoryFfi.openDatabase(
        tempPath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      try {
        final tables = await tempDb.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name NOT LIKE 'sqlite_%' AND name != 'point_id'",
        );
        await tempDb.transaction((txn) async {
          for (final row in tables) {
            final tableName = row['name'] as String;
            for (final entry in remap.entries) {
              await txn.execute('UPDATE "$tableName" SET id=? WHERE id=?', [
                entry.value,
                entry.key,
              ]);
            }
          }
          for (final entry in remap.entries) {
            await txn.execute('UPDATE point_id SET db_id=? WHERE db_id=?', [
              entry.value,
              entry.key,
            ]);
          }
        });
        FileLogService().log(
          '[Recovery] Synced ${newRows.length} new point(s) for $dbType (remapped ${remap.length} db_id conflict(s))',
        );
      } finally {
        await tempDb.close();
      }
    } catch (e) {
      FileLogService().log(
        '[Recovery] _syncNewPointsInTemp failed for $dbType: $e',
      );
    } finally {
      await mainDb.close();
    }
  }

  /// Flushes one TEMP window after its gap-fill; null [to] means through the end.
  Future<void> flushTempWindowToMain(
    BackupDatabase database,
    DateTime? from,
    DateTime? to,
  ) => _synchronized(() async {
    final dbFile = database.fileName;
    final mainPath = '$_mainDbDir\\$dbFile';
    final tempPath = '$_tempDbDir\\$dbFile';
    if (!await File(tempPath).exists() || !await File(mainPath).exists())
      return;
    await _flushSingleDbWindow(mainPath, tempPath, database, from, to);
  });

  /// Reopens app.db on TEMP or MAIN after a failed flush closed its handles.
  Future<void> reopenAfterFailedFlush() => _synchronized(() async {
    if (hasActiveGap) {
      await _meta.markFlushPending(_tempDbDir);
    }
    await app.setDbPath(hasActiveGap ? _tempDbDir : _mainDbDir);
    await _openAllDbs();
    FileLogService().log(
      '[Recovery] Reopened DB after failed flush → ${hasActiveGap ? "TEMP" : "MAIN"}',
    );
  });

  /// Reopens MAIN before catch-up so new realtime packets have a live target.
  /// Metadata remains in-progress until catch-up and cleanup both finish.
  Future<void> switchToMainForCatchUp() => _synchronized(() async {
    FileLogService().log('[Recovery] Gap merge complete — switching to MAIN');
    await _switchToMainDbImpl();
  });

  /// Completes metadata after catch-up and removes the now-inactive TEMP DB.
  /// A third-party SQLite viewer may temporarily lock TEMP on Windows; cleanup
  /// is retried and then deferred without invalidating an otherwise-good merge.
  Future<void> finalizeFlushedCleanup() => _synchronized(() async {
    final deleted = await _deleteTempDbWithRetry();
    await _meta.markFlushCompleted();
    FileLogService().log('[Recovery] Flush complete — MAIN is active');
    if (!deleted) {
      FileLogService().log(
        '[Recovery] TEMP cleanup deferred; the inactive folder is still locked',
      );
    }
  });

  Future<bool> _deleteTempDbWithRetry() async {
    final tempDir = Directory(_tempDbDir);
    if (!await tempDir.exists()) return true;

    Object? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        await tempDir.delete(recursive: true);
        FileLogService().log('[Recovery] TEMP DB deleted');
        return true;
      } catch (error) {
        lastError = error;
        FileLogService().log(
          '[Recovery] TEMP delete attempt $attempt/3 failed: $error',
        );
        if (attempt < 3) {
          await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
        }
      }
    }
    FileLogService().log('[Recovery] TEMP DB remains on disk: $lastError');
    return false;
  }

  /// Opens and initialises the current real-time write target. Interrupted or
  /// pending recovery sessions stay on TEMP; healthy sessions use MAIN.
  Future<void> openActiveRealtimeDb() => _synchronized(() async {
    await app.setDbPath(hasActiveGap ? _tempDbDir : _mainDbDir);
    await _openAllDbs();
    if (hasActiveGap) await _seedMeterValueCache();
  });

  /// Normalizes TEMP history fields and JSON before copying them to MAIN.
  /// Deduplication ignores `data` so formatting variants do not duplicate events.
  Future<void> _flushHistoryDb(
    String mainPath,
    String tempPath, {
    DateTime? from,
    DateTime? to,
  }) async {
    final tempDb = await databaseFactoryFfi.openDatabase(
      tempPath,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    final db = await databaseFactoryFfi.openDatabase(
      mainPath,
      options: OpenDatabaseOptions(readOnly: false, singleInstance: false),
    );
    try {
      final tables = await tempDb.rawQuery(
        "SELECT name FROM sqlite_master "
        "WHERE type='table' AND name NOT LIKE 'sqlite_%'",
      );
      for (final tRow in tables) {
        final tableName = tRow['name'] as String;

        // Ensure the table exists in MAIN (new monthly partition in TEMP).
        final mainHas = await db.rawQuery(
          "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
          [tableName],
        );
        if (mainHas.isEmpty) {
          final schema = await tempDb.rawQuery(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name=?",
            [tableName],
          );
          if (schema.isNotEmpty) {
            await db.execute(
              (schema.first['sql'] as String).replaceFirst(
                'CREATE TABLE',
                'CREATE TABLE IF NOT EXISTS',
              ),
            );
          }
        }

        // Detect optional 'who' column.
        final cols = await tempDb.rawQuery("PRAGMA table_info('$tableName')");
        final hasWho = cols.any((c) => (c['name'] as String?) == 'who');

        final where = _dateWhere('date', from, to);
        final whereClause = where.isEmpty ? '' : ' WHERE $where';
        final rows = await tempDb.rawQuery(
          'SELECT * FROM "$tableName"$whereClause ORDER BY date, type, com, id',
        );
        if (rows.isEmpty) continue;

        await db.transaction((txn) async {
          for (final row in rows) {
            final date = row['date'];
            final type = _normalizeHistoryField(row['type']);
            final com = _normalizeHistoryField(row['com']);
            final id = _normalizeHistoryField(row['id']);
            final data = _normalizeHistoryData(row['data']);
            // COALESCE handles existing NULL-com rows in MAIN so they are
            // matched by the normalised '' com value.
            const notExists =
                " WHERE NOT EXISTS ("
                "  SELECT 1 FROM \"{t}\""
                "  WHERE date=? AND type=? AND COALESCE(com,'')=? AND COALESCE(id,'')=?"
                ")";
            if (hasWho) {
              final who = _normalizeHistoryField(row['who']);
              await txn.execute(
                'INSERT INTO "$tableName" (date, type, com, id, data, who)'
                        ' SELECT ?, ?, ?, ?, ?, ?' +
                    notExists.replaceAll('{t}', tableName),
                [date, type, com, id, data, who, date, type, com, id],
              );
            } else {
              await txn.execute(
                'INSERT INTO "$tableName" (date, type, com, id, data)'
                        ' SELECT ?, ?, ?, ?, ?' +
                    notExists.replaceAll('{t}', tableName),
                [date, type, com, id, data, date, type, com, id],
              );
            }
          }
        });
        FileLogService().log(
          '[Recovery] Flushed history "$tableName": ${rows.length} row(s) (normalised)',
        );
      }
    } finally {
      await tempDb.close();
      await db.close();
    }
  }

  /// Converts [DateTime] to the YYYYMMDDHHmm integer used in DB date columns.
  static int _toDbInt(DateTime dt) =>
      dt.year * 100000000 +
      dt.month * 1000000 +
      dt.day * 10000 +
      dt.hour * 100 +
      dt.minute;

  /// Builds a SQL WHERE fragment for an integer date column, e.g.
  /// `col >= 202606150900 AND col < 202606151500`.
  static String _dateWhere(String col, DateTime? from, DateTime? to) {
    final parts = <String>[];
    if (from != null) parts.add('$col >= ${_toDbInt(from)}');
    if (to != null) parts.add('$col < ${_toDbInt(to)}');
    return parts.join(' AND ');
  }

  Future<void> _switchToMainDbImpl() async {
    await app.setDbPath(_mainDbDir);
    await _openAllDbs();
    FileLogService().log('[Recovery] Switched to MAIN DB at $_mainDbDir');
  }

  /// Writes controller [records] to MAIN without disturbing app.db on TEMP.
  Future<void> fillGapInMainDb(
    BackupDatabase database,
    List<dynamic> records, {
    DateTime? deleteFrom,
  }) => _synchronized(
    () => _fillGapInMainDbImpl(database, records, deleteFrom: deleteFrom),
  );

  Future<void> _fillGapInMainDbImpl(
    BackupDatabase database,
    List<dynamic> records, {
    DateTime? deleteFrom,
  }) async {
    if (records.isEmpty) return;
    final dbFile = database.fileName;
    final mainPath = '$_mainDbDir\\$dbFile';
    if (!await File(mainPath).exists()) {
      FileLogService().log(
        '[Recovery] Gap-fill: MAIN file missing, skip $dbFile',
      );
      return;
    }

    // Open MAIN file by full path — does NOT affect app.db (TEMP path).
    final rawDb = await databaseFactoryFfi.openDatabase(
      mainPath,
      options: OpenDatabaseOptions(readOnly: false, singleInstance: false),
    );
    final mainDb = ReiriDb();
    mainDb.db[database.type] = rawDb;
    try {
      // Sort AFTER init so the loaded point_id mapping can be used to order
      // records by integer db_id (matching the original DB's insertion order).
      switch (database) {
        case BackupDatabase.trend:
          await mainDb.initTrendDb();
          final pointList = mainDb.trendDb['pointList'] as Map;
          final sorted = List<dynamic>.from(records)
            ..sort((a, b) {
              final cmpDate = (a[0] as int).compareTo(b[0] as int);
              if (cmpDate != 0) return cmpDate;
              final aMap = pointList[a[1].toString()];
              final bMap = pointList[b[1].toString()];
              final aId = aMap is Map ? aMap[a[2].toString()] as int? : null;
              final bId = bMap is Map ? bMap[b[2].toString()] as int? : null;
              if (aId != null && bId != null) return aId.compareTo(bId);
              if (aId != null) return -1;
              if (bId != null) return 1;
              return a[1].toString().compareTo(b[1].toString());
            });
          await mainDb.addTrendData(sorted);
        case BackupDatabase.meter:
          await mainDb.initMeterDb();
          final sorted = _sortByDbId(
            records,
            mainDb.meterDb['pointList'] as Map<String, int>,
          );
          await mainDb.addMeterData(sorted);
        case BackupDatabase.optime:
          await mainDb.initOptimeDb();
          final sorted = _sortByDbId(
            records,
            mainDb.optimeDb['pointList'] as Map<String, int>,
          );
          await mainDb.addOptimeData(sorted);
        case BackupDatabase.ppd:
          await mainDb.initPpdDb();
          final sorted = _sortByDbId(
            records,
            mainDb.ppdDb['pointList'] as Map<String, int>,
          );
          await mainDb.addPpdData(sorted);
        case BackupDatabase.history:
          await mainDb.initHistoryDb();
          if (deleteFrom != null) {
            final fromInt = _dateTimeToDbInt(deleteFrom);
            for (final tbl in [
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
            ]) {
              await rawDb.execute('DELETE FROM $tbl WHERE date >= $fromInt');
            }
            FileLogService().log(
              '[Recovery] Gap-fill: cleared history records >= $fromInt from MAIN',
            );
          }
          final processed = records.map((rec) {
            final r = List<dynamic>.from(rec as List);
            r[2] = _normalizeHistoryField(r[2]); // com
            r[4] = _normalizeHistoryData(r[4]); // data
            if (r.length > 5) r[5] = _normalizeHistoryField(r[5]); // who
            return r;
          }).toList();
          await mainDb.addHistoryData(processed);
      }
      FileLogService().log(
        '[Recovery] Gap-fill: wrote ${records.length} record(s) → $dbFile',
      );
    } catch (e) {
      FileLogService().log('[Recovery] Gap-fill: write error for $dbFile: $e');
      // Abort so a failed write cannot clear its gap or delete TEMP.
      rethrow;
    } finally {
      await rawDb.close();
      mainDb.db.remove(database.type);
    }
  }

  /// Sorts gap records by date, known point ID, then new string ID.
  static List<dynamic> _sortByDbId(
    List<dynamic> records,
    Map<String, int> pointList,
  ) {
    return List<dynamic>.from(records)..sort((a, b) {
      final cmpDate = (a[0] as int).compareTo(b[0] as int);
      if (cmpDate != 0) return cmpDate;
      final aId = pointList[a[1].toString()];
      final bId = pointList[b[1].toString()];
      if (aId != null && bId != null) return aId.compareTo(bId);
      if (aId != null) return -1;
      if (bId != null) return 1;
      return a[1].toString().compareTo(b[1].toString());
    });
  }

  /// Computes the next scheduled flush time for the given [hour] and [minute].
  /// Returns today's time if it hasn't passed yet, otherwise tomorrow's.
  static DateTime nextOffPeakTime({int hour = 3, int minute = 0}) {
    final now = DateTime.now();
    final todayAt = DateTime(now.year, now.month, now.day, hour, minute);
    return now.isBefore(todayAt)
        ? todayAt
        : todayAt.add(const Duration(days: 1));
  }

  /// Reopens MAIN so app.db caches include direct recovery writes.
  Future<void> reinitMainDb() => _synchronized(_openAllDbs);

  /// Keeps the earliest MAIN row for each duplicated `(date, id)` pair.
  Future<void> deduplicateInMain(
    BackupDatabase database,
  ) => _synchronized(() async {
    final dbFile = database.fileName;
    final mainPath = '$_mainDbDir\\$dbFile';
    if (!await File(mainPath).exists()) return;
    final db = await databaseFactoryFfi.openDatabase(
      mainPath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name NOT LIKE 'sqlite_%' AND name != 'point_id'",
      );
      for (final row in tables) {
        final tableName = row['name'] as String;
        final cols = await db.rawQuery("PRAGMA table_info('$tableName')");
        final colNames = cols.map((c) => c['name'] as String).toSet();
        if (!colNames.contains('date') || !colNames.contains('id')) continue;
        final before =
            (await db.rawQuery(
                  'SELECT COUNT(*) AS n FROM "$tableName"',
                )).first['n']
                as int? ??
            0;
        await db.execute(
          'DELETE FROM "$tableName" WHERE rowid NOT IN ('
          ' SELECT MIN(rowid) FROM "$tableName" GROUP BY date, id'
          ')',
        );
        final after =
            (await db.rawQuery(
                  'SELECT COUNT(*) AS n FROM "$tableName"',
                )).first['n']
                as int? ??
            0;
        if (before != after) {
          FileLogService().log(
            '[Recovery] Dedup $dbFile "$tableName": removed ${before - after} duplicate(s)',
          );
        }
      }
    } catch (e) {
      FileLogService().log(
        '[Recovery] deduplicateInMain failed for $dbFile: $e',
      );
    } finally {
      await db.close();
    }
  });

  /// Refreshes meter baselines through a separate read-only MAIN connection.
  /// Live app.db handles remain open for concurrent realtime writes.
  Future<void> refreshMeterValueCacheFromMain() => _synchronized(() async {
    final reiriDb = app.db;
    if (reiriDb == null) return;
    final valueCache = reiriDb.meterDb['value'];
    if (valueCache is! Map) return;

    final mainPath = '$_mainDbDir\\${BackupDatabase.meter.fileName}';
    if (!await File(mainPath).exists()) return;

    final db = await databaseFactoryFfi.openDatabase(
      mainPath,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      final rows = await db.rawQuery(
        'SELECT m.id AS db_id, m.value AS value FROM meter m '
        'JOIN (SELECT id, MAX(date) AS md FROM meter GROUP BY id) x '
        'ON m.id = x.id AND m.date = x.md',
      );
      for (final r in rows) {
        valueCache['${r['db_id']}'] = (r['value'] as num).toDouble();
      }
    } catch (e) {
      FileLogService().log(
        '[Recovery] refreshMeterValueCacheFromMain failed: $e',
      );
    } finally {
      await db.close();
    }
  });

  // ── helpers ────────────────────────────────────────────────────────────────

  // ── History data normalisation ────────────────────────────────────────────

  /// Converts a [DateTime] to the 12-digit integer (YYYYMMDDHHmm) used as the
  /// `date` column value in all history monthly tables.
  static int _dateTimeToDbInt(DateTime dt) =>
      dt.year * 100000000 +
      dt.month * 1000000 +
      dt.day * 10000 +
      dt.hour * 100 +
      dt.minute;

  /// Null or the string "null" → '' so addHistoryData's raw string
  /// interpolation (`'${line[n]}'`) stores an empty string, not "null".
  static String _normalizeHistoryField(dynamic v) {
    if (v == null) return '';
    final s = v.toString();
    return s == 'null' ? '' : s;
  }

  /// Converts controller map notation to source-compatible JSON.
  /// Null and empty event data remain empty strings.
  static String _normalizeHistoryData(dynamic v) {
    if (v == null) return '';
    if (v is! String) return jsonEncode(v);
    final s = v.trim();
    if (s.isEmpty || s == 'null') return '';
    try {
      jsonDecode(s);
      return s;
    } catch (_) {}
    return _dartMapToJson(s);
  }

  /// Converts nested Dart map notation to valid JSON.
  static String _dartMapToJson(String s) {
    s = s.trim();
    if (!s.startsWith('{') || !s.endsWith('}')) return '"$s"';
    final inner = s.substring(1, s.length - 1).trim();
    if (inner.isEmpty) return '{}';
    // Split on top-level commas, respecting nested braces.
    final pairs = <String>[];
    int depth = 0, start = 0;
    for (int i = 0; i < inner.length; i++) {
      final ch = inner[i];
      if (ch == '{' || ch == '[')
        depth++;
      else if (ch == '}' || ch == ']')
        depth--;
      else if (ch == ',' && depth == 0) {
        pairs.add(inner.substring(start, i).trim());
        start = i + 1;
      }
    }
    pairs.add(inner.substring(start).trim());
    final parts = <String>[];
    for (final pair in pairs) {
      final colon = pair.indexOf(':');
      if (colon < 0) continue;
      final key = pair.substring(0, colon).trim();
      final val = pair.substring(colon + 1).trim();
      parts.add('"$key":${_jsonifyHistoryVal(val)}');
    }
    return '{${parts.join(',')}}';
  }

  static String _jsonifyHistoryVal(String val) {
    if (val == 'null') return '""';
    if (val == 'true' || val == 'false') return val;
    if (int.tryParse(val) != null || double.tryParse(val) != null) return val;
    if (val.startsWith('{') && val.endsWith('}')) return _dartMapToJson(val);
    return '"$val"';
  }

  Future<void> _openAllDbs() async {
    if (app.db == null) return;
    await app.db!.openHistoryDb();
    await app.db!.initHistoryDb();
    await app.db!.openMeterDb();
    await app.db!.initMeterDb();
    await app.db!.openOptimeDb();
    await app.db!.initOptimeDb();
    await app.db!.openPpdDb();
    await app.db!.initPpdDb();
    await app.db!.openTrendDb();
    await app.db!.initTrendDb();
  }

  /// Close all open DB handles held by [ReiriDb].
  Future<void> _closeAllDbs() async {
    final reiriDb = app.db;
    if (reiriDb == null) return;
    for (final db in reiriDb.db.values) {
      try {
        await db.close();
      } catch (_) {}
    }
    reiriDb.db.clear();
  }
}
