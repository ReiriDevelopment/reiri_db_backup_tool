/// Raised when a controller recovery response cannot safely be treated as
/// complete. Callers must keep the recovery gap and TEMP database intact so
/// the request can be retried.
class RecoveryDataUnavailableException implements Exception {
  const RecoveryDataUnavailableException(this.message);

  final String message;

  @override
  String toString() => 'RecoveryDataUnavailableException: $message';
}

/// Validates the payload returned by a controller `*_db_backup` request.
///
/// An empty history response is valid because history is event-based. Interval
/// databases are only scheduled when a write boundary may have been missed, so
/// completing such a recovery with no records would silently leave a hole.
List<dynamic> requireRecoveryRecords({
  required String dbType,
  required List<dynamic>? records,
}) {
  if (records == null) {
    throw RecoveryDataUnavailableException(
      '$dbType recovery returned an invalid data payload',
    );
  }
  if (records.isEmpty && dbType != 'history') {
    throw RecoveryDataUnavailableException(
      '$dbType recovery returned no interval records',
    );
  }
  return records;
}
