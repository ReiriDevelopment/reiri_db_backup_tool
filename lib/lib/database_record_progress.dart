// File purpose: Determines whether a database's latest-record marker has advanced.

/// Whether the database contains a record event newer than the last observed
/// progress marker.
///
/// Interval databases advance by timestamp. Event-based history can contain
/// multiple rows at the same minute, so its row ID is also considered.
bool hasDatabaseRecordAdvanced({
  required int previousTimestamp,
  required int latestTimestamp,
  bool eventBased = false,
  int? previousRowId,
  int? latestRowId,
}) {
  if (latestTimestamp > previousTimestamp) return true;
  return eventBased &&
      latestTimestamp == previousTimestamp &&
      previousRowId != null &&
      latestRowId != null &&
      latestRowId > previousRowId;
}
