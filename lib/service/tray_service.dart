import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';

/// Manages the system tray icon, tooltip, and context menu.
///
/// Call [init] once after [windowManager] is ready.
/// Call [updateStatus] whenever connection or backup health changes.
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

  /// Updates the tray tooltip to reflect the current connection/backup state.
  ///
  /// Three icon states are spec'd (colours TBC).  For now all states share the
  /// same icon; the tooltip distinguishes them.  To add coloured icons later,
  /// replace the setIcon call with the appropriate asset path.
  Future<void> updateStatus({
    required bool isConnected,
    required bool backupHealthy,
  }) async {
    if (!_initialized) return;

    final String tooltip;
    if (!isConnected) {
      tooltip = 'Reiri Backup — Disconnected';
      // TODO: swap icon to disconnected variant when colour assets are ready
      // await trayManager.setIcon('assets/images/tray_icon_disconnected.ico');
    } else if (!backupHealthy) {
      tooltip = 'Reiri Backup — Warning: no recent backup';
      // TODO: swap icon to warning variant
      // await trayManager.setIcon('assets/images/tray_icon_warning.ico');
    } else {
      tooltip = 'Reiri Backup — Connected';
      // await trayManager.setIcon('assets/images/tray_icon.ico');
    }

    await trayManager.setToolTip(tooltip);
  }

  Future<void> _rebuildContextMenu() async {
    final menu = Menu(
      items: [
        MenuItem(key: 'open', label: 'Open app'),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: 'Exit'),
      ],
    );
    await trayManager.setContextMenu(menu);
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
