/// Write intervals per DB type (from system design).
/// Used to determine whether any records were missed during a disconnect gap.
const Map<String, Duration> kDbWriteIntervals = {
  'history.db': Duration(hours: 24), // event-based; 24h conservative threshold
  'meter.db': Duration(minutes: 15),
  'optime.db': Duration(minutes: 15),
  'ppd.db': Duration(minutes: 15),
  'trend.db': Duration(minutes: 5),
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
  idle, // not yet connected / no gap
  realtimeTemp, // gap detected — real-time writes go to TEMP DB
  realtimeMain, // no gap (or flush done) — real-time writes go to MAIN DB
}

/// Progress of the TEMP → MAIN flush operation.
enum FlushStatus { none, pending, inProgress, completed }

/// Persisted state that survives app crashes (stored in backup_metadata.json).
class BackupMetadata {
  /// Earliest known start of the current disconnect window.
  ///
  /// Once set, this value must not move forward until the next connection
  /// consumes
  /// it.  Older app versions also used this field as a rolling heartbeat; the
  /// loader keeps accepting that representation for backwards compatibility.
  final DateTime? disconnectedAt;

  /// Most recent time the controller was confirmed reachable while real-time
  /// backup was healthy. Kept separate from [disconnectedAt] so a delayed
  /// WebSocket disconnect, logout, or widget disposal cannot erase a real gap.
  final DateTime? lastHealthyAt;

  /// When the app most recently connected to the controller.
  final DateTime? tConnect;

  final BackupState backupState;
  final FlushStatus flushStatus;

  /// One entry per affected DB file with the **merged** time range covering
  /// all disconnect periods. Used for gap-fill and flush operations — merging
  /// ensures rows are appended to MAIN in chronological order.
  final List<GapRange> detectedGaps;

  /// Every discrete disconnect period accumulated since the last flush.
  /// May contain multiple entries for the same DB file. Used only for display.
  final List<GapRange> gapPeriods;

  /// Absolute path to the TEMP DB directory (null when no temp exists).
  final String? tempDbPath;

  /// When true, [HomeScreen] will trigger gap-fill automatically on the first
  /// connect after an initial FTP/local-import setup, without requiring the
  /// user to navigate to the recovery page.
  final bool autoFill;

  const BackupMetadata({
    this.disconnectedAt,
    this.lastHealthyAt,
    this.tConnect,
    this.backupState = BackupState.idle,
    this.flushStatus = FlushStatus.none,
    this.detectedGaps = const [],
    this.gapPeriods = const [],
    this.tempDbPath,
    this.autoFill = false,
  });

  BackupMetadata copyWith({
    DateTime? disconnectedAt,
    DateTime? lastHealthyAt,
    DateTime? tConnect,
    BackupState? backupState,
    FlushStatus? flushStatus,
    List<GapRange>? detectedGaps,
    List<GapRange>? gapPeriods,
    String? tempDbPath,
    bool clearDisconnectedAt = false,
    bool clearLastHealthyAt = false,
    bool clearTConnect = false,
    bool clearTempDbPath = false,
    bool? autoFill,
  }) {
    return BackupMetadata(
      disconnectedAt: clearDisconnectedAt
          ? null
          : (disconnectedAt ?? this.disconnectedAt),
      lastHealthyAt: clearLastHealthyAt
          ? null
          : (lastHealthyAt ?? this.lastHealthyAt),
      tConnect: clearTConnect ? null : (tConnect ?? this.tConnect),
      backupState: backupState ?? this.backupState,
      flushStatus: flushStatus ?? this.flushStatus,
      detectedGaps: detectedGaps ?? this.detectedGaps,
      gapPeriods: gapPeriods ?? this.gapPeriods,
      tempDbPath: clearTempDbPath ? null : (tempDbPath ?? this.tempDbPath),
      autoFill: autoFill ?? this.autoFill,
    );
  }

  Map<String, dynamic> toJson() => {
    'disconnectedAt': disconnectedAt?.toIso8601String(),
    'lastHealthyAt': lastHealthyAt?.toIso8601String(),
    'tConnect': tConnect?.toIso8601String(),
    'backupState': backupState.name,
    'flushStatus': flushStatus.name,
    'detectedGaps': detectedGaps.map((g) => g.toJson()).toList(),
    'gapPeriods': gapPeriods.map((g) => g.toJson()).toList(),
    'tempDbPath': tempDbPath,
    'autoFill': autoFill,
  };

  factory BackupMetadata.fromJson(Map<String, dynamic> j) => BackupMetadata(
    disconnectedAt: j['disconnectedAt'] != null
        ? DateTime.parse(j['disconnectedAt'] as String)
        : null,
    lastHealthyAt: j['lastHealthyAt'] != null
        ? DateTime.parse(j['lastHealthyAt'] as String)
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
    gapPeriods: (j['gapPeriods'] as List<dynamic>? ?? [])
        .map((g) => GapRange.fromJson(g as Map<String, dynamic>))
        .toList(),
    tempDbPath: j['tempDbPath'] as String?,
    autoFill: j['autoFill'] as bool? ?? false,
  );

  factory BackupMetadata.empty() => const BackupMetadata();
}
