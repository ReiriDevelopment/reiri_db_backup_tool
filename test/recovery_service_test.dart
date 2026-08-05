import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reiri_db_backup_tool/model/backup_metadata.dart';
import 'package:reiri_db_backup_tool/service/backup_metadata_service.dart';
import 'package:reiri_db_backup_tool/service/recovery_service.dart';

void main() {
  test(
    'interrupted flush is queued for the coordinator without clearing gaps',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'reiri_recovery_service_test_',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      const safeMac = 'controller';
      final macDirectory = Directory('${root.path}\\$safeMac');
      await macDirectory.create(recursive: true);
      final gap = GapRange(
        dbFile: 'trend.db',
        start: DateTime(2026, 7, 30, 10),
        end: DateTime(2026, 7, 30, 11),
      );
      final metadata = BackupMetadataService();
      await metadata.init(macDirectory.path);
      await metadata.save(
        BackupMetadata(
          backupState: BackupState.realtimeTemp,
          flushStatus: FlushStatus.inProgress,
          detectedGaps: [gap],
          gapPeriods: [gap],
          tempDbPath: '${macDirectory.path}\\temp_db',
        ),
      );

      final service = RecoveryService();
      await service.init(rootPath: root.path, safeMac: safeMac);

      expect(service.metadata.flushStatus, FlushStatus.pending);
      expect(service.metadata.backupState, BackupState.realtimeTemp);
      expect(service.metadata.detectedGaps, hasLength(1));
      expect(service.metadata.detectedGaps.single.dbFile, 'trend.db');
    },
  );
}
