import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reiri_app_core/reiri_app_core.dart';

import 'package:reiri_db_backup_tool/lib/initial_backup_constants.dart';
import 'package:reiri_db_backup_tool/model/backup_metadata.dart';
import 'package:reiri_db_backup_tool/provider/backup_log_provider.dart';
import 'package:reiri_db_backup_tool/service/file_log_service.dart';
import 'package:reiri_db_backup_tool/service/recovery_coordinator.dart';
import 'package:reiri_db_backup_tool/service/recovery_service.dart';

/// UI state surfaced to the Recovery screen.
class RecoveryState {
  final List<GapRange> gaps;
  final List<GapRange> gapPeriods;
  final BackupState backupState;
  final FlushStatus flushStatus;
  final bool isScanning;
  final bool isFlushing;
  final DateTime? scheduledAt;
  final String? flushStep;

  const RecoveryState({
    this.gaps = const [],
    this.gapPeriods = const [],
    this.backupState = BackupState.idle,
    this.flushStatus = FlushStatus.none,
    this.isScanning = false,
    this.isFlushing = false,
    this.scheduledAt,
    this.flushStep,
  });

  bool get hasGaps => gapPeriods.isNotEmpty;

  RecoveryState copyWith({
    List<GapRange>? gaps,
    List<GapRange>? gapPeriods,
    BackupState? backupState,
    FlushStatus? flushStatus,
    bool? isScanning,
    bool? isFlushing,
    DateTime? scheduledAt,
    String? flushStep,
    bool clearScheduledAt = false,
    bool clearFlushStep = false,
  }) {
    return RecoveryState(
      gaps: gaps ?? this.gaps,
      gapPeriods: gapPeriods ?? this.gapPeriods,
      backupState: backupState ?? this.backupState,
      flushStatus: flushStatus ?? this.flushStatus,
      isScanning: isScanning ?? this.isScanning,
      isFlushing: isFlushing ?? this.isFlushing,
      scheduledAt: clearScheduledAt ? null : (scheduledAt ?? this.scheduledAt),
      flushStep: clearFlushStep ? null : (flushStep ?? this.flushStep),
    );
  }
}

final recoveryProvider = NotifierProvider<RecoveryNotifier, RecoveryState>(
  RecoveryNotifier.new,
);

/// Projects [RecoveryCoordinator] progress into Riverpod UI state.
class RecoveryNotifier extends Notifier<RecoveryState> {
  RecoveryService? _service;
  RecoveryCoordinator? _coordinator;
  int _recoveryHour = kDefaultRecoveryTime.hour;
  int _recoveryMinute = kDefaultRecoveryTime.minute;

  @override
  RecoveryState build() => const RecoveryState();

  void setRecoveryTime(int hour, int minute) {
    _recoveryHour = hour;
    _recoveryMinute = minute;
  }

  void attach(RecoveryService service) {
    _service = service;
    _coordinator = RecoveryCoordinator(ref: ref, service: service);
    syncFromService();
  }

  void syncFromService() {
    final metadata = _service?.metadata;
    if (metadata == null) return;
    state = RecoveryState(
      gaps: metadata.detectedGaps,
      gapPeriods: metadata.gapPeriods,
      backupState: metadata.backupState,
      flushStatus: metadata.flushStatus,
      scheduledAt: metadata.detectedGaps.isNotEmpty ? _nextOffPeak() : null,
    );
  }

  Future<void> scanForGaps() async {
    state = state.copyWith(isScanning: true);
    await Future.wait([
      Future(syncFromService),
      Future.delayed(const Duration(seconds: 1)),
    ]);
    state = state.copyWith(isScanning: false);
  }

  void onGapsDetected(List<GapRange> gaps) {
    final metadata = _service?.metadata;
    state = RecoveryState(
      gaps: metadata?.detectedGaps ?? gaps,
      gapPeriods: metadata?.gapPeriods ?? gaps,
      backupState: BackupState.realtimeTemp,
      flushStatus: FlushStatus.pending,
      scheduledAt: gaps.isNotEmpty ? _nextOffPeak() : null,
    );
  }

  void updateRecoveryTime(int hour, int minute) {
    _recoveryHour = hour;
    _recoveryMinute = minute;
    if (state.gaps.isEmpty) return;
    state = state.copyWith(
      scheduledAt: RecoveryService.nextOffPeakTime(hour: hour, minute: minute),
    );
  }

  Future<RecoveryDetectionResult?> detectGaps() async {
    final result = await _coordinator?.detectGaps();
    if (result != null && result.gaps.isNotEmpty) {
      onGapsDetected(result.gaps);
    } else if (result != null) {
      syncFromService();
    }
    return result;
  }

  Future<void> runFlushNow() async {
    final coordinator = _coordinator;
    final service = _service;
    if (coordinator == null || service == null || state.isFlushing) {
      return;
    }
    if (!service.hasActiveGap) {
      // Do not leave stale gap rows visible when persisted metadata is clear.
      syncFromService();
      return;
    }
    state = state.copyWith(
      isFlushing: true,
      flushStep: app.word('preparing_recovery'),
    );
    try {
      final result = await coordinator.runInterleavedFlush(
        gaps: state.gaps,
        gapPeriods: state.gapPeriods,
        onStep: (step) => state = state.copyWith(flushStep: step),
      );
      state = const RecoveryState(
        backupState: BackupState.realtimeMain,
        flushStatus: FlushStatus.none,
      );
      if (result.logEntries.isNotEmpty) {
        ref.read(backupLogProvider.notifier).addEntries(result.logEntries);
      }
    } catch (error) {
      FileLogService().log('[Recovery] interleaved flush error: $error');
      // The coordinator has reopened the correct write target and restored
      // pending metadata. Project that source of truth back into the UI.
      syncFromService();
    } finally {
      state = state.copyWith(isFlushing: false, clearFlushStep: true);
    }
  }

  DateTime _nextOffPeak() => RecoveryService.nextOffPeakTime(
    hour: _recoveryHour,
    minute: _recoveryMinute,
  );
}
