import 'package:flutter_test/flutter_test.dart';
import 'package:reiri_db_backup_tool/lib/date_time_utils.dart';

void main() {
  group('dbIntToDateTime', () {
    test('converts the DB YYYYMMDDHHmm representation', () {
      expect(dbIntToDateTime(202607290405), DateTime(2026, 7, 29, 4, 5));
    });

    test('preserves the existing DateTime normalization behavior', () {
      expect(dbIntToDateTime(202613010000), DateTime(2027, 1));
    });
  });

  group('formatDateTime', () {
    final date = DateTime(2026, 7, 9, 4, 5, 6);

    test('omits seconds for home and recovery views', () {
      expect(formatDateTime(date), '09 Jul 04:05');
    });

    test('includes seconds for backup log display and CSV export', () {
      expect(formatDateTime(date, includeSeconds: true), '09 Jul 04:05:06');
    });
  });

  group('formatScheduledDateTime', () {
    final now = DateTime(2026, 7, 29, 10);

    test('uses Today before 18:00 on the current date', () {
      expect(
        formatScheduledDateTime(DateTime(2026, 7, 29, 17, 5), now: now),
        'Today 17:05',
      );
    });

    test('uses Tonight from 18:00 on the current date', () {
      expect(
        formatScheduledDateTime(DateTime(2026, 7, 29, 18, 5), now: now),
        'Tonight 18:05',
      );
    });

    test('uses abbreviated month and unpadded day on another date', () {
      expect(
        formatScheduledDateTime(DateTime(2026, 12, 3, 4, 5), now: now),
        'Dec 3 04:05',
      );
    });
  });
}
