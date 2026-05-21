import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reiri_app_core/reiri_app_core.dart';
import 'package:reiri_db_backup_tool/lib/initial_backup_constants.dart';
import 'package:reiri_db_backup_tool/model/backup_metadata.dart';
import 'package:reiri_db_backup_tool/provider/backup_log_provider.dart';
import 'package:reiri_db_backup_tool/service/backup_metadata_service.dart';
import 'package:reiri_db_backup_tool/view/initial_backup_ftp_view.dart';
import 'package:reiri_db_backup_tool/view/initial_backup_local_import_view.dart';
import 'home_screen.dart';
import 'login_screen.dart';
import 'reiri_screen.dart';

class InitialBackupScreen extends ReiriScreen {
  InitialBackupScreen({this.initialMac});

  final String? initialMac;

  String selectedMethod = 'ftp';
  bool showingView = false;

  static Future<bool> needsInitialBackup(String? macaddr) async {
    if (macaddr == null || macaddr.isEmpty) return true;

    // Check done flag.
    try {
      final info = await app.loadJson(kInitialBackupDoneKey, macaddr: macaddr);
      if (info['done'] != true) return true;
    } catch (_) {
      return true;
    }

    // Verify the required DB files still exist and are non-empty.
    try {
      final rootPath = await loadBackupRootPath(macaddr);
      if (rootPath == null) return true;
      final safeMac = macToSafeFolderName(macaddr);
      final dbDir = '$rootPath\\$safeMac\\$kInitialBackupDbFolderName';
      for (final filename in kInitialBackupDbFiles) {
        final file = File('$dbDir\\$filename');
        if (!await file.exists() || await file.length() == 0) return true;
      }
    } catch (_) {
      return true;
    }

    return false;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    app.refresh(ref, 'initial_backup_screen');

    final macaddr =
        initialMac ?? app.selectedController?['macaddr']?.toString();
    final safeMac =
        (macaddr == null || macaddr.isEmpty) ? '' : macToSafeFolderName(macaddr);
    final controllerIp = app.controllerInfo('ipaddr')?.toString() ?? '';

    return Scaffold(
      appBar: appBar(context, leading: const SizedBox.shrink()),
      body: showingView
          ? _buildViewPhase(
              context,
              macaddr: macaddr,
              safeMac: safeMac,
              controllerIp: controllerIp,
            )
          : _buildSelectionPhase(
              context,
              macaddr: macaddr,
              safeMac: safeMac,
              controllerIp: controllerIp,
            ),
    );
  }

  Widget _buildSelectionPhase(
    BuildContext context, {
    required String? macaddr,
    required String safeMac,
    required String controllerIp,
  }) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(context, macaddr),
              const SizedBox(height: 28),
              _buildMethodCard(
                methodValue: 'ftp',
                icon: Icons.cloud_download_outlined,
                title: 'Load via FTP',
                description:
                    'Download the historical DB from the controller over FTP.',
                onTap: () {
                  selectedMethod = 'ftp';
                  app.requestRefresh('initial_backup_screen');
                },
              ),
              _buildMethodCard(
                methodValue: 'local',
                icon: Icons.sd_storage_outlined,
                title: 'Import Local DB Files',
                description:
                    'Select existing local SQLite DB files and import them.',
                onTap: () {
                  selectedMethod = 'local';
                  app.requestRefresh('initial_backup_screen');
                },
              ),
              const SizedBox(height: 24),
              if (macaddr == null || macaddr.isEmpty)
                _buildMissingMacError()
              else
                FilledButton.icon(
                  onPressed: () {
                    showingView = true;
                    app.requestRefresh('initial_backup_screen');
                  },
                  icon: const Icon(Icons.arrow_forward_rounded),
                  label: const Text('Continue'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    textStyle: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: () {
                  app.logout();
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(builder: (_) => LoginScreen()),
                    (route) => false,
                  );
                },
                icon: Icon(Icons.logout_rounded,
                    size: 16, color: app.color.inactive),
                label: Text('Logout',
                    style: TextStyle(color: app.color.inactive)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildViewPhase(
    BuildContext context, {
    required String? macaddr,
    required String safeMac,
    required String controllerIp,
  }) {
    Future<void> onCompleted(
      String method,
      String backupPath, {
      List<GapRange> initialGaps = const [],
    }) async {
      try {
        await markInitialBackupDone(macaddr!, method);
        await storeBackupRootPath(macaddr, backupPath);
      } catch (_) {}
      // Stamp the FTP/import completion time as "disconnected at" so that gap
      // detection in HomeScreen._init() can catch any controller writes that
      // occur between the snapshot and real-time backup starting.
      //
      // When the import view detected per-file missing data (interval
      // boundaries crossed since the imported snapshot's latest record), seed
      // those ranges into backup_metadata.detectedGaps so RecoveryService
      // routes real-time → TEMP DB on first connect and schedules gap-fill.
      try {
        final safeMac = macToSafeFolderName(macaddr!);
        final metaService = BackupMetadataService();
        await metaService.init('$backupPath\\$safeMac');
        await metaService.recordDisconnect();
        if (initialGaps.isNotEmpty) {
          final seeded = metaService.current.copyWith(
            detectedGaps: initialGaps,
            backupState: BackupState.realtimeTemp,
            flushStatus: FlushStatus.pending,
          );
          await metaService.save(seeded);
        }
      } catch (_) {}
      await BackupLogNotifier.clearEntries(macaddr!);
      if (!context.mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => HomeScreen()),
        (route) => false,
      );
    }

    final isFtp = selectedMethod == 'ftp';

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton.icon(
                onPressed: () {
                  showingView = false;
                  app.requestRefresh('initial_backup_screen');
                },
                icon: const Icon(Icons.arrow_back_rounded, size: 16),
                label: const Text('Back'),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  foregroundColor: app.color.inactive,
                  textStyle: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(height: 16),
              _buildViewHeader(context, isFtp: isFtp, controllerIp: controllerIp),
              const SizedBox(height: 24),
              if (isFtp)
                InitialBackupFtpView(
                  controllerIp: controllerIp,
                  macaddr: safeMac,
                  onCompleted: onCompleted,
                )
              else
                InitialBackupLocalImportView(
                  controllerMac: safeMac,
                  onCompleted: onCompleted,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildViewHeader(
    BuildContext context, {
    required bool isFtp,
    required String controllerIp,
  }) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: app.color.active.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(
            isFtp ? Icons.cloud_download_outlined : Icons.sd_storage_outlined,
            size: 24,
            color: app.color.active,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isFtp ? 'Load via FTP' : 'Import Local DB Files',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              Text(
                isFtp
                    ? 'Download DB files from the controller at $controllerIp'
                    : 'Select the controller\'s "DB" folder containing the SQLite DB files to import.',
                style: TextStyle(fontSize: 12, color: app.color.inactive),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context, String? macaddr) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: app.color.active.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.backup_rounded,
                  size: 28, color: app.color.active),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                'Initial Backup',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'Choose how to import the controller database before enabling continuous backup.',
          style: TextStyle(fontSize: 13, color: app.color.inactive),
        ),
        if (macaddr != null && macaddr.isNotEmpty) ...[
          const SizedBox(height: 10),
          _buildMacChip(macaddr),
        ],
      ],
    );
  }

  Widget _buildMacChip(String macaddr) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: app.color.inactive.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.router_outlined, size: 13, color: app.color.inactive),
          const SizedBox(width: 5),
          Text(
            macaddr,
            style: TextStyle(
              fontSize: 12,
              color: app.color.inactive,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMethodCard({
    required String methodValue,
    required IconData icon,
    required String title,
    required String description,
    required VoidCallback onTap,
  }) {
    final selected = selectedMethod == methodValue;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          border: Border.all(
            color: selected ? app.color.active : Colors.grey.shade600,
            width: selected ? 2 : 1,
          ),
          color: selected ? app.color.active.withValues(alpha: 0.06) : null,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Radio<String>(
              value: methodValue,
              groupValue: selectedMethod,
              onChanged: (_) => onTap(),
              activeColor: app.color.active,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            const SizedBox(width: 8),
            Icon(
              icon,
              size: 26,
              color: selected ? app.color.active : app.color.inactive,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? app.color.foreground
                          : app.color.inactive,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    description,
                    style:
                        TextStyle(fontSize: 12, color: app.color.inactive),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMissingMacError() {
    return Column(
      children: [
        Icon(Icons.error_outline_rounded, size: 40, color: app.color.alert),
        const SizedBox(height: 10),
        Text(
          'Controller ID is missing. Please log in again.',
          style: TextStyle(color: app.color.alert, fontSize: 13),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
