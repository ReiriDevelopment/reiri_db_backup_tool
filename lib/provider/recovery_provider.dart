import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reiri_app_core/reiri_app_core.dart';

import 'package:reiri_db_backup_tool/model/backup_metadata.dart';
import 'package:reiri_db_backup_tool/service/recovery_service.dart';

/// UI state surfaced to the Recovery screen.
class RecoveryState {
  final List<GapRange> gaps;
  final BackupState backupState;
  final FlushStatus flushStatus;
  final bool isScanning;
  final bool isFlushing;
  final DateTime? scheduledAt;

  const RecoveryState({
    this.gaps = const [],
    this.backupState = BackupState.idle,
    this.flushStatus = FlushStatus.none,
    this.isScanning = false,
    this.isFlushing = false,
    this.scheduledAt,
  });

  bool get hasGaps => gaps.isNotEmpty;

  RecoveryState copyWith({
    List<GapRange>? gaps,
    BackupState? backupState,
    FlushStatus? flushStatus,
    bool? isScanning,
    bool? isFlushing,
    DateTime? scheduledAt,
    bool clearScheduledAt = false,
  }) {
    return RecoveryState(
      gaps: gaps ?? this.gaps,
      backupState: backupState ?? this.backupState,
      flushStatus: flushStatus ?? this.flushStatus,
      isScanning: isScanning ?? this.isScanning,
      isFlushing: isFlushing ?? this.isFlushing,
      scheduledAt: clearScheduledAt ? null : (scheduledAt ?? this.scheduledAt),
    );
  }
}

final recoveryProvider =
    NotifierProvider<RecoveryNotifier, RecoveryState>(RecoveryNotifier.new);

class RecoveryNotifier extends Notifier<RecoveryState> {
  RecoveryService? _service;

  @override
  RecoveryState build() => const RecoveryState();

  /// Attach the shared [RecoveryService] instance from HomeScreen.
  void attach(RecoveryService service) {
    _service = service;
    _syncFromService();
  }

  void _syncFromService() {
    final meta = _service?.metadata;
    if (meta == null) return;
    state = RecoveryState(
      gaps: meta.detectedGaps,
      backupState: meta.backupState,
      flushStatus: meta.flushStatus,
      scheduledAt: meta.detectedGaps.isNotEmpty
          ? RecoveryService.nextOffPeakTime()
          : null,
    );
  }

  /// Refresh gap list from the service's persisted metadata.
  /// Spinner is shown for at least 1 second so the user can see it.
  Future<void> scanForGaps() async {
    state = state.copyWith(isScanning: true);
    await Future.wait([
      Future(() => _syncFromService()),
      Future.delayed(const Duration(seconds: 1)),
    ]);
    state = state.copyWith(isScanning: false);
  }

  /// Called by HomeScreen after [RecoveryService.onConnected] returns gaps.
  void onGapsDetected(List<GapRange> gaps) {
    state = RecoveryState(
      gaps: gaps,
      backupState: BackupState.realtimeTemp,
      flushStatus: FlushStatus.pending,
      scheduledAt:
          gaps.isNotEmpty ? RecoveryService.nextOffPeakTime() : null,
    );
  }

  /// Called by HomeScreen when flush completes.
  void onFlushCompleted() {
    state = const RecoveryState(
      gaps: [],
      backupState: BackupState.realtimeMain,
      flushStatus: FlushStatus.none,
    );
  }

  /// Start the flush immediately (manual "Run Now" trigger or scheduled 3am).
  /// First fetches any missing records from the controller into MAIN DB,
  /// then merges TEMP → MAIN.
  Future<void> runFlushNow() async {
    if (_service == null || !_service!.hasActiveGap) return;
    state = state.copyWith(isFlushing: true);
    try {
      await _fillGapsFromController(state.gaps);
      await _service!.flushTempToMain();
      onFlushCompleted();
    } catch (e) {
      print('[Recovery] runFlushNow error: $e');
      // Keep state as-is so user can retry.
    } finally {
      state = state.copyWith(isFlushing: false);
    }
  }

  /// For each unique DB type in [gaps], sends one `*_db_backup` request
  /// covering the full bounding window and writes the returned records
  /// directly into MAIN DB (while TEMP DB stays live for real-time).
  Future<void> _fillGapsFromController(List<GapRange> gaps) async {
    if (gaps.isEmpty) return;

    // Compute bounding window per DB type (earliest start → latest end).
    final Map<String, ({DateTime from, DateTime to})> ranges = {};
    for (final gap in gaps) {
      final type = RecoveryService.fileToDbType(gap.dbFile);
      if (type == null) continue;
      final existing = ranges[type];
      if (existing == null) {
        ranges[type] = (from: gap.start, to: gap.end);
      } else {
        ranges[type] = (
          from: existing.from.isBefore(gap.start) ? existing.from : gap.start,
          to:   existing.to.isAfter(gap.end)       ? existing.to   : gap.end,
        );
      }
    }

    for (final entry in ranges.entries) {
      final type = entry.key;
      final from = entry.value.from;
      final to   = entry.value.to;
      print('[Recovery] Gap-fill: requesting $type  $from → $to');

      final cmd = DbAccess();
      final ok = cmd.dbBackup(type, from, to);
      if (!ok) {
        print('[Recovery] Gap-fill: dbBackup() rejected for $type (locked?)');
        continue;
      }

      final completer = Completer<List<dynamic>?>();
      final sub = ref.listen<Map<String, dynamic>?>(
        communicationProvider(cmd),
        (_, data) {
          if (data != null && !completer.isCompleted) {
            final records = data['data'];
            completer.complete(records is List ? List<dynamic>.from(records) : null);
          }
        },
      );

      app.requestController(cmd);

      try {
        final records = await completer.future
            .timeout(const Duration(seconds: 120));
        if (records != null && records.isNotEmpty) {
          await _service!.fillGapInMainDb(type, records);
        } else {
          print('[Recovery] Gap-fill: no records for $type');
        }
      } on TimeoutException {
        print('[Recovery] Gap-fill: timeout waiting for $type');
      } catch (e) {
        print('[Recovery] Gap-fill: error for $type: $e');
      } finally {
        sub.close();
      }
    }
  }
}
