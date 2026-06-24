import 'package:reiri_app_core/reiri_app_core.dart';

/// [DbAccess] subclass that adds response parsing for the `*_db_backup`
/// controller commands used by the gap-fill recovery flow.
///
/// The base [DbAccess.receiveData] has no case for these commands, so the
/// controller response would fall through to the default handler which does
/// not extract the `data` field correctly.  Overriding here avoids any
/// changes to reiri_app_core.
class BackupDbAccess extends DbAccess {
  @override
  Map<String, dynamic> receiveData(List<dynamic> pack) {
    final cmd = pack[1][0] as String;
    if (cmd.endsWith('_db_backup')) {
      return {
        'result': 'OK',
        'data': pack[1][1]['data'],
      };
    }
    return super.receiveData(pack);
  }
}
