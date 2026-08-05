import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:reiri_app_core/reiri_app_core.dart';
import 'package:tray_manager/tray_manager.dart';

/// Manages the tray icon, tooltip, and menu after window initialization.
class TrayService with TrayListener {
  TrayService._();
  static final TrayService instance = TrayService._();

  bool _initialized = false;

  /// Called when the user wants to restore the app window (left-click or "Open app").
  VoidCallback? onOpenApp;

  /// Called when the user chooses Exit from the tray context menu.
  VoidCallback? onExit;

  Future<void> init({
    required VoidCallback onOpenApp,
    required VoidCallback onExit,
  }) async {
    this.onOpenApp = onOpenApp;
    this.onExit = onExit;

    if (_initialized) return;
    _initialized = true;

    trayManager.addListener(this);

    await trayManager.setIcon(
      Platform.isWindows
          ? 'assets/images/tray_icon.ico'
          : 'assets/images/tray_icon.ico',
    );
    await trayManager.setToolTip('Reiri Backup');
    await _rebuildContextMenu();
  }

  /// Updates the tooltip; status-specific icons are not available yet.
  Future<void> updateStatus({
    required bool isConnected,
    required bool backupHealthy,
  }) async {
    if (!_initialized) return;

    await _rebuildContextMenu();

    final String tooltip;
    if (!isConnected) {
      tooltip = 'Reiri Backup — ${_word('disconnected', 'Disconnected')}';
      // TODO: swap icon to disconnected variant when colour assets are ready
      // await trayManager.setIcon('assets/images/tray_icon_disconnected.ico');
    } else if (!backupHealthy) {
      tooltip =
          'Reiri Backup — ${_word('tray_warning_no_recent_backup', 'Warning: no recent backup')}';
      // TODO: swap icon to warning variant
      // await trayManager.setIcon('assets/images/tray_icon_warning.ico');
    } else {
      tooltip = 'Reiri Backup — ${_word('connected', 'Connected')}';
      // await trayManager.setIcon('assets/images/tray_icon.ico');
    }

    await trayManager.setToolTip(tooltip);
  }

  Future<void> _rebuildContextMenu() async {
    final menu = Menu(
      items: [
        MenuItem(key: 'open', label: _word('open_app', 'Open app')),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: _word('exit', 'Exit')),
      ],
    );
    await trayManager.setContextMenu(menu);
  }

  String _word(String key, String fallback) {
    try {
      final value = app.word(key);
      return value == key ? fallback : value;
    } catch (_) {
      // Tray initialization runs before the app string table has loaded.
      return fallback;
    }
  }

  void dispose() {
    if (_initialized) {
      trayManager.removeListener(this);
      trayManager.destroy();
      _initialized = false;
    }
  }

  // ── TrayListener ─────────────────────────────────────────────────────────

  @override
  void onTrayIconMouseDown() {
    onOpenApp?.call();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        onOpenApp?.call();
      case 'exit':
        onExit?.call();
    }
  }
}
