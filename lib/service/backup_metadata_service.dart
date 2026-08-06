// File purpose: Persists backup health metadata and derives missing-data gaps.

import 'dart:convert';
import 'dart:io';

import 'package:reiri_db_backup_tool/lib/recovery_time_window.dart';
import 'package:reiri_db_backup_tool/model/backup_database.dart';
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

  /// Reads persisted metadata, falling back to an empty state when absent or invalid.
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

  /// Clears persisted recovery state after a fresh initial backup.
  Future<void> reset() async {
    await save(BackupMetadata.empty());
  }

  /// Records a healthy real-time checkpoint without modifying an active gap.
  Future<void> recordHeartbeat({DateTime? at}) async {
    if (_current.disconnectedAt != null) return;
    final updated = _current.copyWith(lastHealthyAt: at ?? DateTime.now());
    await save(updated);
  }

  /// Records the earliest disconnect boundary without moving an existing gap.
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

  /// Records a connection and merges new gaps with pending recovery work.
  /// Returns only the newly detected gaps.
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

  /// Merges ranges by database, appending previously unseen databases.
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

  /// Derives per-database gaps from the last healthy or disconnected boundary.
  List<GapRange> _computeGaps(DateTime tConnect) {
    // Fall back through the last healthy connection; no timestamp means first run.
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

    // Check interval-based DBs first (all except event-based history).
    final gaps = <GapRange>[];
    for (final database in BackupDatabase.gapDetectionOrder) {
      final missed = _wroteInGap(database, gapStart, tConnect);
      if (missed) {
        gaps.add(
          GapRange(dbFile: database.fileName, start: gapStart, end: tConnect),
        );
        FileLogService().log('[Recovery]   MISS ${database.fileName}');
      } else {
        FileLogService().log('[Recovery]   OK   ${database.fileName}');
      }
    }

    // Any disconnect may miss event-based history.
    const history = BackupDatabase.history;
    if (tConnect.isAfter(gapStart)) {
      gaps.add(
        GapRange(dbFile: history.fileName, start: gapStart, end: tConnect),
      );
      FileLogService().log(
        '[Recovery]   MISS ${history.fileName} '
        '(start=disconnectedAt=$gapStart)',
      );
    } else {
      FileLogService().log(
        '[Recovery]   OK   ${history.fileName} (empty disconnect window)',
      );
    }

    return gaps;
  }

  /// Whether a scheduled write boundary may fall inside the gap.
  bool _wroteInGap(
    BackupDatabase database,
    DateTime gapStart,
    DateTime tConnect,
  ) {
    final intervalMin = database.interval!.inMinutes;
    final previousWrite = previousWriteBoundary(gapStart, intervalMin);
    final missed = scheduledWriteMayBeMissed(
      gapStart: gapStart,
      reconnectAt: tConnect,
      intervalMinutes: intervalMin,
    );
    FileLogService().log(
      '[Recovery]     ${database.fileName}: previous boundary = '
      '$previousWrite  reconnect = $tConnect  '
      'grace=${kControllerWriteGrace.inSeconds}s  missed=$missed',
    );
    return missed;
  }

  /// Marks TEMP as active while leaving the coordinated flush pending.
  Future<void> saveTempPath(String tempDbPath) async {
    final updated = _current.copyWith(
      tempDbPath: tempDbPath,
      flushStatus: FlushStatus.pending,
    );
    await save(updated);
  }

  /// Checkpoints an active TEMP-to-MAIN flush for crash recovery.
  Future<void> markFlushInProgress(String tempDbPath) async {
    final updated = _current.copyWith(
      tempDbPath: tempDbPath,
      flushStatus: FlushStatus.inProgress,
    );
    await save(updated);
  }

  /// Returns an interrupted/failed flush to the retryable pending state while
  /// preserving every gap and the TEMP write target.
  Future<void> markFlushPending(String tempDbPath) async {
    final updated = _current.copyWith(
      tempDbPath: tempDbPath,
      flushStatus: FlushStatus.pending,
      backupState: BackupState.realtimeTemp,
    );
    await save(updated);
  }

  /// Clears completed recovery work and records that live writes are back on MAIN.
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
