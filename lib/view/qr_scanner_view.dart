import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';
import 'package:reiri_app_core/reiri_app_core.dart';
import 'package:reiri_db_backup_tool/lib/app_constant.dart';
import 'dart:convert';

// this is used for QR cord reading on Android and iOS
// Show QR code scan screen and get controller info from QR code
/// Scans controller QR codes using the device camera.
class QrScannerView extends ConsumerWidget {
  QrScannerView();

  final GlobalKey qrKey = GlobalKey(debugLabel: 'QR');
  QRViewController? _qrController;

  bool _scanned = false; // prevent multiple scans

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      width: 300,
      height: 300,
      child: QRView(
        key: qrKey,
        onQRViewCreated: (QRViewController controller) {
          _qrController = controller;

          controller.scannedDataStream.listen((scanData) {
            if (_scanned) return; // prevent duplicate scans
            if (scanData.code == null) return;

            _scanned = true;

            try {
              final cdata = jsonDecode(
                utf8.decode(base64.decoder.convert(scanData.code!)),
              );
              final list = <String, Map<String, dynamic>>{};
              if (SUPPORT_MODELS.contains(cdata['model'])) {
                final info = {
                  'model': cdata['model'],
                  'version': cdata['version'],
                  'macaddr': cdata['mac_addr'],
                  'name': cdata['name'],
                  'ipaddr': cdata['ip_addr'],
                  'cloud': cdata['ssc_connect'],
                  'url': cdata['ssc_url'],
                };

                final mac = info['macaddr'];

                if (mac != null) {
                  print('selectedController: $mac');

                  list[mac] = info;

                  print('_controllerProvider: $list');

                  _qrController?.stopCamera();
                }
              }
              if (context.mounted) {
                Navigator.pop(context, list);
              }
            } catch (e) {
              debugPrint('QR decode error: $e');
              _scanned = false;
            }
          });
        },
        onPermissionSet: (ctrl, p) => _onPermissionSet(context, ctrl, p),
      ),
    );
  }

  void _onPermissionSet(BuildContext context, QRViewController ctrl, bool p) {
    if (!p) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(app.word('no_camera_permission'))));
    }
  }
}
