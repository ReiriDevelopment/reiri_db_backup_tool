import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reiri_db_backup_tool/service/backup_metadata_service.dart';

void main() {
  late Directory tempDir;
  late BackupMetadataService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('reiri_metadata_test_');
    service = BackupMetadataService();
    await service.init(tempDir.path);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test(
    'delayed disconnect preserves the last healthy time across sleep',
    () async {
      final lastHealthy = DateTime(2026, 7, 7, 18, 59);
      await service.recordHeartbeat(at: lastHealthy);
      await service.recordDisconnect(at: DateTime(2026, 7, 8, 9, 13));

      expect(service.current.disconnectedAt, lastHealthy);

      final gaps = await service.recordConnect(DateTime(2026, 7, 8, 9, 14));
      expect(gaps, hasLength(5));
      expect(gaps.every((gap) => gap.start == lastHealthy), isTrue);
      expect(service.current.disconnectedAt, isNull);
    },
  );

  test('logout and dispose cannot move an outage start forward', () async {
    final lastHealthy = DateTime(2026, 7, 10, 14, 14, 59);
    await service.recordHeartbeat(at: lastHealthy);
    await service.recordDisconnect(at: DateTime(2026, 7, 10, 14, 26));
    await service.recordDisconnect(at: DateTime(2026, 7, 10, 15, 40, 32));
    await service.recordDisconnect(at: DateTime(2026, 7, 10, 15, 40, 33));

    expect(service.current.disconnectedAt, lastHealthy);

    final gaps = await service.recordConnect(DateTime(2026, 7, 10, 15, 49));
    expect(gaps, hasLength(5));
    expect(gaps.every((gap) => gap.start == lastHealthy), isTrue);
  });

  test(
    'crash recovery falls back to the persisted healthy heartbeat',
    () async {
      final lastHealthy = DateTime(2026, 7, 8, 12, 59);
      await service.recordHeartbeat(at: lastHealthy);

      // Simulate a force-kill: no disconnect callback runs before the next
      // process records its connection.
      final gaps = await service.recordConnect(DateTime(2026, 7, 10, 10));

      expect(gaps, hasLength(5));
      expect(gaps.every((gap) => gap.start == lastHealthy), isTrue);
    },
  );

  test(
    'short disconnect inside controller delivery grace is recovered',
    () async {
      final lastHealthy = DateTime(2026, 7, 7, 13, 45, 30);
      await service.recordHeartbeat(at: lastHealthy);
      await service.recordDisconnect(at: DateTime(2026, 7, 7, 13, 45, 35));

      final gaps = await service.recordConnect(
        DateTime(2026, 7, 7, 13, 45, 46),
      );

      expect(
        gaps.map((gap) => gap.dbFile),
        containsAll(<String>[
          'meter.db',
          'optime.db',
          'ppd.db',
          'trend.db',
          'history.db',
        ]),
      );
    },
  );

  test('history is recovered for a non-boundary disconnect', () async {
    await service.recordHeartbeat(at: DateTime(2026, 7, 7, 13, 32, 10));
    await service.recordDisconnect(at: DateTime(2026, 7, 7, 13, 32, 12));

    final gaps = await service.recordConnect(DateTime(2026, 7, 7, 13, 32, 20));

    expect(gaps.map((gap) => gap.dbFile), ['history.db']);
  });
}
