/// Write intervals per DB type (from system design).
/// Used to determine whether any records were missed during a disconnect gap.
const Map<String, Duration> kDbWriteIntervals = {
  'history.db': Duration(hours: 24), // event-based; 24h conservative threshold
  'meter.db':   Duration(minutes: 15),
  'optime.db':  Duration(minutes: 15),
  'ppd.db':     Duration(minutes: 15),
  'trend.db':   Duration(minutes: 5),
};

/// A detected gap for a single DB file.
class GapRange {
  final String dbFile;
  final DateTime start;
  final DateTime end;

  const GapRange({
    required this.dbFile,
    required this.start,
    required this.end,
  });

  Duration get duration => end.difference(start);

  Map<String, dynamic> toJson() => {
    'dbFile': dbFile,
    'start': start.toIso8601String(),
    'end': end.toIso8601String(),
  };

  factory GapRange.fromJson(Map<String, dynamic> j) => GapRange(
    dbFile: j['dbFile'] as String,
    start: DateTime.parse(j['start'] as String),
    end: DateTime.parse(j['end'] as String),
  );
}

/// Where real-time backup is currently writing.
enum BackupState {
  idle,           // not yet connected / no gap
  realtimeTemp,   // gap detected — real-time writes go to TEMP DB
  realtimeMain,   // no gap (or flush done) — real-time writes go to MAIN DB
}

/// Progress of the TEMP → MAIN flush operation.
enum FlushStatus { none, pending, inProgress, completed }

/// Persisted state that survives app crashes (stored in backup_metadata.json).
class BackupMetadata {
  /// When the last connection dropped (or the app closed).
  final DateTime? disconnectedAt;

  /// When the app most recently connected to the controller.
  final DateTime? tConnect;

  final BackupState backupState;
  final FlushStatus flushStatus;

  /// Gaps detected on the last reconnect, one entry per affected DB file.
  final List<GapRange> detectedGaps;

  /// Absolute path to the TEMP DB directory (null when no temp exists).
  final String? tempDbPath;

  const BackupMetadata({
    this.disconnectedAt,
    this.tConnect,
    this.backupState = BackupState.idle,
    this.flushStatus = FlushStatus.none,
    this.detectedGaps = const [],
    this.tempDbPath,
  });

  BackupMetadata copyWith({
    DateTime? disconnectedAt,
    DateTime? tConnect,
    BackupState? backupState,
    FlushStatus? flushStatus,
    List<GapRange>? detectedGaps,
    String? tempDbPath,
    bool clearDisconnectedAt = false,
    bool clearTConnect = false,
    bool clearTempDbPath = false,
  }) {
    return BackupMetadata(
      disconnectedAt: clearDisconnectedAt
          ? null
          : (disconnectedAt ?? this.disconnectedAt),
      tConnect: clearTConnect ? null : (tConnect ?? this.tConnect),
      backupState: backupState ?? this.backupState,
      flushStatus: flushStatus ?? this.flushStatus,
      detectedGaps: detectedGaps ?? this.detectedGaps,
      tempDbPath: clearTempDbPath ? null : (tempDbPath ?? this.tempDbPath),
    );
  }

  Map<String, dynamic> toJson() => {
    'disconnectedAt': disconnectedAt?.toIso8601String(),
    'tConnect': tConnect?.toIso8601String(),
    'backupState': backupState.name,
    'flushStatus': flushStatus.name,
    'detectedGaps': detectedGaps.map((g) => g.toJson()).toList(),
    'tempDbPath': tempDbPath,
  };

  factory BackupMetadata.fromJson(Map<String, dynamic> j) => BackupMetadata(
    disconnectedAt: j['disconnectedAt'] != null
        ? DateTime.parse(j['disconnectedAt'] as String)
        : null,
    tConnect: j['tConnect'] != null
        ? DateTime.parse(j['tConnect'] as String)
        : null,
    backupState: BackupState.values.firstWhere(
      (e) => e.name == j['backupState'],
      orElse: () => BackupState.idle,
    ),
    flushStatus: FlushStatus.values.firstWhere(
      (e) => e.name == j['flushStatus'],
      orElse: () => FlushStatus.none,
    ),
    detectedGaps: (j['detectedGaps'] as List<dynamic>? ?? [])
        .map((g) => GapRange.fromJson(g as Map<String, dynamic>))
        .toList(),
    tempDbPath: j['tempDbPath'] as String?,
  );

  factory BackupMetadata.empty() => const BackupMetadata();
}
