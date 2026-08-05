import 'package:reiri_app_core/reiri_app_core.dart';

/// Parses `*_db_backup` responses not handled by the core [DbAccess].
class BackupDbAccess extends DbAccess {
  @override
  Map<String, dynamic> receiveData(List<dynamic> pack) {
    final cmd = pack[1][0] as String;
    if (cmd.endsWith('_db_backup')) {
      return {'result': 'OK', 'data': pack[1][1]['data']};
    }
    return super.receiveData(pack);
  }
}
