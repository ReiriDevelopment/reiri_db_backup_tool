import 'package:flutter_test/flutter_test.dart';

import 'package:reiri_db_backup_tool/lib/database_record_progress.dart';

void main() {
  test(
    'interval database advances only when its record timestamp advances',
    () {
      expect(
        hasDatabaseRecordAdvanced(
          previousTimestamp: 202608031215,
          latestTimestamp: 202608031230,
        ),
        isTrue,
      );
      expect(
        hasDatabaseRecordAdvanced(
          previousTimestamp: 202608031215,
          latestTimestamp: 202608031215,
        ),
        isFalse,
      );
    },
  );

  test('history can advance with another row at the same timestamp', () {
    expect(
      hasDatabaseRecordAdvanced(
        previousTimestamp: 202608031215,
        latestTimestamp: 202608031215,
        eventBased: true,
        previousRowId: 10,
        latestRowId: 11,
      ),
      isTrue,
    );
  });
}
