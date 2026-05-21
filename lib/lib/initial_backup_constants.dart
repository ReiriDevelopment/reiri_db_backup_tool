import 'package:reiri_app_core/reiri_app_core.dart';

const List<String> kInitialBackupDbFiles = [
  'history.db',
  'meter.db',
  'optime.db',
  'trend.db',
  'ppd.db',
];

const String kInitialBackupDbFolderName = 'DB';
const String kTempDbFolderName = 'DB_TEMP';

const String kInitialBackupDoneKey = 'INITIAL_HISTORY_BACKUP_DONE_V1';
const String kBackupRootPathKey = 'BACKUP_ROOT_PATH_V1';

/// Convert MAC address into a Windows-safe folder name.
/// Example: `02:81:0c:0c:f4:2f` -> `02_81_0c_0c_f4_2f`
String macToSafeFolderName(String mac) {
  return mac.replaceAll(':', '_');
}

Future<void> storeBackupRootPath(String macaddr, String path) async {
  await app.storeJson(kBackupRootPathKey, {'path': path}, macaddr: macaddr);
}

Future<String?> loadBackupRootPath(String macaddr) async {
  try {
    final info = await app.loadJson(kBackupRootPathKey, macaddr: macaddr);
    return info['path']?.toString();
  } catch (_) {
    return null;
  }
}

Future<void> markInitialBackupDone(String macaddr, String method) async {
  await app.storeJson(
    kInitialBackupDoneKey,
    {
      'done': true,
      'method': method,
      'updatedAt': DateTime.now().toIso8601String(),
    },
    macaddr: macaddr,
  );
}

