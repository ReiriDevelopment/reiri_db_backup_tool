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
}
