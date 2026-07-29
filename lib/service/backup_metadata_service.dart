import 'dart:convert';
import 'dart:io';

import 'package:reiri_db_backup_tool/model/backup_metadata.dart';
import 'package:reiri_db_backup_tool/lib/recovery_time_window.dart';
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

  /// Wipes all persisted recovery state back to an empty baseline.
  ///
  /// Called when a fresh initial backup establishes a new baseline, so stale
  /// gaps or an interrupted TEMP flush left over from a previous install do not
  /// carry over and light up the Recovery tab on a clean start.
  Future<void> reset() async {
    await save(BackupMetadata.empty());
  }

  /// Records a healthy real-time checkpoint without modifying an active gap.
  Future<void> recordHeartbeat({DateTime? at}) async {
    if (_current.disconnectedAt != null) return;
    final updated = _current.copyWith(lastHealthyAt: at ?? DateTime.now());
    await save(updated);
  }

  /// Records the earliest plausible start of a disconnect window.
  ///
  /// Repeated calls are intentionally idempotent: delayed WebSocket events,
  /// logout, and `dispose()` must never move an existing gap forward. The last
  /// healthy heartbeat is used as a conservative lower bound.
  Future<void> recordDisconnect({DateTime? at}) async {
    final observedAt = at ?? DateTime.now();
    final heartbeat = _current.lastHealthyAt;
    final candidate = heartbeat != null && heartbeat.isBefore(observedAt)
        ? heartbeat
        : observedAt;
    final existing = _current.disconnectedAt;
    final gapStart = existing != null && existing.isBefore(candidate)
        ? existing
        : candidate;
    final updated = _current.copyWith(disconnectedAt: gapStart);
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
    // Accumulate discrete periods (no merging) for UI display.
    final periods = [..._current.gapPeriods, ...newGaps];

    final updated = _current.copyWith(
      tConnect: tConnect,
      lastHealthyAt: tConnect,
      clearDisconnectedAt: true,
      detectedGaps: mergedGaps,
      gapPeriods: periods,
      backupState: mergedGaps.isEmpty
          ? BackupState.realtimeMain
          : BackupState.realtimeTemp,
      flushStatus: mergedGaps.isEmpty ? FlushStatus.none : FlushStatus.pending,
    );
    await save(updated);
    return newGaps;
  }

  /// Merges [incoming] gaps into [existing] gaps.
  /// - Same DB file → extend the time range to cover both windows.
  /// - New DB file  → append as a new entry.
  static List<GapRange> _mergeGaps(
    List<GapRange> existing,
    List<GapRange> incoming,
  ) {
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
    final gapStart =
        _current.disconnectedAt ?? _current.lastHealthyAt ?? _current.tConnect;
    if (gapStart == null) {
      FileLogService().log(
        '[Recovery] _computeGaps: no prior disconnect/connect time found — first run, no gap',
      );
      return [];
    }

    FileLogService().log(
      '[Recovery] _computeGaps: gapStart=$gapStart  tConnect=$tConnect  duration=${tConnect.difference(gapStart).inMinutes}min',
    );

    // Check interval-based DBs first (all except history).
    final intervalDbFiles = kDbWriteIntervals.keys
        .where((f) => f != 'history.db')
        .toList();

    final gaps = <GapRange>[];
    for (final dbFile in intervalDbFiles) {
      final missed = _wroteInGap(dbFile, gapStart, tConnect);
      if (missed) {
        gaps.add(GapRange(dbFile: dbFile, start: gapStart, end: tConnect));
        FileLogService().log('[Recovery]   MISS $dbFile');
      } else {
        FileLogService().log('[Recovery]   OK   $dbFile');
      }
    }

    // History is event-based and can change at any moment, so every actual
    // disconnect window is potentially missing history even when it did not
    // cross an interval-database boundary.
    if (tConnect.isAfter(gapStart)) {
      gaps.add(GapRange(dbFile: 'history.db', start: gapStart, end: tConnect));
      FileLogService().log(
        '[Recovery]   MISS history.db (start=disconnectedAt=$gapStart)',
      );
    } else {
      FileLogService().log(
        '[Recovery]   OK   history.db (empty disconnect window)',
      );
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
    final previousWrite = previousWriteBoundary(gapStart, intervalMin);
    final missed = scheduledWriteMayBeMissed(
      gapStart: gapStart,
      reconnectAt: tConnect,
      intervalMinutes: intervalMin,
    );
    FileLogService().log(
      '[Recovery]     $dbFile: previous boundary = $previousWrite  reconnect = $tConnect  grace=${kControllerWriteGrace.inSeconds}s  missed=$missed',
    );
    return missed;
  }

  /// Records that TEMP DB is the active write target for gap recovery.
  /// The flush has NOT started yet — use [markFlushInProgress] only when
  /// [RecoveryService._doFlush] actually begins executing.
  Future<void> saveTempPath(String tempDbPath) async {
    final updated = _current.copyWith(
      tempDbPath: tempDbPath,
      flushStatus: FlushStatus.pending,
    );
    await save(updated);
  }

  /// Marks that the TEMP→MAIN flush is actively executing.  This is the
  /// checkpoint that [RecoveryService.init] uses to detect a crash-interrupted
  /// flush on the next startup.  Call only at the very start of [_doFlush].
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
      gapPeriods: [],
      clearTempDbPath: true,
      autoFill: false,
    );
    await save(updated);
  }
}
