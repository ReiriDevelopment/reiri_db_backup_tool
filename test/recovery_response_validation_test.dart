import 'package:flutter_test/flutter_test.dart';
import 'package:reiri_db_backup_tool/lib/recovery_response_validation.dart';
import 'package:reiri_db_backup_tool/model/backup_database.dart';

void main() {
  test('rejects an invalid controller recovery payload', () {
    expect(
      () =>
          requireRecoveryRecords(database: BackupDatabase.trend, records: null),
      throwsA(isA<RecoveryDataUnavailableException>()),
    );
  });

  test('accepts an empty interval database response', () {
    expect(
      requireRecoveryRecords(database: BackupDatabase.trend, records: const []),
      isEmpty,
    );
  });

  test('allows an empty event-based history response', () {
    expect(
      requireRecoveryRecords(
        database: BackupDatabase.history,
        records: const [],
      ),
      isEmpty,
    );
  });

  test('returns interval records unchanged', () {
    final records = <dynamic>[
      [202607221605, 'dss4-point', 'temp', 24.5],
    ];

    expect(
      requireRecoveryRecords(database: BackupDatabase.trend, records: records),
      same(records),
    );
  });

  test('accepts a response with missing interval timestamps', () {
    final records = <dynamic>[
      [202608050930, 'point-1'],
      [202608051000, 'point-1'],
      [202608051015, 'point-1'],
    ];

    expect(
      requireRecoveryRecords(database: BackupDatabase.meter, records: records),
      same(records),
    );
  });
}
