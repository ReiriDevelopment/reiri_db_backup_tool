import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reiri_app_core/reiri_app_core.dart';

import 'package:reiri_db_backup_tool/lib/date_time_utils.dart';
import 'package:reiri_db_backup_tool/lib/initial_backup_constants.dart';
import 'package:reiri_db_backup_tool/lib/recovery_response_validation.dart';
import 'package:reiri_db_backup_tool/lib/recovery_time_window.dart';
import 'package:reiri_db_backup_tool/model/backup_log_entry.dart';
import 'package:reiri_db_backup_tool/model/backup_metadata.dart';
import 'package:reiri_db_backup_tool/provider/backup_log_provider.dart';
import 'package:reiri_db_backup_tool/service/backup_db_access.dart';
import 'package:reiri_db_backup_tool/service/file_log_service.dart';
import 'package:reiri_db_backup_tool/service/recovery_service.dart';

/// Accumulates raw controller records and date span from one or more gap-fill
/// calls for a single DB type. Raw records are serialised to JSON for the
/// backup log CSV so the caller can inspect exact values (e.g. meter amounts).
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

/// UI state surfaced to the Recovery screen.
class RecoveryState {
  /// Merged ranges (one per DB file) used for gap-fill operations.
  final List<GapRange> gaps;

  /// Discrete disconnect periods accumulated since last flush — shown in UI.
  final List<GapRange> gapPeriods;
  final BackupState backupState;
  final FlushStatus flushStatus;
  final bool isScanning;
  final bool isFlushing;
  final DateTime? scheduledAt;

  /// Current step description shown in the loading overlay while flushing.
  /// Null when not flushing.
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

class RecoveryNotifier extends Notifier<RecoveryState> {
  RecoveryService? _service;

  // Cached recovery time — set once at login via setRecoveryTime() and
  // updated whenever the user changes it.  Stored here (not in a string
  // provider) so it survives tab switches without stringDataProvider
  // auto-disposing.
  int _recoveryHour = kDefaultRecoveryTime.hour;
  int _recoveryMinute = kDefaultRecoveryTime.minute;

  @override
  RecoveryState build() => const RecoveryState();

  /// Seeds the cached recovery hour/minute from the persisted setting.
  /// Call this once at login (before [attach]) with the value from disk.
  void setRecoveryTime(int hour, int minute) {
    _recoveryHour = hour;
    _recoveryMinute = minute;
  }

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
      gapPeriods: meta.gapPeriods,
      backupState: meta.backupState,
      flushStatus: meta.flushStatus,
      scheduledAt: meta.detectedGaps.isNotEmpty ? _nextOffPeak() : null,
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
    final meta = _service?.metadata;
    state = RecoveryState(
      gaps: meta?.detectedGaps ?? gaps,
      gapPeriods: meta?.gapPeriods ?? gaps,
      backupState: BackupState.realtimeTemp,
      flushStatus: FlushStatus.pending,
      scheduledAt: gaps.isNotEmpty ? _nextOffPeak() : null,
    );
  }

  /// Update the scheduled flush time after the user changes the setting.
  /// Only updates [scheduledAt] if a gap is currently active.
  void updateRecoveryTime(int hour, int minute) {
    _recoveryHour = hour;
    _recoveryMinute = minute;
    if (state.gaps.isEmpty) return;
    state = state.copyWith(
      scheduledAt: RecoveryService.nextOffPeakTime(hour: hour, minute: minute),
    );
  }

  /// Called by HomeScreen when flush completes.
  void onFlushCompleted() {
    state = const RecoveryState(
      gaps: [],
      gapPeriods: [],
      backupState: BackupState.realtimeMain,
      flushStatus: FlushStatus.none,
      flushStep: null,
    );
  }

  /// Start the flush immediately (manual "Run Now" trigger or scheduled 3am).
  ///
  /// Uses discrete [gapPeriods] to interleave gap-fill and TEMP-window writes
  /// so rows land in MAIN in chronological order without redundant controller
  /// requests for the "connected" windows already in TEMP.
  ///
  /// For each DB type, the sequence is:
  ///   gap-fill [D1→C1] → flush TEMP [C1→D2) → gap-fill [D2→C2] → flush TEMP [C2→∞)
  Future<void> runFlushNow() async {
    if (_service == null || !_service!.hasActiveGap || state.isFlushing) return;
    state = state.copyWith(isFlushing: true, flushStep: 'Preparing recovery…');
    final suspendTime = DateTime.now();
    try {
      await _service!.suspendRealtime();

      // Use discrete gapPeriods (one entry per disconnect per DB) so each
      // gap-fill request covers only the actual missing window. TEMP data
      // from the connected windows between gaps is flushed directly without
      // re-fetching from the controller, minimising controller requests.
      final rawPeriods = state.gapPeriods.isNotEmpty
          ? state.gapPeriods
          : state.gaps;

      final Map<String, List<GapRange>> byType = {};
      for (final p in rawPeriods) {
        final type = RecoveryService.fileToDbType(p.dbFile);
        if (type == null) continue;
        byType.putIfAbsent(type, () => []).add(p);
      }
      for (final list in byType.values) {
        list.sort((a, b) => a.start.compareTo(b.start));
      }

      // Track per-type record counts and date spans for backup log entries.
      final summaries = <String, _GapSummary>{};

      final typeCount = byType.length;
      int typeIndex = 0;
      for (final entry in byType.entries) {
        typeIndex++;
        final type = entry.key;
        final label = _dbTypeLabel(type);
        final periods = entry.value;
        for (int i = 0; i < periods.length; i++) {
          final period = periods[i];
          state = state.copyWith(
            flushStep:
                'Fetching $label from controller'
                '${periods.length > 1 ? ' (gap ${i + 1}/${periods.length})' : ''}'
                ' [$typeIndex/$typeCount]',
          );
          final r = await _fillSinglePeriodFromController(type, period);
          summaries.update(type, (s) => s.merge(r), ifAbsent: () => r);
          state = state.copyWith(
            flushStep:
                'Writing $label to database'
                '${periods.length > 1 ? ' (${i + 1}/${periods.length})' : ''}'
                ' [$typeIndex/$typeCount]',
          );
          // Flush TEMP up to the start of the next gap (the connected window
          // between this gap and the next). For the last period, flush to the
          // end of TEMP (null = no upper bound).
          final tempTo = (i + 1 < periods.length) ? periods[i + 1].start : null;
          await _service!.flushTempWindowToMain(type, null, tempTo);
        }
      }

      // Flush TEMP for any DB types that had no explicit gap entry but still
      // wrote to TEMP during the disconnected window (e.g. meter/optime/ppd
      // when only trend missed a write boundary). Without this their TEMP data
      // is deleted by finalizeFlushedCleanup and never reaches MAIN.
      const allDbTypes = ['trend', 'meter', 'optime', 'ppd', 'history'];
      for (final type in allDbTypes) {
        if (byType.containsKey(type)) continue;
        await _service!.flushTempWindowToMain(type, null, null);
      }

      state = state.copyWith(flushStep: 'Finalising…');
      await _service!.finalizeFlushedCleanup();
      onFlushCompleted();

      // Catch-up: fill any realtime writes that arrived while suspended.
      // Real-time DB handles were closed for the duration of the flush, so
      // any interval boundary that fired during that window (e.g. 03:05 trend
      // when the 03:00 scheduled flush took several minutes) was silently lost.
      final flushEnd = DateTime.now();
      await _catchUpSuspendWindow(suspendTime, flushEnd, summaries);

      // Remove duplicate rows that can appear in two scenarios:
      //   1. Multi-period gap fill: period-i's extended `to` and period-(i+1)'s
      //      _prevBoundary both cover the same boundary stamp (e.g. 18:00 in
      //      both a 17:46-end window extended to 18:01 and an 18:03-start window
      //      whose prevBoundary is 18:00). meter/optime/trend all lack
      //      UNIQUE(date,id) so addXxxData inserts rather than ignores.
      //   2. Catch-up: controller pushes a boundary record slightly before the
      //      boundary timestamp, so it lands in TEMP *and* in the catch-up window.
      for (final f in ['trend.db', 'meter.db', 'optime.db']) {
        await _service!.deduplicateInMain(f);
      }

      // Refresh the meter last-value cache from MAIN so subsequent realtime
      // meter amounts are computed against the post-catch-up / post-dedup
      // values. Uses a separate read-only connection — does NOT close app.db's
      // live handles — so real-time writes (e.g. the dss4 reconnect burst)
      // arriving at exactly the flush minute are never dropped.
      await _service!.refreshMeterValueCacheFromMain();

      // Add one recovery log entry per DB type with the actual record time
      // (earliest record date from the controller) and a details summary.
      const _dbFiles = {
        'meter': 'meter.db',
        'optime': 'optime.db',
        'trend': 'trend.db',
        'ppd': 'ppd.db',
        'history': 'history.db',
      };
      final flushTime = DateTime.now();
      final logEntries = summaries.entries.map((e) {
        final dbFile = _dbFiles[e.key] ?? '${e.key}.db';
        return BackupLogEntry(
          timestamp: e.value.first ?? flushTime,
          backedUpAt: flushTime,
          type: BackupLogType.recovery,
          result: BackupLogResult.success,
          database: dbFile,
          details: e.value.rawRecords.isEmpty
              ? null
              : jsonEncode(e.value.rawRecords),
        );
      }).toList();
      if (logEntries.isNotEmpty) {
        ref.read(backupLogProvider.notifier).addEntries(logEntries);
      }
    } catch (e) {
      FileLogService().log('[Recovery] runFlushNow error: $e');
      // suspendRealtime() closed every app.db handle before this failure —
      // without reopening one, real-time writes have nowhere to land and
      // backup stays silently dead (even across logout/login) until the
      // next successful flush. Reopen on whichever DB is still the active
      // target so real-time can resume; the gap stays pending and will be
      // retried by the next reconnect / scheduled flush.
      await _service?.reopenAfterFailedFlush();
      // Avoid retrying a timed-out controller request every minute after the
      // scheduled time has passed. Keep the gap visible and schedule the next
      // automatic attempt; the user can still trigger "Run Now" manually.
      state = state.copyWith(scheduledAt: _nextOffPeak());
    } finally {
      state = state.copyWith(isFlushing: false, clearFlushStep: true);
    }
  }

  /// Requests the controller for each DB type covering [from, to] so any data
  /// that arrived while real-time was suspended during the flush is recovered.
  /// Skipped when the suspend window is shorter than the smallest write interval
  /// (5 min / trend) since no boundary could have been missed in that time.
  /// Results are merged into [summaries] for backup log entry creation.
  Future<void> _catchUpSuspendWindow(
    DateTime from,
    DateTime to,
    Map<String, _GapSummary> summaries,
  ) async {
    if (_service == null) return;
    if (to.difference(from) < const Duration(minutes: 5)) return;
    FileLogService().log(
      '[Recovery] Catch-up suspend window: $from → $to '
      '(${to.difference(from).inMinutes} min)',
    );
    const dbMap = {
      'trend': 'trend.db',
      'meter': 'meter.db',
      'optime': 'optime.db',
      'ppd': 'ppd.db',
      'history': 'history.db',
    };
    for (final entry in dbMap.entries) {
      final dbFile = entry.value;
      final interval = kDbWriteIntervals[dbFile];
      // Advance `from` to the first boundary strictly AFTER suspendTime so the
      // boundary at suspendTime — already written to MAIN by the TEMP flush —
      // is not re-requested.  DBs without a UNIQUE(date, id) constraint (e.g.
      // trend) would otherwise receive duplicate rows for that boundary.
      final catchUpFrom = (interval != null && interval.inMinutes < 60)
          ? previousWriteBoundary(from, interval.inMinutes).add(interval)
          : from;
      if (!catchUpFrom.isBefore(to)) continue;
      final r = await _fillSinglePeriodFromController(
        entry.key,
        GapRange(dbFile: dbFile, start: catchUpFrom, end: to),
      );
      summaries.update(entry.key, (s) => s.merge(r), ifAbsent: () => r);
    }
  }

  static String _dbTypeLabel(String type) => switch (type) {
    'meter' => 'Energy Metering',
    'optime' => 'Operation Time',
    'ppd' => 'PPD Data',
    'trend' => 'Trend Data',
    'history' => 'Operation History',
    _ => type,
  };

  /// Fetches a single discrete gap [period] for [type] from the controller,
  /// writes the result directly into MAIN DB, and returns a [_GapSummary]
  /// with the record count and date span of the received data.
  Future<_GapSummary> _fillSinglePeriodFromController(
    String type,
    GapRange period,
  ) async {
    final dbFile = period.dbFile;
    final interval = kDbWriteIntervals[dbFile];
    final rawFrom = period.start;

    // History is event-based: request the full day from midnight of the gap
    // start until now, then delete+replace that range in MAIN DB so partial
    // day records (written before the disconnect) are removed and the complete
    // controller data is re-inserted cleanly.
    final bool isHistory = type == 'history';
    final DateTime from;
    final DateTime to;
    if (isHistory) {
      from = DateTime(rawFrom.year, rawFrom.month, rawFrom.day);
      to = DateTime.now();
    } else {
      if (interval != null && interval.inMinutes < 60) {
        final window = intervalRecoveryWindow(
          dbType: type,
          gapStart: rawFrom,
          gapEnd: period.end,
          intervalMinutes: interval.inMinutes,
        );
        from = window.from;
        to = window.to;
      } else {
        from = rawFrom;
        to = period.end;
      }
    }

    FileLogService().log('[Recovery] Gap-fill: requesting $type  $from → $to');

    final cmd = BackupDbAccess();
    final ok = cmd.dbBackup(type, from, to);
    if (!ok) {
      final error = RecoveryDataUnavailableException(
        '$type recovery request was rejected',
      );
      FileLogService().log('[Recovery] Gap-fill: $error');
      throw error;
    }

    final completer = Completer<List<dynamic>?>();
    final sub = ref.listen<Map<String, dynamic>?>(communicationProvider(cmd), (
      _,
      data,
    ) {
      if (data != null && !completer.isCompleted) {
        final records = data['data'];
        completer.complete(
          records is List ? List<dynamic>.from(records) : null,
        );
      }
    });
    try {
      app.requestController(cmd);
      final response = await completer.future.timeout(
        const Duration(seconds: 120),
      );
      final records = requireRecoveryRecords(dbType: type, records: response);
      if (records.isNotEmpty) {
        // Log the date span the controller actually returned so a short gap-fill
        // (records dropped/missing) is visible without re-querying the DB.
        final rawDates = records
            .map((r) => (r is List && r.isNotEmpty) ? r[0] : null)
            .whereType<Object>()
            .toList();
        final span = rawDates.isEmpty
            ? 'n/a'
            : '${rawDates.reduce((a, b) => (a as Comparable).compareTo(b) <= 0 ? a : b)}'
                  '..${rawDates.reduce((a, b) => (a as Comparable).compareTo(b) >= 0 ? a : b)}';
        FileLogService().log(
          '[Recovery] Gap-fill: $type received ${records.length} record(s), date span $span',
        );
        await _service!.fillGapInMainDb(
          type,
          records,
          deleteFrom: isHistory ? from : null,
        );

        // Convert min/max DB int dates to DateTime for the backup log entry.
        final dateTimes = rawDates
            .map((v) => v is int && v > 0 ? dbIntToDateTime(v) : null)
            .whereType<DateTime>()
            .toList();
        final first = dateTimes.isEmpty
            ? null
            : dateTimes.reduce((a, b) => a.isBefore(b) ? a : b);
        final last = dateTimes.isEmpty
            ? null
            : dateTimes.reduce((a, b) => a.isAfter(b) ? a : b);
        return _GapSummary(
          count: records.length,
          first: first,
          last: last,
          rawRecords: records,
        );
      } else {
        // Only event-based history is allowed to complete with no records.
        FileLogService().log(
          '[Recovery] Gap-fill: no records for $type $from → $to',
        );
        return const _GapSummary(count: 0);
      }
    } on TimeoutException catch (e) {
      final error = RecoveryDataUnavailableException(
        '$type recovery timed out after 120 seconds',
      );
      FileLogService().log('[Recovery] Gap-fill: $error ($e)');
      throw error;
    } on RecoveryDataUnavailableException catch (e) {
      FileLogService().log('[Recovery] Gap-fill: $e');
      rethrow;
    } catch (e) {
      final error = RecoveryDataUnavailableException(
        '$type recovery failed: $e',
      );
      FileLogService().log('[Recovery] Gap-fill: $error');
      throw error;
    } finally {
      sub.close();
    }
  }

  DateTime _nextOffPeak() => RecoveryService.nextOffPeakTime(
    hour: _recoveryHour,
    minute: _recoveryMinute,
  );
}
