// File purpose: Calculates safe request and scheduling windows for recovery operations.

/// Treat disconnects near a write boundary as potentially missing its record.
const Duration kControllerWriteGrace = Duration(minutes: 1);

/// Gaps shorter than this are recovered automatically instead of waiting for
/// the configured off-peak schedule.
const Duration kAutomaticShortGapThreshold = Duration(minutes: 1);

/// Whether every pending recovery period is short enough to fill immediately.
/// An empty collection is not recovery work and therefore returns false.
bool shouldAutomaticallyRecoverShortGaps(
  Iterable<Duration> gapDurations, {
  Duration threshold = kAutomaticShortGapThreshold,
}) {
  var foundGap = false;
  for (final duration in gapDurations) {
    foundGap = true;
    if (duration >= threshold) return false;
  }
  return foundGap;
}

/// Keeps an existing recovery appointment while work remains pending.
///
/// In particular, an overdue appointment must survive a failed recovery so it
/// can be retried as soon as the controller reconnects instead of being moved
/// to tomorrow.
DateTime? pendingRecoverySchedule({
  required bool hasPendingGaps,
  required DateTime? existingSchedule,
  required DateTime Function() nextSchedule,
}) {
  if (!hasPendingGaps) return null;
  return existingSchedule ?? nextSchedule();
}

/// Whether scheduled recovery can safely start at [now].
bool scheduledRecoveryMayStart({
  required DateTime now,
  required DateTime? scheduledAt,
  required bool isFlushing,
  required bool controllerConnected,
}) {
  if (!controllerConnected || isFlushing || scheduledAt == null) return false;
  return !now.isBefore(scheduledAt);
}

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

/// Whether an unavailable window may contain a scheduled push.
/// [grace] includes delayed delivery from the preceding boundary.
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

/// Earliest time the controller's latest interval batch should be complete.
DateTime recoveryBoundaryReadyAt({
  required DateTime gapEnd,
  required int intervalMinutes,
  Duration grace = kControllerWriteGrace,
}) => previousWriteBoundary(gapEnd, intervalMinutes).add(grace);

/// Controller request bounds for one interval-database recovery period.
class RecoveryRequestWindow {
  const RecoveryRequestWindow({required this.from, required this.to});

  final DateTime from;
  final DateTime to;
}

/// Builds conservative controller request bounds.
/// Accumulated DBs include the prior interval; [to] is exclusive.
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
