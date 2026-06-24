import 'dart:async';
import 'dart:convert';
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

  // ── Operation serialization ─────────────────────────────────────────────
  // Every method that opens/closes [app.db] handles or opens a second SQLite
  // connection to a DB file must run through [_synchronized]. This guarantees
  // no two structural DB operations overlap — the previous code allowed gap
  // detection to run twice concurrently (from _init AND the connection
  // listener), so one path could close a handle while another was mid-open,
  // producing a use-after-close native crash (consistently on optime.db,
  // leaving a stale optime.db-journal).
  Future<void> _opChain = Future.value();

  /// Runs [action] after all previously-queued operations finish, so structural
  /// DB work is strictly serialized. Errors in one action do not break the
  /// chain for the next.
  Future<T> _synchronized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final prev = _opChain;
    _opChain = completer.future.then((_) {}, onError: (_) {});
    prev.whenComplete(() {
      action().then(completer.complete).catchError(
          (Object e, StackTrace s) => completer.completeError(e, s));
    });
    return completer.future;
  }

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
      await _synchronized(_doFlush);
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
  Future<List<GapRange>> onConnected() =>
      _synchronized(_onConnectedImpl);

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
      // Record that TEMP is the active write target. Keep flushStatus=pending —
      // markFlushInProgress is called only when _doFlush actually starts, so
      // a subsequent login while waiting for the scheduled flush does NOT trigger
      // the crash-recovery auto-flush in init().
      await _meta.saveTempPath(_tempDbDir);
      if (wasInTemp) {
        FileLogService().log(
            '[Recovery] Resuming existing TEMP DB (${allGaps.length} gap(s) pending)');
      } else {
        FileLogService().log(
            '[Recovery] Gap detected (${allGaps.length} DBs affected). Routing real-time → TEMP DB');
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
    // Seed TEMP's point_id from MAIN on first creation so flush can use a
    // direct ATTACH copy without a JOIN remap.  Skip on resume (TEMP already
    // has accumulated realtime data whose db_ids reference TEMP's point_id).
    if (isNew) {
      // Close app.db's handles first: _seedPointIdFromMain opens its own
      // connection to these same TEMP files, and two live FFI connections
      // writing one DB file is what crashes optime.db (locked / native abort,
      // leaving a stale optime.db-journal). After seeding, reopen and re-init
      // so app.db's in-memory point caches (optimeDb/meterDb/…) reflect the
      // seeded point_id — otherwise the first realtime insert reuses db_id=1
      // and hits the UNIQUE(id) collision on the un-try/caught point_id insert.
      await _closeAllDbs();
      await _seedPointIdFromMain();
      await app.setDbPath(_tempDbDir);
      await _openAllDbs();
    }
    // TEMP's meter table is empty right after staging, so initMeterDb leaves
    // app.db.meterDb['value'] empty. The first realtime meter row is for a
    // seeded point_id, so addRealtimeMeterData skips the new-point branch and
    // evaluates `meterDb['value'][dbId] < 0` on a null entry → throws and
    // crashes the realtime write (meter is the only DB with this last-value
    // cache, which is why it's always meter). Pre-fill the cache from MAIN's
    // last values so the comparison is safe and the first post-gap amount is
    // computed against MAIN's real last value (see docs/issues-and-solutions.md
    // Issue 3).
    await _seedMeterValueCache();
  }

  /// Pre-populates [app.db]'s in-memory meter last-value cache
  /// (`meterDb['value']`, keyed by db_id string) from MAIN's most recent meter
  /// rows. Only fills entries that are missing so it never clobbers a newer
  /// value already accumulated in a resumed TEMP session.
  Future<void> _seedMeterValueCache() async {
    final reiriDb = app.db;
    if (reiriDb == null) return;
    final valueCache = reiriDb.meterDb['value'];
    if (valueCache is! Map) return;

    final mainPath = '$_mainDbDir\\meter.db';
    if (!await File(mainPath).exists()) return;

    final db = await databaseFactoryFfi.openDatabase(
      mainPath,
      options: OpenDatabaseOptions(readOnly: true),
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
      // Backfill any seeded point that has no MAIN value row yet with the
      // "unknown" sentinel (-1) so addRealtimeMeterData never compares null,
      // even when MAIN's meter table has no data for that point.
      final pointList = reiriDb.meterDb['pointList'];
      if (pointList is Map) {
        for (final dbId in pointList.values) {
          final key = '$dbId';
          if (valueCache[key] == null) valueCache[key] = -1;
        }
      }
      FileLogService().log('[Recovery] Seeded meter value cache from MAIN ($filled point(s))');
    } catch (e) {
      FileLogService().log('[Recovery] _seedMeterValueCache failed: $e');
    } finally {
      await db.close();
    }
  }

  /// Copies MAIN's point_id table into each surrogate-key TEMP DB so that
  /// realtime writes and the subsequent flush share the same db_id mapping.
  Future<void> _seedPointIdFromMain() async {
    for (final type in const ['meter', 'optime', 'ppd', 'trend']) {
      final mainPath = '$_mainDbDir\\${_dbTypeToFile(type)}';
      final tempPath = '$_tempDbDir\\${_dbTypeToFile(type)}';
      if (!await File(mainPath).exists()) continue;
      final tempDb = await databaseFactoryFfi.openDatabase(tempPath);
      try {
        await tempDb.execute('ATTACH ? AS main_db', [mainPath]);
        await tempDb.transaction((txn) async {
          await txn.execute('DELETE FROM point_id');
          await txn.execute('INSERT INTO point_id SELECT * FROM main_db.point_id');
        });
        await tempDb.execute('DETACH main_db');
        FileLogService().log('[Recovery] Seeded point_id for $type from MAIN');
      } catch (e) {
        FileLogService().log('[Recovery] _seedPointIdFromMain failed for $type: $e');
      } finally {
        await tempDb.close();
      }
    }
  }

  /// Closes all DB handles held by [app.db].  Call before flush so that
  /// [_syncNewPointsInTemp] can write to TEMP without competing with the
  /// realtime [app.db] writer.  [finalizeFlushedCleanup] → [switchToMainDb]
  /// reopens everything on MAIN when the flush is done.
  Future<void> suspendRealtime() => _synchronized(_closeAllDbs);

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
    await _synchronized(_doFlush);
  }

  Future<void> _doFlush() async {
    // Set inProgress before touching any files — this is the crash-recovery
    // checkpoint that init() checks. If the app is killed after this line but
    // before markFlushCompleted(), the next startup will resume the flush.
    await _meta.markFlushInProgress(_tempDbDir);
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

        final dbType = fileToDbType(dbFile);
        if (dbType == null) {
          FileLogService().log('[Recovery] No flush handler for $dbFile, skipping');
          continue;
        }

        await _flushSingleDb(mainPath, tempPath, dbType);
      }

      await _meta.markFlushCompleted();
      FileLogService().log('[Recovery] Flush complete — switching to MAIN DB');

      await _switchToMainDbImpl();

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

  /// Flushes TEMP DB rows for [dbType] into MAIN DB.
  ///
  /// `meter`/`trend`/`optime`/`ppd` store data rows keyed by a surrogate
  /// `db_id` from their own `point_id` table. TEMP's `point_id` table is
  /// built independently (starting at 1) while routing real-time writes
  /// during a gap, so its `db_id` values do not match MAIN's mapping for the
  /// same physical point. A raw row copy would therefore duplicate each
  /// point's data under a different (wrong) id.
  ///
  /// To keep `point_id` consistent with MAIN, TEMP's rows are read back
  /// together with TEMP's `point_id` to recover the original string id, then
  /// replayed through `addXxxData` so MAIN resolves/assigns the correct
  /// MAIN-side `db_id` (creating a new entry only if the point is genuinely
  /// new to MAIN). TEMP's `point_id` table itself is never copied.
  ///
  /// `history.db` has no `point_id` surrogate key, so it uses a plain
  /// `INSERT OR IGNORE ... SELECT *` via ATTACH.
  Future<void> _flushSingleDb(String mainPath, String tempPath, String dbType) async {
    await _flushSingleDbWindow(mainPath, tempPath, dbType, null, null);
  }

  /// Flushes TEMP rows for [dbType] where date >= [from] and date < [to]
  /// (pass null for no bound) into MAIN DB.
  ///
  /// TEMP's point_id was seeded from MAIN at creation so db_ids already
  /// match — a direct ATTACH copy is used instead of a JOIN remap.
  /// [_syncNewPointsInTemp] handles the rare case where new controller
  /// points appeared after TEMP was created (e.g. new equipment added
  /// during a gap window) by inserting them into MAIN first and patching
  /// TEMP's data rows if db_id assignments diverged.
  Future<void> _flushSingleDbWindow(String mainPath, String tempPath,
      String dbType, DateTime? from, DateTime? to) async {
    if (dbType == 'history') {
      await _flushHistoryDb(mainPath, tempPath, from: from, to: to);
      return;
    }

    // Resolve any new points before the copy so db_ids are in sync.
    await _syncNewPointsInTemp(mainPath, tempPath, dbType);

    final db = await databaseFactoryFfi.openDatabase(mainPath);
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
              (schema.first['sql'] as String)
                  .replaceFirst('CREATE TABLE', 'CREATE TABLE IF NOT EXISTS'),
            );
          }
        }
      }

      await db.transaction((txn) async {
        for (final row in tables) {
          final tableName = row['name'] as String;
          // Gap-fill runs before this flush and stores amounts taken directly
          // from the controller (correct per-interval deltas). TEMP real-time
          // amounts can be inflated when the first post-reconnect push spans
          // multiple intervals (meterDb cache was seeded from a pre-gap
          // baseline). Use NOT EXISTS so TEMP rows are skipped for any (date,
          // id) already written by gap-fill; only genuinely new real-time rows
          // (timestamps beyond the gap window) are inserted.
          // Note: these tables have no UNIQUE(date,id) constraint, so the
          // standard INSERT OR IGNORE cannot deduplicate without this check.
          final conditions = <String>[
            if (from != null) 't.date >= ${_toDbInt(from)}',
            if (to != null)   't.date < ${_toDbInt(to)}',
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
          '[Recovery] Flushed "$dbType" [${from ?? "start"}, ${to ?? "end"}] (direct copy)');
    } finally {
      await db.close();
    }
  }

  /// Syncs new point_id entries from TEMP into MAIN, then patches TEMP's data
  /// rows if MAIN assigned different db_ids (can happen when gap-fill and
  /// realtime both encounter a brand-new controller point and assign it in a
  /// different order).  A no-op when all TEMP points already exist in MAIN
  /// (the common case after seeding at TEMP creation).
  Future<void> _syncNewPointsInTemp(
      String mainPath, String tempPath, String dbType) async {
    final mainDb = await databaseFactoryFfi.openDatabase(mainPath);
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
      final sel  = dbType == 'trend' ? 't.id, t.type' : 't.id';
      await mainDb.execute(
        'INSERT OR IGNORE INTO point_id $cols '
        'SELECT $sel FROM temp_db.point_id t '
        'WHERE NOT EXISTS (SELECT 1 FROM point_id m WHERE m.id = t.id)',
      );

      // Build remap for any assignments that diverged.
      final remap = <int, int>{}; // temp_db_id → main_db_id
      for (final p in newRows) {
        final tempId = p['temp_id'] as int;
        final strId  = p['str_id']  as String;
        final r = await mainDb.rawQuery(
          'SELECT db_id FROM point_id WHERE id=?', [strId]);
        if (r.isNotEmpty) {
          final mainId = r.first['db_id'] as int;
          if (mainId != tempId) remap[tempId] = mainId;
        }
      }

      await mainDb.execute('DETACH temp_db');

      if (remap.isEmpty) {
        FileLogService().log('[Recovery] Synced ${newRows.length} new point(s) for $dbType (no db_id conflict)');
        return;
      }

      // Patch TEMP: update data rows and point_id to use MAIN's db_id values.
      final tempDb = await databaseFactoryFfi.openDatabase(tempPath);
      try {
        final tables = await tempDb.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name NOT LIKE 'sqlite_%' AND name != 'point_id'",
        );
        await tempDb.transaction((txn) async {
          for (final row in tables) {
            final tableName = row['name'] as String;
            for (final entry in remap.entries) {
              await txn.execute(
                'UPDATE "$tableName" SET id=? WHERE id=?',
                [entry.value, entry.key],
              );
            }
          }
          for (final entry in remap.entries) {
            await txn.execute(
              'UPDATE point_id SET db_id=? WHERE db_id=?',
              [entry.value, entry.key],
            );
          }
        });
        FileLogService().log('[Recovery] Synced ${newRows.length} new point(s) for $dbType (remapped ${remap.length} db_id conflict(s))');
      } finally {
        await tempDb.close();
      }
    } catch (e) {
      FileLogService().log('[Recovery] _syncNewPointsInTemp failed for $dbType: $e');
    } finally {
      await mainDb.close();
    }
  }

  /// Flushes the TEMP DB window [from, to) for [dbType] into MAIN.
  /// Called by the interleaved flush in RecoveryNotifier.runFlushNow after
  /// each gap-fill period so rows land in MAIN in chronological order.
  /// Pass [to]=null to flush from [from] to the end of TEMP (last window).
  Future<void> flushTempWindowToMain(
      String dbType, DateTime? from, DateTime? to) => _synchronized(() async {
    final dbFile = _dbTypeToFile(dbType);
    final mainPath = '$_mainDbDir\\$dbFile';
    final tempPath = '$_tempDbDir\\$dbFile';
    if (!await File(tempPath).exists() || !await File(mainPath).exists()) return;
    await _flushSingleDbWindow(mainPath, tempPath, dbType, from, to);
  });

  /// Marks flush completed, switches to MAIN DB, and deletes the TEMP folder.
  /// Called after all interleaved gap-fill + TEMP-window writes are done.
  Future<void> finalizeFlushedCleanup() => _synchronized(() async {
    await _meta.markFlushCompleted();
    FileLogService().log('[Recovery] Flush complete — switching to MAIN DB');
    await _switchToMainDbImpl();
    final tempDir = Directory(_tempDbDir);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
      FileLogService().log('[Recovery] TEMP DB deleted');
    }
  });

  /// Flushes TEMP history rows into MAIN, normalising each row before
  /// inserting:
  ///   • com / id / who: null or the string "null" → ''
  ///   • data: Dart Map.toString() format → proper JSON
  ///
  /// Deduplicates on (date, type, com, id) via NOT EXISTS — ignoring the
  /// `data` column — so that a gap-fill row (data='{}') and a real-time TEMP
  /// row (data='') for the same event do not both land in MAIN.  SQLite's
  /// UNIQUE constraint (used by INSERT OR IGNORE) includes `data`, so it
  /// would let both variants through.  COALESCE in the NOT EXISTS clause also
  /// matches against any pre-existing NULL-com rows in MAIN.
  Future<void> _flushHistoryDb(String mainPath, String tempPath,
      {DateTime? from, DateTime? to}) async {
    final tempDb = await databaseFactoryFfi.openDatabase(
      tempPath,
      options: OpenDatabaseOptions(readOnly: true),
    );
    final db = await databaseFactoryFfi.openDatabase(
      mainPath,
      options: OpenDatabaseOptions(readOnly: false),
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
              (schema.first['sql'] as String)
                  .replaceFirst('CREATE TABLE', 'CREATE TABLE IF NOT EXISTS'),
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
            final com  = _normalizeHistoryField(row['com']);
            final id   = _normalizeHistoryField(row['id']);
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
                ' SELECT ?, ?, ?, ?, ?, ?'
                + notExists.replaceAll('{t}', tableName),
                [date, type, com, id, data, who, date, type, com, id],
              );
            } else {
              await txn.execute(
                'INSERT INTO "$tableName" (date, type, com, id, data)'
                ' SELECT ?, ?, ?, ?, ?'
                + notExists.replaceAll('{t}', tableName),
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
      dt.year * 100000000 + dt.month * 1000000 + dt.day * 10000 +
      dt.hour * 100 + dt.minute;

  /// Builds a SQL WHERE fragment for an integer date column, e.g.
  /// `col >= 202606150900 AND col < 202606151500`.
  static String _dateWhere(String col, DateTime? from, DateTime? to) {
    final parts = <String>[];
    if (from != null) parts.add('$col >= ${_toDbInt(from)}');
    if (to != null) parts.add('$col < ${_toDbInt(to)}');
    return parts.join(' AND ');
  }

  /// Redirects [app.db] back to MAIN DB.  Call after [flushTempToMain] or
  /// when the user manually dismisses a gap (e.g. gap-fill was done elsewhere).
  Future<void> switchToMainDb() => _synchronized(_switchToMainDbImpl);

  Future<void> _switchToMainDbImpl() async {
    await app.setDbPath(_mainDbDir);
    await _openAllDbs();
    FileLogService().log('[Recovery] Switched to MAIN DB at $_mainDbDir');
  }

  /// Writes [records] (from a `*_db_backup` controller response) into the
  /// MAIN DB for [dbType].  Opens a dedicated SQLite connection by absolute
  /// path so it does not interfere with [app.db], which points to TEMP during
  /// gap recovery.
  Future<void> fillGapInMainDb(String dbType, List<dynamic> records) =>
      _synchronized(() => _fillGapInMainDbImpl(dbType, records));

  Future<void> _fillGapInMainDbImpl(
      String dbType, List<dynamic> records) async {
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
      // Sort AFTER init so the loaded point_id mapping can be used to order
      // records by integer db_id (matching the original DB's insertion order).
      switch (dbType) {
        case 'trend':
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
        case 'meter':
          await mainDb.initMeterDb();
          final sorted = _sortByDbId(
              records, mainDb.meterDb['pointList'] as Map<String, int>);
          await mainDb.addMeterData(sorted);
        case 'optime':
          await mainDb.initOptimeDb();
          final sorted = _sortByDbId(
              records, mainDb.optimeDb['pointList'] as Map<String, int>);
          await mainDb.addOptimeData(sorted);
        case 'ppd':
          await mainDb.initPpdDb();
          final sorted = _sortByDbId(
              records, mainDb.ppdDb['pointList'] as Map<String, int>);
          await mainDb.addPpdData(sorted);
        case 'history':
          await mainDb.initHistoryDb();
          final processed = records.map((rec) {
            final r = List<dynamic>.from(rec as List);
            r[2] = _normalizeHistoryField(r[2]);  // com
            r[4] = _normalizeHistoryData(r[4]);   // data
            if (r.length > 5) r[5] = _normalizeHistoryField(r[5]); // who
            return r;
          }).toList();
          await mainDb.addHistoryData(processed);
      }
      FileLogService().log('[Recovery] Gap-fill: wrote ${records.length} record(s) → $dbFile');
    } catch (e) {
      FileLogService().log('[Recovery] Gap-fill: write error for $dbFile: $e');
    } finally {
      await rawDb.close();
      mainDb.db.remove(dbType);
    }
  }

  /// Sorts gap-fill records `[date, string_id, ...]` by date then by integer
  /// db_id from [pointList]. Records for new points (not yet in point_id) sort
  /// after known points; ties within new points break by string_id.
  static List<dynamic> _sortByDbId(
      List<dynamic> records, Map<String, int> pointList) {
    return List<dynamic>.from(records)
      ..sort((a, b) {
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

  /// Computes the next scheduled flush time for the given [hour] and [minute].
  /// Returns today's time if it hasn't passed yet, otherwise tomorrow's.
  static DateTime nextOffPeakTime({int hour = 3, int minute = 0}) {
    final now = DateTime.now();
    final todayAt = DateTime(now.year, now.month, now.day, hour, minute);
    return now.isBefore(todayAt)
        ? todayAt
        : todayAt.add(const Duration(days: 1));
  }

  /// Re-opens and re-initialises all MAIN DB files so in-memory caches
  /// (e.g. trendDb, meterDb) reflect any rows that were written directly to
  /// the DB files by catch-up or gap-fill after the last [_openAllDbs] call.
  /// Call this after [finalizeFlushedCleanup] + catch-up writes are done so
  /// subsequent realtime [app.db] writes see the correct post-flush state.
  Future<void> reinitMainDb() => _synchronized(_openAllDbs);

  /// Removes duplicate rows from every data table in the MAIN [dbFile], keeping
  /// only the earliest rowid for each (date, id) pair.  Duplicates can appear
  /// when overlapping gap-fill windows both request the same boundary record
  /// (e.g. multi-period meter/optime where period-1's extended `to` and
  /// period-2's `_prevBoundary` both land on the same 15-min stamp), or when a
  /// catch-up write and a TEMP-flush write land the same boundary record.
  Future<void> deduplicateInMain(String dbFile) => _synchronized(() async {
    final mainPath = '$_mainDbDir\\$dbFile';
    if (!await File(mainPath).exists()) return;
    final db = await databaseFactoryFfi.openDatabase(mainPath);
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
        final before = (await db.rawQuery(
            'SELECT COUNT(*) AS n FROM "$tableName"')).first['n'] as int? ?? 0;
        await db.execute(
          'DELETE FROM "$tableName" WHERE rowid NOT IN ('
          ' SELECT MIN(rowid) FROM "$tableName" GROUP BY date, id'
          ')',
        );
        final after = (await db.rawQuery(
            'SELECT COUNT(*) AS n FROM "$tableName"')).first['n'] as int? ?? 0;
        if (before != after) {
          FileLogService().log(
              '[Recovery] Dedup $dbFile "$tableName": removed ${before - after} duplicate(s)');
        }
      }
    } catch (e) {
      FileLogService().log('[Recovery] deduplicateInMain failed for $dbFile: $e');
    } finally {
      await db.close();
    }
  });

  /// Convenience wrapper kept for callers that already reference this by name.
  Future<void> deduplicateTrendInMain() => deduplicateInMain('trend.db');

  // ── helpers ────────────────────────────────────────────────────────────────

  // ── History data normalisation ────────────────────────────────────────────

  /// Null or the string "null" → '' so addHistoryData's raw string
  /// interpolation (`'${line[n]}'`) stores an empty string, not "null".
  static String _normalizeHistoryField(dynamic v) {
    if (v == null) return '';
    final s = v.toString();
    return s == 'null' ? '' : s;
  }

  /// Ensures the history `data` payload is stored as valid JSON.
  ///
  /// The controller returns `data` as Dart Map.toString() notation
  /// (e.g. `{comm_stat: false}`) rather than proper JSON.  Keys are
  /// unquoted; string values are unquoted; booleans/numbers are correct.
  /// This converts to `{"comm_stat":false}` so the DB matches the
  /// format written by the initial FTP/local-import backup.
  static String _normalizeHistoryData(dynamic v) {
    if (v == null) return '{}';
    if (v is! String) return jsonEncode(v);
    final s = v.trim();
    if (s.isEmpty || s == 'null') return '{}';
    try { jsonDecode(s); return s; } catch (_) {}
    return _dartMapToJson(s);
  }

  /// Converts a Dart Map.toString() string like `{key: val, key: val}` to
  /// JSON `{"key":"val","key":"val"}`.  Handles nested `{}` objects.
  /// Null values → `""`, booleans/numbers → unquoted, strings → quoted.
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
      if (ch == '{' || ch == '[') depth++;
      else if (ch == '}' || ch == ']') depth--;
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
