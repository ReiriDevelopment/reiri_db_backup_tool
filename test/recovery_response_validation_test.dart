import 'package:flutter_test/flutter_test.dart';
import 'package:reiri_db_backup_tool/lib/recovery_response_validation.dart';

void main() {
  test('rejects an invalid controller recovery payload', () {
    expect(
      () => requireRecoveryRecords(dbType: 'trend', records: null),
      throwsA(isA<RecoveryDataUnavailableException>()),
    );
  });

  test('rejects an empty interval database response', () {
    expect(
      () => requireRecoveryRecords(dbType: 'trend', records: const []),
      throwsA(isA<RecoveryDataUnavailableException>()),
    );
  });

  test('allows an empty event-based history response', () {
    expect(
      requireRecoveryRecords(dbType: 'history', records: const []),
      isEmpty,
    );
  });

  test('returns interval records unchanged', () {
    final records = <dynamic>[
      [202607221605, 'dss4-point', 'temp', 24.5],
    ];

    expect(
      requireRecoveryRecords(dbType: 'trend', records: records),
      same(records),
    );
  });
}
