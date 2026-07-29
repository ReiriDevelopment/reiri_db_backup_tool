import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:reiri_db_backup_tool/lib/date_time_utils.dart';
import 'package:reiri_db_backup_tool/model/backup_metadata.dart';

export 'package:reiri_db_backup_tool/lib/date_time_utils.dart'
    show dbIntToDateTime;

/// Result of inspecting one DB file in a source folder before import.
class DbProbeResult {
  /// True if the file exists on disk.
  final bool exists;

  /// Most recent record timestamp inside the DB (null when the file is
  /// missing, empty, or unreadable).
  final DateTime? latestRecord;

  /// True if at least one scheduled write boundary for this DB falls between
  /// [latestRecord] and "now" — i.e. there is data on the controller that the
  /// imported snapshot is missing.
  final bool hasMissingData;

  /// Convenience: time between latestRecord and now (null when no record).
  final Duration? behind;

  const DbProbeResult({
    required this.exists,
    required this.latestRecord,
    required this.hasMissingData,
    required this.behind,
  });

  const DbProbeResult.missing()
      : exists = false,
        latestRecord = null,
        hasMissingData = false,
        behind = null;
}

/// Opens [dbPath] read-only, walks every user table that has a `date` column,
/// and returns the overall `max(date)` as a [DateTime].
///
/// Returns null when the file is missing/empty/unreadable, or when no `date`
/// column is found in any table. Date values are stored as 12-digit ints in
/// `YYYYMMDDHHmm` format (the same format used everywhere else in the app).
Future<DateTime?> probeLatestRecord(String dbPath) async {
  final f = File(dbPath);
  if (!await f.exists() || await f.length() == 0) return null;

  Database? db;
  try {
    db = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(readOnly: true),
    );
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master "
      "WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    );
    int latest = 0;
    for (final row in tables) {
      final name = row['name'] as String?;
      if (name == null) continue;
      // Confirm a `date` column exists before querying — some auxiliary tables
      // (point_id, etc.) do not have one.
      final cols = await db.rawQuery("PRAGMA table_info('$name')");
      final hasDate = cols.any((c) => (c['name'] as String?) == 'date');
      if (!hasDate) continue;
      try {
        final r = await db.rawQuery('SELECT max(date) AS m FROM "$name"');
        final m = r.isEmpty ? null : r.first['m'];
        if (m is int && m > latest) latest = m;
      } catch (_) {
        // Some tables may not be queryable (corrupt, schema mismatch) — skip.
      }
    }
    if (latest <= 0) return null;
    return dbIntToDateTime(latest);
  } catch (_) {
    return null;
  } finally {
    await db?.close();
  }
}

/// Probes every required interval-based DB file in [sourceFolder] and reports
/// which ones are behind the current wall-clock time.
///
/// Mirrors the gap-detection logic in [BackupMetadataService._computeGaps]:
/// for each interval-based DB we check whether at least one scheduled write
/// boundary falls between the imported snapshot's latest record and "now".
/// `history.db` is event-based — it's only treated as missing when an
/// interval-based DB is already missing data (consistent with the runtime
/// gap-detection rule).
Future<Map<String, DbProbeResult>> probeSourceFolder({
  required String sourceFolder,
  required List<String> dbFiles,
  DateTime? now,
}) async {
  final tNow = now ?? DateTime.now();
  final results = <String, DbProbeResult>{};

  for (final fname in dbFiles) {
    final path = '$sourceFolder\\$fname';
    final file = File(path);
    if (!await file.exists()) {
      results[fname] = const DbProbeResult.missing();
      continue;
    }

    final latest = await probeLatestRecord(path);
    if (latest == null) {
      results[fname] = DbProbeResult(
        exists: true,
        latestRecord: null,
        hasMissingData: false,
        behind: null,
      );
      continue;
    }

    final interval = kDbWriteIntervals[fname];
    bool missed = false;
    if (interval != null && fname != 'history.db') {
      // A record stamped T is written by the controller at (or very shortly
      // after) T — both instantaneous-reading DBs (trend) and accumulated DBs
      // (meter/optime/ppd, where T is the END of the [T-interval, T] window)
      // are available as soon as the clock passes T.  A previous version added
      // one extra interval as a buffer, but that made the probe blind to any
      // record written in that window (e.g. trend stamped 17:35, FTP downloaded
      // trend.db at 17:34, probe ran at 17:35:12 → 17:35+5=17:40 > 17:35:12
      // → not flagged → data permanently lost).
      final nextRecordStamp = _nextBoundary(latest, interval.inMinutes);
      missed = nextRecordStamp.isBefore(tNow);
    }
    results[fname] = DbProbeResult(
      exists: true,
      latestRecord: latest,
      hasMissingData: missed,
      behind: tNow.difference(latest),
    );
  }

  // history.db piggy-backs on the interval-DB check.
  if (dbFiles.contains('history.db')) {
    final anyMiss = results.entries
        .where((e) => e.key != 'history.db')
        .any((e) => e.value.hasMissingData);
    final h = results['history.db'];
    if (h != null && h.exists && h.latestRecord != null && anyMiss) {
      results['history.db'] = DbProbeResult(
        exists: true,
        latestRecord: h.latestRecord,
        hasMissingData: true,
        behind: h.behind,
      );
    }
  }

  return results;
}

/// Builds the list of [GapRange] entries that should be written into
/// `backup_metadata.json` immediately after an import, so the next
/// `RecoveryService.onConnected()` sees them and routes real-time to TEMP DB.
///
/// Each gap spans `latestRecord → now` for the corresponding file. Only files
/// with [DbProbeResult.hasMissingData] are included.
List<GapRange> probeResultsToGaps(
  Map<String, DbProbeResult> probe, {
  DateTime? now,
}) {
  final tNow = now ?? DateTime.now();
  final gaps = <GapRange>[];
  for (final entry in probe.entries) {
    final fname = entry.key;
    final r = entry.value;
    if (!r.hasMissingData || r.latestRecord == null) continue;
    // For interval-based DBs the latest record is already captured — the first
    // truly missing timestamp is one interval later. history.db is event-based,
    // so the start stays at the latest event.
    final interval = kDbWriteIntervals[fname];
    final start = (interval != null && fname != 'history.db')
        ? r.latestRecord!.add(interval)
        : r.latestRecord!;
    gaps.add(GapRange(
      dbFile: fname,
      start: start,
      end: tNow,
    ));
  }
  return gaps;
}

/// Returns the next clock boundary that is a multiple of [intervalMin]
/// strictly after [from]. Replica of the private helper in
/// `BackupMetadataService` — duplicated here so this utility can be used
/// before the service is initialised.
DateTime _nextBoundary(DateTime from, int intervalMin) {
  final minsFromMidnight = from.hour * 60 + from.minute;
  final onBoundaryExact = minsFromMidnight % intervalMin == 0 &&
      from.second == 0 &&
      from.millisecond == 0;
  final nextMins = onBoundaryExact
      ? minsFromMidnight + intervalMin
      : ((minsFromMidnight ~/ intervalMin) + 1) * intervalMin;
  final dayOffset = nextMins ~/ (24 * 60);
  final timeMin = nextMins % (24 * 60);
  return DateTime(from.year, from.month, from.day + dayOffset,
      timeMin ~/ 60, timeMin % 60);
}
