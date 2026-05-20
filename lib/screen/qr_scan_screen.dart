import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reiri_app_core/app_interface.dart';
import 'package:reiri_db_backup_tool/lib/qr_from_image_gallery.dart';
import 'package:reiri_db_backup_tool/view/qr_scanner_view.dart';
import 'package:reiri_db_backup_tool/view/qr_web_view.dart';
import 'package:reiri_db_backup_tool/lib/qrc_file_reader.dart';
import 'package:std_widget/std_widget.dart';
import 'dart:io';

class QrScanScreen extends ConsumerWidget {
  QrScanScreen({this.fromGallery = false}) {}
  int tabIndex = 0;
  bool? fromGallery;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    app.refresh(ref, 'qr_scan_screen');
    Widget bodyView = Container();
    if (tabIndex == 0) {
      // Android and iOS can scan QR code directly.
      // Windows use WebView to scan QR code and save it to file then read the file.
      if (Platform.isWindows) {
        bodyView = QrWebView();
      } else {
        bodyView = QrScannerView(); // for iOS and Android
      }
    } else {
      if (Platform.isWindows) {
        bodyView = QrWebView(key: ValueKey('gallery'), isGallery: true);
      } else {
        bodyView = TextButton(
          onPressed: () async {
            Map<String, dynamic> selected =
                await QrFromImageGallery.getImageFromGallery();
            if (selected.isNotEmpty && selected['macaddr'] != null) {
              // ref.read(rsys.getProvider('ctrl_sel').notifier).state = selected['macaddr'];
              Map<String, Map<String, dynamic>> searchedcontrollers = {};
              searchedcontrollers[selected['macaddr']] = {
                'model': selected['model'],
                'version': selected['version'],
                'macaddr': selected['macaddr'],
                'name': selected['name'],
                'ipaddr': selected['ipaddr'],
                'cloud': selected['cloud'],
                'url': selected['url'],
              };

              print('search result: $searchedcontrollers');
              Navigator.pop(context, searchedcontrollers);
            }
          },
          child: Text(app.word('upload_image')),
        );
      }
    }

    final backButton = IconButton(
      icon: const Icon(Icons.arrow_back_ios_rounded),
      onPressed: () async {
        Map<String, Map<String, dynamic>>? readList;
        if (Platform.isWindows) {
          // close web view
          // read *.qrc file to get controller information
          readList = await QrcFileReader().getList();
          // _provider = readList;
          print('QR code data: $readList');
        }
        Navigator.pop(context, readList);
      },
    );

    return MediaQuery.withNoTextScaling(
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: app.color.background,
          elevation: 0,
          leading: backButton,
        ),
        body: SafeArea(
          child: Center(
            child: Column(
              children: [
                TabSelection(
                  tabIndex: tabIndex,
                  tabs: [
                    Text(app.word('scan'), style: TextStyle(fontSize: 18)),
                    Text(
                      app.word('upload_image'),
                      style: TextStyle(fontSize: 18),
                    ),
                  ],
                  onChanged: (value) {
                    tabIndex = value;
                    app.requestRefresh('qr_scan_screen');
                  },
                ),
                bodyView,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
