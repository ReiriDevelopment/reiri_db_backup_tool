import 'package:flutter_test/flutter_test.dart';
import 'package:reiri_db_backup_tool/lib/db_latest_probe.dart';
import 'package:reiri_db_backup_tool/model/backup_metadata.dart';

void main() {
  test('FTP always recovers the latest trend boundary', () {
    final completedAt = DateTime(2026, 8, 3, 14, 5, 16);

    final gaps = addFtpTrendOverlap(const [], completedAt: completedAt);

    expect(gaps, hasLength(1));
    expect(gaps.single.dbFile, 'trend.db');
    expect(gaps.single.start, DateTime(2026, 8, 3, 14, 5));
    expect(gaps.single.end, completedAt);
  });

  test('FTP overlap extends an existing trend gap without duplicating it', () {
    final completedAt = DateTime(2026, 8, 3, 14, 5, 16);
    final existing = GapRange(
      dbFile: 'trend.db',
      start: DateTime(2026, 8, 3, 13, 55),
      end: DateTime(2026, 8, 3, 14, 5, 10),
    );

    final gaps = addFtpTrendOverlap([existing], completedAt: completedAt);

    expect(gaps, hasLength(1));
    expect(gaps.single.start, existing.start);
    expect(gaps.single.end, completedAt);
  });
}
