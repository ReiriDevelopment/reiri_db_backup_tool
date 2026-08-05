import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:reiri_db_backup_tool/lib/date_time_utils.dart';
import 'package:reiri_db_backup_tool/lib/recovery_time_window.dart';
import 'package:reiri_db_backup_tool/model/backup_database.dart';
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

  /// Whether the controller may contain records newer than [latestRecord].
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

/// Returns the latest `YYYYMMDDHHmm` date across all readable user tables.
/// Returns null when the file or a dated record is unavailable.
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

/// Reports which source databases may be behind the controller.
/// History follows the interval databases because it is event-based.
Future<Map<String, DbProbeResult>> probeSourceFolder({
  required String sourceFolder,
  required List<String> dbFiles,
  DateTime? now,
}) async {
  final tNow = now ?? DateTime.now();
  final results = <String, DbProbeResult>{};

  for (final fname in dbFiles) {
    final database = BackupDatabase.tryFromFileName(fname);
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

    final interval = database?.interval;
    bool missed = false;
    if (interval != null && database?.eventBased == false) {
      // Records become available at their stamped boundary.
      // Do not add an interval buffer or the newest record may be missed.
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
  const history = BackupDatabase.history;
  if (dbFiles.contains(history.fileName)) {
    final anyMiss = results.entries
        .where((entry) => entry.key != history.fileName)
        .any((e) => e.value.hasMissingData);
    final h = results[history.fileName];
    if (h != null && h.exists && h.latestRecord != null && anyMiss) {
      results[history.fileName] = DbProbeResult(
        exists: true,
        latestRecord: h.latestRecord,
        hasMissingData: true,
        behind: h.behind,
      );
    }
  }

  return results;
}

/// Converts missing probe results into gaps for the next recovery cycle.
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
    // Interval gaps start after the captured record; history starts at it.
    final database = BackupDatabase.tryFromFileName(fname);
    final interval = database?.interval;
    final start = (interval != null && database?.eventBased == false)
        ? r.latestRecord!.add(interval)
        : r.latestRecord!;
    gaps.add(GapRange(dbFile: fname, start: start, end: tNow));
  }
  return gaps;
}

/// Adds a conservative overlap for the latest trend boundary after FTP.
///
/// A streamed SQLite snapshot can contain some rows from the newest trend
/// batch while other rows from that same timestamp are still being written.
/// The overall `max(date)` probe cannot detect that partial batch, so FTP must
/// always request the latest five-minute boundary again. Recovery later
/// deduplicates overlapping `(date, id)` rows.
List<GapRange> addFtpTrendOverlap(
  List<GapRange> gaps, {
  required DateTime completedAt,
}) {
  const trend = BackupDatabase.trend;
  final intervalMinutes = trend.interval!.inMinutes;
  final overlap = GapRange(
    dbFile: trend.fileName,
    start: previousWriteBoundary(completedAt, intervalMinutes),
    end: completedAt,
  );
  final result = List<GapRange>.from(gaps);
  final index = result.indexWhere((gap) => gap.dbFile == trend.fileName);
  if (index < 0) {
    result.add(overlap);
    return result;
  }

  final existing = result[index];
  result[index] = GapRange(
    dbFile: trend.fileName,
    start: existing.start.isBefore(overlap.start)
        ? existing.start
        : overlap.start,
    end: existing.end.isAfter(overlap.end) ? existing.end : overlap.end,
  );
  return result;
}

/// Returns the first [intervalMin] clock boundary strictly after [from].
DateTime _nextBoundary(DateTime from, int intervalMin) {
  final minsFromMidnight = from.hour * 60 + from.minute;
  final onBoundaryExact =
      minsFromMidnight % intervalMin == 0 &&
      from.second == 0 &&
      from.millisecond == 0;
  final nextMins = onBoundaryExact
      ? minsFromMidnight + intervalMin
      : ((minsFromMidnight ~/ intervalMin) + 1) * intervalMin;
  final dayOffset = nextMins ~/ (24 * 60);
  final timeMin = nextMins % (24 * 60);
  return DateTime(
    from.year,
    from.month,
    from.day + dayOffset,
    timeMin ~/ 60,
    timeMin % 60,
  );
}
