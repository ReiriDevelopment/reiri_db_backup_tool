import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart';
import 'package:reiri_db_backup_tool/lib/app_constant.dart';
import 'dart:io';
import 'dart:convert';

// Read *.qrc file in downloads folder to get controller information
// this is used only for Windows version
/// Parses controller connection details from a Reiri `.qrc` file.
class QrcFileReader {
  Future<Map<String, Map<String, dynamic>>> getList() async {
    // get downloads folder path
    final dir = await getDownloadsDirectory();
    Map<String, Map<String, dynamic>> controllerList = {};

    if (dir != null) {
      dir.listSync().forEach((file) {
        // find *.qrc file in downloads folder
        if (extension(file.path) == '.qrc') {
          final coded = File(file.path).readAsStringSync();
          final cdata = jsonDecode(utf8.decode(base64.decoder.convert(coded)));
          if (SUPPORT_MODELS.contains(cdata['model'])) {
            // convert format
            Map<String, dynamic> info = {};
            info['model'] = cdata['model'];
            info['version'] = cdata['version'];
            info['macaddr'] = cdata['mac_addr'];
            info['name'] = cdata['name'];
            info['ipaddr'] = cdata['ip_addr'];
            info['cloud'] = cdata['ssc_connect'];
            info['url'] = cdata['ssc_url'];
            if (info['macaddr'] != null) controllerList[info['macaddr']] = info;
          }
        }
      });
    }
    return controllerList;
  }
}
