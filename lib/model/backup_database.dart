/// Defines the identity and shared behavior of a database managed by backup
/// and recovery.
///
/// Keep [fileName] and [type] stable: filenames are persisted in backup
/// metadata, while type values are part of the controller protocol.
enum BackupDatabase {
  history(
    fileName: 'history.db',
    type: 'history',
    interval: null,
    descriptionKey: 'db_desc_history_event',
    eventBased: true,
    usesPointId: false,
  ),
  meter(
    fileName: 'meter.db',
    type: 'meter',
    interval: Duration(minutes: 15),
    descriptionKey: 'db_desc_meter_data',
    eventBased: false,
    usesPointId: true,
  ),
  optime(
    fileName: 'optime.db',
    type: 'optime',
    interval: Duration(minutes: 15),
    descriptionKey: 'op_time',
    eventBased: false,
    usesPointId: true,
  ),
  trend(
    fileName: 'trend.db',
    type: 'trend',
    interval: Duration(minutes: 5),
    descriptionKey: 'db_desc_trend_data',
    eventBased: false,
    usesPointId: true,
  ),
  ppd(
    fileName: 'ppd.db',
    type: 'ppd',
    interval: Duration(minutes: 15),
    descriptionKey: 'db_desc_ppd_data',
    eventBased: false,
    usesPointId: true,
  );

  const BackupDatabase({
    required this.fileName,
    required this.type,
    required this.interval,
    required this.descriptionKey,
    required this.eventBased,
    required this.usesPointId,
  });

  /// Filename used on disk and in persisted backup metadata.
  final String fileName;

  /// Stable short identifier used by the controller backup protocol.
  final String type;

  /// Scheduled controller write interval, or null for event-based databases.
  final Duration? interval;

  /// Localization key used for dashboard and recovery labels.
  final String descriptionKey;

  /// Whether records are produced by events instead of a fixed schedule.
  final bool eventBased;

  /// Whether the database uses a surrogate `point_id` mapping.
  final bool usesPointId;

  static BackupDatabase? tryFromFileName(String fileName) {
    for (final database in values) {
      if (database.fileName == fileName) return database;
    }
    return null;
  }

  static BackupDatabase? tryFromType(String type) {
    for (final database in values) {
      if (database.type == type) return database;
    }
    return null;
  }

  static final List<String> fileNames = List.unmodifiable(
    values.map((database) => database.fileName),
  );

  /// Existing scheduled-gap detection order.
  static const List<BackupDatabase> gapDetectionOrder = [
    meter,
    optime,
    ppd,
    trend,
  ];

  /// Existing controller recovery order, kept stable during centralization.
  static const List<BackupDatabase> recoveryOrder = [
    trend,
    meter,
    optime,
    ppd,
    history,
  ];
}
