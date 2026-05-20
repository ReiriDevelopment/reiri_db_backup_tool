import 'dart:convert';
import 'dart:io';

import 'package:reiri_db_backup_tool/model/backup_metadata.dart';
import 'package:reiri_db_backup_tool/service/file_log_service.dart';

const _kMetadataFileName = 'backup_metadata.json';

/// Persists [BackupMetadata] to a JSON file alongside the backup folder.
/// Must call [init] before any other method.
class BackupMetadataService {
  BackupMetadata _current = BackupMetadata.empty();
  String? _filePath;

  BackupMetadata get current => _current;

  /// Load existing metadata from [macDir] (the per-controller root folder,
  /// e.g. `{rootPath}\{safeMac}`).
  Future<void> init(String macDir) async {
    _filePath = '$macDir\\$_kMetadataFileName';
    _current = await _load();

    // If a previous flush completed but the app crashed before cleanup,
    // treat it as done so the next connect doesn't re-flush.
    if (_current.flushStatus == FlushStatus.completed) {
      _current = _current.copyWith(
        flushStatus: FlushStatus.none,
        clearTempDbPath: true,
        detectedGaps: [],
        backupState: BackupState.idle,
      );
      await _write(_current);
    }
  }

  Future<BackupMetadata> _load() async {
    if (_filePath == null) return BackupMetadata.empty();
    final file = File(_filePath!);
    if (!await file.exists()) return BackupMetadata.empty();
    try {
      final raw = await file.readAsString();
      return BackupMetadata.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return BackupMetadata.empty();
    }
  }

  Future<void> _write(BackupMetadata m) async {
    if (_filePath == null) return;
    await File(_filePath!).writeAsString(jsonEncode(m.toJson()));
  }

  Future<void> save(BackupMetadata metadata) async {
    _current = metadata;
    await _write(metadata);
  }

  /// Writes the current time as the disconnect timestamp.
  /// Call on explicit disconnect, logout, dispose, and every minute as a
  /// heartbeat so crashes / force-kills leave a recent timestamp.
  Future<void> recordDisconnect() async {
    final updated = _current.copyWith(disconnectedAt: DateTime.now());
    await save(updated);
  }

  /// Records the new connection time and computes gaps per DB type.
  ///
  /// New gaps are **merged** with any existing scheduled gaps so that gaps
  /// from a previous session (e.g. logged out before recovery ran) are not
  /// lost when the user logs back in.
  ///
  /// Returns only the newly detected [GapRange]s (may be empty even when
  /// merged gaps exist from a prior session).
  Future<List<GapRange>> recordConnect(DateTime tConnect) async {
    final newGaps = _computeGaps(tConnect);
    final mergedGaps = _mergeGaps(_current.detectedGaps, newGaps);

    final updated = _current.copyWith(
      tConnect: tConnect,
      detectedGaps: mergedGaps,
      backupState: mergedGaps.isEmpty ? BackupState.realtimeMain : BackupState.realtimeTemp,
      flushStatus: mergedGaps.isEmpty ? FlushStatus.none : FlushStatus.pending,
    );
    await save(updated);
    return newGaps;
  }

  /// Merges [incoming] gaps into [existing] gaps.
  /// - Same DB file → extend the time range to cover both windows.
  /// - New DB file  → append as a new entry.
  static List<GapRange> _mergeGaps(
      List<GapRange> existing, List<GapRange> incoming) {
    if (incoming.isEmpty) return existing;
    final merged = List<GapRange>.from(existing);
    for (final gap in incoming) {
      final idx = merged.indexWhere((g) => g.dbFile == gap.dbFile);
      if (idx >= 0) {
        final old = merged[idx];
        merged[idx] = GapRange(
          dbFile: gap.dbFile,
          start: old.start.isBefore(gap.start) ? old.start : gap.start,
          end: old.end.isAfter(gap.end) ? old.end : gap.end,
        );
      } else {
        merged.add(gap);
      }
    }
    return merged;
  }

  List<GapRange> _computeGaps(DateTime tConnect) {
    // Prefer the recorded disconnect time; fall back to the previous tConnect
    // (conservative: assumes disconnected immediately after last session ended).
    // If neither exists this is the very first connection — no gap possible.
    final gapStart = _current.disconnectedAt ?? _current.tConnect;
    if (gapStart == null) {
      FileLogService().log('[Recovery] _computeGaps: no prior disconnect/connect time found — first run, no gap');
      return [];
    }

    FileLogService().log('[Recovery] _computeGaps: gapStart=$gapStart  tConnect=$tConnect  duration=${tConnect.difference(gapStart).inMinutes}min');

    // Check interval-based DBs first (all except history).
    final intervalDbFiles = kDbWriteIntervals.keys
        .where((f) => f != 'history.db')
        .toList();

    final gaps = <GapRange>[];
    for (final dbFile in intervalDbFiles) {
      final missed = _wroteInGap(dbFile, gapStart, tConnect);
      if (missed) {
        gaps.add(GapRange(
          dbFile: dbFile,
          start: gapStart,
          end: tConnect,
        ));
        FileLogService().log('[Recovery]   MISS $dbFile');
      } else {
        FileLogService().log('[Recovery]   OK   $dbFile');
      }
    }

    // History is event-based — include it only when at least one interval-based
    // DB is already missing, using the disconnect time as the recovery start.
    if (gaps.isNotEmpty) {
      gaps.add(GapRange(
        dbFile: 'history.db',
        start: gapStart,
        end: tConnect,
      ));
      FileLogService().log('[Recovery]   MISS history.db (start=disconnectedAt=$gapStart)');
    } else {
      FileLogService().log('[Recovery]   OK   history.db (no interval DB gaps — skipped)');
    }

    return gaps;
  }

  /// Returns true if at least one scheduled write point falls inside the gap
  /// (gapStart, tConnect).
  ///
  /// Interval-based DBs (trend 5 min, meter/ppd/optime 15 min) write at fixed
  /// clock boundaries (:00, :05, :10 … for trend; :00, :15, :30, :45 for
  /// others). We find the first boundary strictly after [gapStart] and check
  /// whether it falls before [tConnect].
  bool _wroteInGap(String dbFile, DateTime gapStart, DateTime tConnect) {
    final intervalMin = kDbWriteIntervals[dbFile]!.inMinutes;
    final nextWrite = _nextBoundary(gapStart, intervalMin);
    final missed = nextWrite.isBefore(tConnect);
    FileLogService().log('[Recovery]     $dbFile: next boundary after disconnect = $nextWrite  reconnect = $tConnect  missed=$missed');
    return missed;
  }

  /// Returns the next clock boundary that is a multiple of [intervalMin]
  /// strictly after [from].
  ///
  /// Examples (intervalMin=15):
  ///   16:48:58 → 17:00:00
  ///   17:00:00 → 17:15:00
  ///   16:44:59 → 16:45:00
  static DateTime _nextBoundary(DateTime from, int intervalMin) {
    final minsFromMidnight = from.hour * 60 + from.minute;
    final onBoundaryExact = minsFromMidnight % intervalMin == 0
        && from.second == 0
        && from.millisecond == 0;
    final nextMins = onBoundaryExact
        ? minsFromMidnight + intervalMin
        : ((minsFromMidnight ~/ intervalMin) + 1) * intervalMin;
    final dayOffset = nextMins ~/ (24 * 60);
    final timeMin = nextMins % (24 * 60);
    return DateTime(from.year, from.month, from.day + dayOffset,
        timeMin ~/ 60, timeMin % 60);
  }

  Future<void> markFlushInProgress(String tempDbPath) async {
    final updated = _current.copyWith(
      tempDbPath: tempDbPath,
      flushStatus: FlushStatus.inProgress,
    );
    await save(updated);
  }

  Future<void> markFlushCompleted() async {
    final updated = _current.copyWith(
      flushStatus: FlushStatus.completed,
      backupState: BackupState.realtimeMain,
      detectedGaps: [],
      clearTempDbPath: true,
      clearDisconnectedAt: true,
    );
    await save(updated);
  }

  Future<void> clearGaps() async {
    final updated = _current.copyWith(
      detectedGaps: [],
      backupState: BackupState.realtimeMain,
      flushStatus: FlushStatus.none,
      clearTempDbPath: true,
    );
    await save(updated);
  }
}
