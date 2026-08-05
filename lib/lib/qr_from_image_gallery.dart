/*==============================================================================
  Created: 21/08/2024, Jared Ong
  Purpose:
    -Gets controller QR data from image gallery
    -Mobile only. Desktop use qr_image_gallery_desktop.dart
==============================================================================*/

import 'dart:convert';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:reiri_db_backup_tool/lib/app_constant.dart';
import 'package:scan/scan.dart';

/// Reads and decodes a QR code from an image selected from the gallery.
class QrFromImageGallery {
  static final QrFromImageGallery _instance = QrFromImageGallery._internal();
  factory QrFromImageGallery() => _instance;
  QrFromImageGallery._internal() {}

  File? _image;
  final picker = ImagePicker();

  static Future<Map<String, dynamic>> getImageFromGallery() async {
    final pickedFile = await _instance.picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
    );
    if (pickedFile == null) return {};

    _instance._image = File(pickedFile.path);
    final res = await Scan.parse(_instance._image!.path);
    //print('RES: $res'); //Encryption

    if (res == null) return {};

    try {
      final cdata = jsonDecode(utf8.decode(base64.decoder.convert(res!)));
      // if scan data is target controller's
      // convert format
      final Map<String, Map<String, dynamic>> list = {};
      Map<String, dynamic> info = {};
      info['model'] = cdata['model'];
      info['version'] = cdata['version'];
      info['macaddr'] = cdata['mac_addr'];
      info['name'] = cdata['name'];
      info['ipaddr'] = cdata['ip_addr'];
      info['cloud'] = cdata['ssc_connect'];
      info['url'] = cdata['ssc_url'];

      //If supportedModels is empty means it supports all models
      if (SUPPORT_MODELS.isNotEmpty) {
        if (!SUPPORT_MODELS.contains(info['model'])) return {};
      }

      if (info['macaddr'] != null) {
        list[info['macaddr']] = info;
        return info;
      }
    } catch (e, st) {
      print('Error with QR Image Gallery: $e');
      return {};
    }

    //print('info: $info');
    return {};
  }
}
