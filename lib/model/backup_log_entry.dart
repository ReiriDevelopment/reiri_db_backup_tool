enum BackupLogType { realtime, recovery }

enum BackupLogResult { success, fail }

class BackupLogEntry {
  const BackupLogEntry({
    required this.timestamp,
    required this.type,
    required this.result,
    required this.database,
    this.backedUpAt,
  });

  /// When the controller wrote the data (file mod time for real-time;
  /// same as [backedUpAt] for recovery since we have no per-record timestamps).
  final DateTime timestamp;

  /// When the app detected and saved the backup event.
  /// Null for entries loaded from storage before this field was added.
  final DateTime? backedUpAt;

  final BackupLogType type;
  final BackupLogResult result;
  final String database;

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'backedUpAt': backedUpAt?.toIso8601String(),
        'type': type.name,
        'result': result.name,
        'database': database,
      };

  factory BackupLogEntry.fromJson(Map<String, dynamic> json) => BackupLogEntry(
        timestamp: DateTime.parse(json['timestamp'] as String),
        backedUpAt: json['backedUpAt'] != null
            ? DateTime.parse(json['backedUpAt'] as String)
            : null,
        type: BackupLogType.values.firstWhere(
          (e) => e.name == json['type'],
          orElse: () => BackupLogType.realtime,
        ),
        result: BackupLogResult.values.firstWhere(
          (e) => e.name == json['result'],
          orElse: () => BackupLogResult.success,
        ),
        database: json['database'] as String? ?? '',
      );
}
