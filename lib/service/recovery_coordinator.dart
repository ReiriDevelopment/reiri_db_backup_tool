import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reiri_app_core/reiri_app_core.dart';

import 'package:reiri_db_backup_tool/lib/date_time_utils.dart';
import 'package:reiri_db_backup_tool/lib/recovery_response_validation.dart';
import 'package:reiri_db_backup_tool/lib/recovery_time_window.dart';
import 'package:reiri_db_backup_tool/model/backup_database.dart';
import 'package:reiri_db_backup_tool/model/backup_log_entry.dart';
import 'package:reiri_db_backup_tool/model/backup_metadata.dart';
import 'package:reiri_db_backup_tool/service/backup_db_access.dart';
import 'package:reiri_db_backup_tool/service/file_log_service.dart';
import 'package:reiri_db_backup_tool/service/recovery_service.dart';

/// Returns detected recovery gaps and whether they should be filled immediately.
class RecoveryDetectionResult {
  final List<GapRange> gaps;
  final List<GapRange> gapPeriods;
  final bool autoFill;

  const RecoveryDetectionResult({
    required this.gaps,
    required this.gapPeriods,
    required this.autoFill,
  });
}

/// Contains backup log entries created by a completed recovery flush.
class RecoveryFlushResult {
  final List<BackupLogEntry> logEntries;

  const RecoveryFlushResult({required this.logEntries});
}

/// Accumulates recovered record counts, timestamps, and raw payloads.
class _GapSummary {
  final int count;
  final DateTime? first;
  final DateTime? last;
  final List<dynamic> rawRecords;

  const _GapSummary({
    required this.count,
    this.first,
    this.last,
    this.rawRecords = const [],
  });

  _GapSummary merge(_GapSummary other) => _GapSummary(
    count: count + other.count,
    first: _earlier(first, other.first),
    last: _later(last, other.last),
    rawRecords: [...rawRecords, ...other.rawRecords],
  );

  static DateTime? _earlier(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isBefore(b) ? a : b;
  }

  static DateTime? _later(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }
}

/// Coordinates gap-fill, interleaved TEMP writes, and post-flush catch-up.
class RecoveryCoordinator {
  final Ref ref;
  final RecoveryService service;

  bool _detectingGaps = false;

  RecoveryCoordinator({required this.ref, required this.service});

  Future<RecoveryDetectionResult?> detectGaps() async {
    if (_detectingGaps) return null;
    _detectingGaps = true;
    try {
      await service.onConnected();
      final metadata = service.metadata;
      final gaps = metadata.detectedGaps;
      if (gaps.isEmpty) {
        FileLogService().log('[Recovery] No gaps — real-time → MAIN DB');
      } else {
        FileLogService().log(
          '[Recovery] *** ${gaps.length} gap(s) scheduled '
          '(including carry-over) ***',
        );
        for (final gap in gaps) {
          FileLogService().log(
            '[Recovery]   ${gap.dbFile}: ${gap.start} → ${gap.end} '
            '(${gap.duration.inMinutes}min)',
          );
        }
      }
      return RecoveryDetectionResult(
        gaps: gaps,
        gapPeriods: metadata.gapPeriods,
        autoFill: metadata.autoFill,
      );
    } finally {
      _detectingGaps = false;
    }
  }

  Future<RecoveryFlushResult> runInterleavedFlush({
    required List<GapRange> gaps,
    required List<GapRange> gapPeriods,
    required void Function(String step) onStep,
  }) async {
    final suspendTime = DateTime.now();
    final summaries = <BackupDatabase, _GapSummary>{};
    try {
      await service.beginInterleavedFlush();
      final rawPeriods = gapPeriods.isNotEmpty ? gapPeriods : gaps;
      final byDatabase = <BackupDatabase, List<GapRange>>{};
      for (final period in rawPeriods) {
        final database = BackupDatabase.tryFromFileName(period.dbFile);
        if (database == null) continue;
        byDatabase.putIfAbsent(database, () => []).add(period);
      }
      for (final periods in byDatabase.values) {
        periods.sort((a, b) => a.start.compareTo(b.start));
      }

      final typeCount = byDatabase.length;
      var typeIndex = 0;
      for (final entry in byDatabase.entries) {
        typeIndex++;
        final database = entry.key;
        final label = app.word(database.descriptionKey);
        final periods = entry.value;
        for (var index = 0; index < periods.length; index++) {
          final period = periods[index];
          await _waitForInitialTrendBoundary(database, period);
          onStep(
            '${app.word('fetching_from_controller')}: $label'
            '${periods.length > 1 ? ' (${app.word('gap_progress')} ${index + 1}/${periods.length})' : ''}'
            ' [$typeIndex/$typeCount]',
          );
          final summary = await _fillSinglePeriodFromController(
            database,
            period,
          );
          summaries.update(
            database,
            (current) => current.merge(summary),
            ifAbsent: () => summary,
          );
          onStep(
            '${app.word('writing_to_database')}: $label'
            '${periods.length > 1 ? ' (${index + 1}/${periods.length})' : ''}'
            ' [$typeIndex/$typeCount]',
          );
          final tempTo = index + 1 < periods.length
              ? periods[index + 1].start
              : null;
          await service.flushTempWindowToMain(database, null, tempTo);
        }
      }

      for (final database in BackupDatabase.recoveryOrder) {
        if (!byDatabase.containsKey(database)) {
          await service.flushTempWindowToMain(database, null, null);
        }
      }

      // Resume live writes on MAIN before catch-up. The catch-up request covers
      // the closed-handle window; records after this switch arrive in realtime.
      await service.switchToMainForCatchUp();
      final flushEnd = DateTime.now();
      await _catchUpSuspendWindow(suspendTime, flushEnd, summaries);
      for (final database in const [
        BackupDatabase.trend,
        BackupDatabase.meter,
        BackupDatabase.optime,
      ]) {
        await service.deduplicateInMain(database);
      }
      await service.refreshMeterValueCacheFromMain();
      onStep(app.word('finalising'));
      await service.finalizeFlushedCleanup();
      return RecoveryFlushResult(logEntries: _buildLogEntries(summaries));
    } catch (_) {
      await service.reopenAfterFailedFlush();
      rethrow;
    }
  }

  List<BackupLogEntry> _buildLogEntries(
    Map<BackupDatabase, _GapSummary> summaries,
  ) {
    final flushTime = DateTime.now();
    return summaries.entries.map((entry) {
      return BackupLogEntry(
        timestamp: entry.value.first ?? flushTime,
        backedUpAt: flushTime,
        type: BackupLogType.recovery,
        result: BackupLogResult.success,
        database: entry.key.fileName,
        details: entry.value.rawRecords.isEmpty
            ? null
            : jsonEncode(entry.value.rawRecords),
      );
    }).toList();
  }

  Future<void> _catchUpSuspendWindow(
    DateTime from,
    DateTime to,
    Map<BackupDatabase, _GapSummary> summaries,
  ) async {
    if (to.difference(from) < const Duration(minutes: 5)) return;
    FileLogService().log(
      '[Recovery] Catch-up suspend window: $from → $to '
      '(${to.difference(from).inMinutes} min)',
    );
    for (final database in BackupDatabase.recoveryOrder) {
      final interval = database.interval;
      final catchUpFrom = interval != null && interval.inMinutes < 60
          ? previousWriteBoundary(from, interval.inMinutes).add(interval)
          : from;
      if (!catchUpFrom.isBefore(to)) continue;
      final summary = await _fillSinglePeriodFromController(
        database,
        GapRange(dbFile: database.fileName, start: catchUpFrom, end: to),
      );
      summaries.update(
        database,
        (current) => current.merge(summary),
        ifAbsent: () => summary,
      );
    }
  }

  Future<void> _waitForInitialTrendBoundary(
    BackupDatabase database,
    GapRange period,
  ) async {
    if (!service.metadata.autoFill || database != BackupDatabase.trend) return;
    final interval = database.interval;
    if (interval == null) return;

    final readyAt = recoveryBoundaryReadyAt(
      gapEnd: period.end,
      intervalMinutes: interval.inMinutes,
    );
    final wait = readyAt.difference(DateTime.now());
    if (wait <= Duration.zero) return;
    FileLogService().log(
      '[Recovery] Waiting ${wait.inSeconds}s for the latest trend batch '
      'to settle (ready at $readyAt)',
    );
    await Future<void>.delayed(wait);
  }

  Future<_GapSummary> _fillSinglePeriodFromController(
    BackupDatabase database,
    GapRange period,
  ) async {
    final type = database.type;
    final interval = database.interval;
    final isHistory = database.eventBased;
    final DateTime from;
    final DateTime to;
    if (isHistory) {
      from = DateTime(period.start.year, period.start.month, period.start.day);
      to = DateTime.now();
    } else if (interval != null && interval.inMinutes < 60) {
      final window = intervalRecoveryWindow(
        dbType: type,
        gapStart: period.start,
        gapEnd: period.end,
        intervalMinutes: interval.inMinutes,
      );
      from = window.from;
      to = window.to;
    } else {
      from = period.start;
      to = period.end;
    }

    FileLogService().log('[Recovery] Gap-fill: requesting $type  $from → $to');
    final command = BackupDbAccess();
    if (!command.dbBackup(type, from, to)) {
      final error = RecoveryDataUnavailableException(
        '$type recovery request was rejected',
      );
      FileLogService().log('[Recovery] Gap-fill: $error');
      throw error;
    }

    final completer = Completer<List<dynamic>?>();
    final subscription = ref.listen<Map<String, dynamic>?>(
      communicationProvider(command),
      (_, data) {
        if (data != null && !completer.isCompleted) {
          final records = data['data'];
          completer.complete(
            records is List ? List<dynamic>.from(records) : null,
          );
        }
      },
    );
    try {
      app.requestController(command);
      final response = await completer.future.timeout(
        const Duration(seconds: 120),
      );
      final records = requireRecoveryRecords(
        database: database,
        records: response,
      );
      if (records.isEmpty) {
        FileLogService().log(
          '[Recovery] Gap-fill: no records for $type $from → $to',
        );
        return const _GapSummary(count: 0);
      }

      final rawDates = records
          .map(
            (record) => record is List && record.isNotEmpty ? record[0] : null,
          )
          .whereType<Object>()
          .toList();
      await service.fillGapInMainDb(
        database,
        records,
        deleteFrom: isHistory ? from : null,
      );
      final dateTimes = rawDates
          .map(
            (value) =>
                value is int && value > 0 ? dbIntToDateTime(value) : null,
          )
          .whereType<DateTime>()
          .toList();
      final first = dateTimes.isEmpty
          ? null
          : dateTimes.reduce((a, b) => a.isBefore(b) ? a : b);
      final last = dateTimes.isEmpty
          ? null
          : dateTimes.reduce((a, b) => a.isAfter(b) ? a : b);
      FileLogService().log(
        '[Recovery] Gap-fill: $type received ${records.length} record(s)',
      );
      return _GapSummary(
        count: records.length,
        first: first,
        last: last,
        rawRecords: records,
      );
    } on TimeoutException catch (error) {
      final unavailable = RecoveryDataUnavailableException(
        '$type recovery timed out after 120 seconds',
      );
      FileLogService().log('[Recovery] Gap-fill: $unavailable ($error)');
      throw unavailable;
    } on RecoveryDataUnavailableException catch (error) {
      FileLogService().log('[Recovery] Gap-fill: $error');
      rethrow;
    } catch (error) {
      final unavailable = RecoveryDataUnavailableException(
        '$type recovery failed: $error',
      );
      FileLogService().log('[Recovery] Gap-fill: $unavailable');
      throw unavailable;
    } finally {
      subscription.close();
    }
  }
}
