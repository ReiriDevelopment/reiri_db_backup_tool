// File purpose: Hosts the controller QR-code registration web flow.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reiri_app_core/reiri_app_core.dart';
import 'package:webview_windows/webview_windows.dart';
import 'dart:async';
import 'dart:io';

// Windows WebView that saves scanned controller data as a .qrc download.

/// Opens the controller QR workflow in an embedded web view.
class QrWebView extends ConsumerStatefulWidget {
  final bool isGallery;

  const QrWebView({super.key, this.isGallery = false});

  @override
  ConsumerState<QrWebView> createState() => _QrWebViewState();
}

/// Manages web-view navigation and extracted controller QR data.
class _QrWebViewState extends ConsumerState<QrWebView> {
  final WebviewController _controller = WebviewController();

  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    initView();
  }

  /// Initializes the Windows web view, tracks QR completion, and loads the
  /// camera or gallery activation page selected by the widget.
  Future<void> initView() async {
    if (!Platform.isWindows) return;

    await _controller.initialize();

    _controller.url.listen((url) {
      // mark ready when URL changes (QR detected flow)
      // ref.read(urlProvider.notifier).setReady();
      ref.read(boolDataProvider('qr_ready').notifier).set(true);
    });

    String url = 'https://ssc-activation.daikin.com.sg/QRscan/';

    if (widget.isGallery) {
      url += 'qr_image.html';
    }

    await _controller.loadUrl(url);

    if (!mounted) return;
    setState(() {
      _initialized = true;
    });
  }

  Widget qrWebView() {
    if (!_initialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return Webview(
      _controller,
      permissionRequested: (a, b, c) => WebviewPermissionDecision.allow,
    );
  }

  void close() {
    _controller.stop();
    _controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = ref.watch(boolDataProvider('qr_ready')) ?? false;

    return Column(
      children: [
        Container(
          margin: const EdgeInsets.all(10),
          child: Text(app.word('qr_scan_msg'), textAlign: TextAlign.center),
        ),
        SizedBox(height: 320, child: Center(child: qrWebView())),
        Container(
          width: 320,
          margin: const EdgeInsets.all(10),
          child: Text(
            ready
                ? app.word(widget.isGallery ? 'qr_scaned_gallery' : 'qr_scaned')
                : '',
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
