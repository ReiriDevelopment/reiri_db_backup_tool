/// Controller database writes can arrive shortly after their nominal clock
/// boundary. A disconnect inside this grace period is treated conservatively
/// as potentially missing that boundary's write.
const Duration kControllerWriteGrace = Duration(minutes: 1);

/// Returns the latest clock boundary less than or equal to [from].
DateTime previousWriteBoundary(DateTime from, int intervalMinutes) {
  final minutes = from.hour * 60 + from.minute;
  final previous = (minutes ~/ intervalMinutes) * intervalMinutes;
  return DateTime(
    from.year,
    from.month,
    from.day,
    previous ~/ 60,
    previous % 60,
  );
}

/// Returns whether a scheduled controller push may have occurred while the
/// connection was unavailable.
///
/// In addition to boundaries strictly inside the gap, this includes the
/// boundary immediately before [gapStart] when the disconnect began within
/// [grace] of that boundary. In field logs, writes stamped at `13:30` were
/// delivered around `13:45:58`, so exact-boundary checks lost these records.
bool scheduledWriteMayBeMissed({
  required DateTime gapStart,
  required DateTime reconnectAt,
  required int intervalMinutes,
  Duration grace = kControllerWriteGrace,
}) {
  if (!reconnectAt.isAfter(gapStart)) return false;

  final previous = previousWriteBoundary(gapStart, intervalMinutes);
  if (!gapStart.isAfter(previous.add(grace))) return true;

  final next = previous.add(Duration(minutes: intervalMinutes));
  return !next.isAfter(reconnectAt);
}

/// Controller request bounds for one interval-database recovery period.
class RecoveryRequestWindow {
  const RecoveryRequestWindow({required this.from, required this.to});

  final DateTime from;
  final DateTime to;
}

/// Builds conservative controller `dbBackup` bounds.
///
/// Meter, optime, and PPD packets are delivered on a boundary but carry the
/// previous interval's timestamp. Their lower bound therefore backs up one
/// additional interval. The controller upper bound is exclusive, so [to]
/// extends by one interval.
RecoveryRequestWindow intervalRecoveryWindow({
  required String dbType,
  required DateTime gapStart,
  required DateTime gapEnd,
  required int intervalMinutes,
}) {
  var from = previousWriteBoundary(gapStart, intervalMinutes);
  if (dbType == 'meter' || dbType == 'optime' || dbType == 'ppd') {
    from = from.subtract(Duration(minutes: intervalMinutes));
  }
  return RecoveryRequestWindow(
    from: from,
    to: gapEnd.add(Duration(minutes: intervalMinutes)),
  );
}
