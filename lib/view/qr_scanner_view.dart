import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';
import 'package:reiri_db_backup_tool/lib/app_constant.dart';
import 'dart:convert';

// this is used for QR cord reading on Android and iOS
// Show QR code scan screen and get controller info from QR code
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
      ).showSnackBar(const SnackBar(content: Text('No camera permission')));
    }
  }
}

// class QrScanner extends ReiriScreen {
// 	// _list is controller list to show in ControllerRegisterPage
// 	// scaned controller information is set to _list
//   QrScanner(this._controllerProvider, {this.selectedController});
//   final StateProvider<Map<String,Map<String,dynamic>>> _controllerProvider;
//   final GlobalKey qrKey = GlobalKey(debugLabel: 'QR');
//   final _notifier = QrNotifier();
//   final _provider = StateNotifierProvider.family.autoDispose<QrNotifier,QRViewController?,QrNotifier>((_,notifier) => notifier);

//   final StateProvider<String>? selectedController;

//   @override
//   Widget build(BuildContext context, WidgetRef ref) {
//     final controller = ref.watch(_provider(_notifier));

//     if(controller != null) controller..resumeCamera()..scannedDataStream.listen((scanData) {
//     	// QR code is scaned
//       final cdata = jsonDecode(utf8.decode(base64.decoder.convert(scanData.code!)));
//       if(ReiriAppInfo.isTarget(cdata['model'])) {
//       	// if scan data is target controller's
//         // convert format
//         final Map<String,Map<String,dynamic>> list = {};
//         Map<String,dynamic> info = {};
//         info['model'] = cdata['model'];
//         info['version'] = cdata['version'];
//         info['macaddr'] = cdata['mac_addr'];
//         info['name'] = cdata['name'];
//         info['ipaddr'] = cdata['ip_addr'];
//         info['cloud'] = cdata['ssc_connect'];
//         info['url'] = cdata['ssc_url'];
//         if(info['macaddr'] != null) {

//           if (selectedController != null) ref.read(selectedController!.notifier).state = info['macaddr'];

//         	list[info['macaddr']] = info;
//         	// update controller list
//         	ref.read(_controllerProvider.notifier).state = list;
//         	// close QR code scanner
// 		      _notifier.get!.stopCamera();
// 		      _notifier.get!.dispose();
// 		      // back to ControllerRegisterPage
// 		      Navigator.pop(context);
//         }
//       }
//     });

//     return Container(
//       width: 300,
//       height: 300,
//       child: QRView(
//         key: qrKey,
//         onQRViewCreated: (ctrl) {_notifier.set(ctrl);},
//         onPermissionSet: (ctrl,p) => _onPermissionSet(context, ctrl, p),
//       ),
//     );
//   }

//   void _onPermissionSet(BuildContext context, QRViewController ctrl, bool p) {
//     if (!p) {
//       ScaffoldMessenger.of(context).showSnackBar(
//         const SnackBar(content: Text('no Permission')),
//       );
//     }
//   }
// }

// class QrNotifier extends StateNotifier<QRViewController?> {
//   QrNotifier() : super(null);
//   void set(QRViewController controller) {state = controller;}
//   QRViewController? get get => state;
// }
