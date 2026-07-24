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
const String kRecoveryTimeKey = 'RECOVERY_SCHEDULE_TIME_V1';
const String kInstantFillKey = 'RECOVERY_MODE_INSTANT_V1';

/// Default recovery flush time: 03:00.
const ({int hour, int minute}) kDefaultRecoveryTime = (hour: 3, minute: 0);

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

Future<void> storeRecoveryTime(int hour, int minute) async {
  await app.storeJson(kRecoveryTimeKey, {'hour': hour, 'minute': minute});
}

Future<({int hour, int minute})> loadRecoveryTime() async {
  try {
    final info = await app.loadJson(kRecoveryTimeKey);
    return (
      hour:   (info['hour']   as num?)?.toInt() ?? kDefaultRecoveryTime.hour,
      minute: (info['minute'] as num?)?.toInt() ?? kDefaultRecoveryTime.minute,
    );
  } catch (_) {
    return kDefaultRecoveryTime;
  }
}

Future<void> storeInstantFill(bool value) async {
  await app.storeJson(kInstantFillKey, {'instant': value});
}

Future<bool> loadInstantFill() async {
  try {
    final info = await app.loadJson(kInstantFillKey);
    return info['instant'] as bool? ?? false;
  } catch (_) {
    return false;
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

