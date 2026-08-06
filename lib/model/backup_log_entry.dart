// File purpose: Defines backup log entry data and JSON serialization.

/// Identifies whether a log entry came from real-time or recovery backup.
enum BackupLogType { realtime, recovery }

/// Legacy persisted result field. New backup-history entries are created only
/// after a database write is confirmed and therefore use
/// [BackupLogResult.success].
enum BackupLogResult { success, fail }

/// Stores one persisted backup activity record for display and export.
class BackupLogEntry {
  const BackupLogEntry({
    required this.timestamp,
    required this.type,
    required this.result,
    required this.database,
    this.backedUpAt,
    this.details,
  });

  /// When the controller record was written (latest confirmed DB record time
  /// for real-time; earliest record date from the response for recovery).
  final DateTime timestamp;

  /// When the app detected and saved the backup event.
  /// Null for entries loaded from storage before this field was added.
  final DateTime? backedUpAt;

  final BackupLogType type;

  /// Retained for backward-compatible loading of existing BACKUP_LOG_V1 data.
  /// The backup-history UI no longer presents this field.
  final BackupLogResult result;
  final String database;

  /// JSON controller records for recovery entries; null for realtime entries.
  final String? details;

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'backedUpAt': backedUpAt?.toIso8601String(),
    'type': type.name,
    'result': result.name,
    'database': database,
    if (details != null) 'details': details,
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
    details: json['details'] as String?,
  );
}
