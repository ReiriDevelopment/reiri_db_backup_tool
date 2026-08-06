// File purpose: Validates controller recovery responses before database insertion.

import 'package:reiri_db_backup_tool/model/backup_database.dart';

/// Signals a malformed response that must leave the gap and TEMP DB intact.
class RecoveryDataUnavailableException implements Exception {
  const RecoveryDataUnavailableException(this.message);

  final String message;

  @override
  String toString() => 'RecoveryDataUnavailableException: $message';
}

/// Validates the shape of a controller `*_db_backup` payload.
///
/// Empty responses and gaps between returned interval timestamps are valid:
/// the controller database is the source of truth and may itself have no row
/// for part (or all) of the requested period.
List<dynamic> requireRecoveryRecords({
  required BackupDatabase database,
  required List<dynamic>? records,
}) {
  final dbType = database.type;
  if (records == null) {
    throw RecoveryDataUnavailableException(
      '$dbType recovery returned an invalid data payload',
    );
  }
  return records;
}
