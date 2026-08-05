import 'package:flutter_test/flutter_test.dart';
import 'package:reiri_db_backup_tool/model/backup_database.dart';

void main() {
  test('preserves the existing initial-backup filenames and order', () {
    expect(BackupDatabase.fileNames, const [
      'history.db',
      'meter.db',
      'optime.db',
      'trend.db',
      'ppd.db',
    ]);
  });

  test('preserves existing gap-detection and recovery orders', () {
    expect(BackupDatabase.gapDetectionOrder, const [
      BackupDatabase.meter,
      BackupDatabase.optime,
      BackupDatabase.ppd,
      BackupDatabase.trend,
    ]);
    expect(BackupDatabase.recoveryOrder, const [
      BackupDatabase.trend,
      BackupDatabase.meter,
      BackupDatabase.optime,
      BackupDatabase.ppd,
      BackupDatabase.history,
    ]);
  });

  test('resolves persisted filenames and controller types', () {
    for (final database in BackupDatabase.values) {
      expect(BackupDatabase.tryFromFileName(database.fileName), same(database));
      expect(BackupDatabase.tryFromType(database.type), same(database));
    }

    expect(BackupDatabase.tryFromFileName('unknown.db'), isNull);
    expect(BackupDatabase.tryFromType('unknown'), isNull);
  });

  test('keeps history event-based and other databases interval-based', () {
    expect(BackupDatabase.history.eventBased, isTrue);
    expect(BackupDatabase.history.interval, isNull);
    expect(BackupDatabase.history.usesPointId, isFalse);

    for (final database in BackupDatabase.values.where(
      (database) => database != BackupDatabase.history,
    )) {
      expect(database.eventBased, isFalse);
      expect(database.interval, isNotNull);
      expect(database.usesPointId, isTrue);
    }
  });
}
