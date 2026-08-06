import 'package:flutter_test/flutter_test.dart';
import 'package:reiri_db_backup_tool/lib/recovery_time_window.dart';

void main() {
  test('detects a short outage inside the delayed-write grace period', () {
    expect(
      scheduledWriteMayBeMissed(
        gapStart: DateTime(2026, 7, 7, 13, 45, 35),
        reconnectAt: DateTime(2026, 7, 7, 13, 45, 46),
        intervalMinutes: 15,
      ),
      isTrue,
    );
  });

  test('does not flag a short outage outside a boundary grace period', () {
    expect(
      scheduledWriteMayBeMissed(
        gapStart: DateTime(2026, 7, 7, 13, 46, 1),
        reconnectAt: DateTime(2026, 7, 7, 13, 46, 30),
        intervalMinutes: 15,
      ),
      isFalse,
    );
  });

  test('accumulated DB request includes the preceding stamped interval', () {
    final window = intervalRecoveryWindow(
      dbType: 'ppd',
      gapStart: DateTime(2026, 7, 7, 13, 45, 35),
      gapEnd: DateTime(2026, 7, 7, 13, 45, 46),
      intervalMinutes: 15,
    );

    expect(window.from, DateTime(2026, 7, 7, 13, 30));
    expect(window.to, DateTime(2026, 7, 7, 14, 0, 46));
  });

  test('trend request starts at its current boundary', () {
    final window = intervalRecoveryWindow(
      dbType: 'trend',
      gapStart: DateTime(2026, 7, 7, 13, 45, 35),
      gapEnd: DateTime(2026, 7, 7, 13, 45, 46),
      intervalMinutes: 5,
    );

    expect(window.from, DateTime(2026, 7, 7, 13, 45));
    expect(window.to, DateTime(2026, 7, 7, 13, 50, 46));
  });

  test('latest recovery boundary observes controller write grace', () {
    final readyAt = recoveryBoundaryReadyAt(
      gapEnd: DateTime(2026, 8, 3, 14, 5, 16),
      intervalMinutes: 5,
    );

    expect(readyAt, DateTime(2026, 8, 3, 14, 6));
  });

  group('automatic short-gap recovery', () {
    test('accepts one or more gaps shorter than one minute', () {
      expect(
        shouldAutomaticallyRecoverShortGaps(const [
          Duration(seconds: 40),
          Duration(seconds: 59),
        ]),
        isTrue,
      );
    });

    test('rejects a gap exactly one minute long', () {
      expect(
        shouldAutomaticallyRecoverShortGaps(const [Duration(minutes: 1)]),
        isFalse,
      );
    });

    test('rejects mixed short and scheduled gaps', () {
      expect(
        shouldAutomaticallyRecoverShortGaps(const [
          Duration(seconds: 20),
          Duration(minutes: 3),
        ]),
        isFalse,
      );
    });

    test('rejects an empty gap collection', () {
      expect(shouldAutomaticallyRecoverShortGaps(const []), isFalse);
    });
  });

  group('scheduled recovery retry', () {
    final dueAt = DateTime(2026, 8, 6, 14, 45);

    test('does not start while the controller is disconnected', () {
      expect(
        scheduledRecoveryMayStart(
          now: DateTime(2026, 8, 6, 14, 46),
          scheduledAt: dueAt,
          isFlushing: false,
          controllerConnected: false,
        ),
        isFalse,
      );
    });

    test('starts an overdue recovery after the controller reconnects', () {
      expect(
        scheduledRecoveryMayStart(
          now: DateTime(2026, 8, 6, 14, 47),
          scheduledAt: dueAt,
          isFlushing: false,
          controllerConnected: true,
        ),
        isTrue,
      );
    });

    test('preserves an overdue appointment while gaps remain pending', () {
      var recalculated = false;
      final scheduledAt = pendingRecoverySchedule(
        hasPendingGaps: true,
        existingSchedule: dueAt,
        nextSchedule: () {
          recalculated = true;
          return DateTime(2026, 8, 7, 14, 45);
        },
      );

      expect(scheduledAt, dueAt);
      expect(recalculated, isFalse);
    });

    test('clears the appointment when recovery has no pending gaps', () {
      expect(
        pendingRecoverySchedule(
          hasPendingGaps: false,
          existingSchedule: dueAt,
          nextSchedule: () => DateTime(2026, 8, 7, 14, 45),
        ),
        isNull,
      );
    });
  });
}
