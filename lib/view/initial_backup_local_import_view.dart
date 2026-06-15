import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'package:reiri_app_core/reiri_app_core.dart';
import 'package:reiri_db_backup_tool/lib/db_latest_probe.dart';
import 'package:reiri_db_backup_tool/lib/initial_backup_constants.dart';
import 'package:reiri_db_backup_tool/model/backup_metadata.dart';

class InitialBackupLocalImportView extends StatefulWidget {
  const InitialBackupLocalImportView({
    super.key,
    required this.controllerMac,
    required this.onCompleted,
  });

  final String controllerMac;
  final Future<void> Function(
    String methodValue,
    String backupPath, {
    List<GapRange> initialGaps,
  })
  onCompleted;

  @override
  State<InitialBackupLocalImportView> createState() =>
      _InitialBackupLocalImportViewState();
}

class _InitialBackupLocalImportViewState
    extends State<InitialBackupLocalImportView> {
  String? _sourcePath;
  String? _backupPath;

  bool _isImporting = false;
  bool _isScanning = false;
  bool _scanDone = false;

  /// Per-file probe result: existence + latest record + missing-data flag.
  /// Used both for the UI (file present?) and to silently seed
  /// `backup_metadata.detectedGaps` so the gap-fill flow kicks in on connect.
  final Map<String, DbProbeResult> _scanResult = {};

  double _progress01 = 0;

  bool get _canImport {
    if (_isImporting || _isScanning) return false;
    if (_sourcePath == null || _sourcePath!.isEmpty) return false;
    if (_backupPath == null || _backupPath!.isEmpty) return false;
    if (!_scanDone) return false;
    return _scanResult.isNotEmpty && _scanResult.values.every((r) => r.exists);
  }

  String get _localDbRootPath => Directory.current.path;

  Future<void> _pickSourcePath() async {
    final path = await getDirectoryPath();
    if (path == null || path.isEmpty) return;
    setState(() {
      _sourcePath = path;
      _scanDone = false;
      _scanResult.clear();
      _progress01 = 0;
    });
    await _scanFolder();
  }

  Future<void> _pickBackupPath() async {
    final path = await getDirectoryPath();
    if (path == null || path.isEmpty) return;
    setState(() {
      _backupPath = path;
      _progress01 = 0;
    });
  }

  Future<void> _scanFolder() async {
    final src = _sourcePath;
    if (src == null || src.isEmpty) return;

    setState(() {
      _isScanning = true;
      _scanDone = false;
    });

    final probe = await probeSourceFolder(
      sourceFolder: src,
      dbFiles: kInitialBackupDbFiles,
      now: DateTime.now(),
    );

    if (!mounted) return;
    setState(() {
      _scanResult
        ..clear()
        ..addAll(probe);
      _scanDone = true;
      _isScanning = false;
    });
  }

  void _clearLocalDirectory(Directory dir) {
    if (!dir.existsSync()) return;
    for (final entry in dir.listSync()) {
      try {
        if (entry is File) {
          entry.deleteSync();
        } else if (entry is Directory) {
          entry.deleteSync(recursive: true);
        }
      } catch (_) {}
    }
  }

  Future<void> _copyDbFiles({
    required String sourceDbDir,
    required String destDbDir,
    bool clearDest = false,
  }) async {
    final dest = Directory(destDbDir);
    dest.createSync(recursive: true);

    // Only clear destination when it's the user-selected staging directory.
    if (clearDest) {
      _clearLocalDirectory(dest);
    }

    final total = kInitialBackupDbFiles.length;
    var done = 0;

    for (final fname in kInitialBackupDbFiles) {
      final srcFile = File('$sourceDbDir\\$fname');
      if (!srcFile.existsSync()) continue;

      final dstFile = File('$destDbDir\\$fname');
      await dstFile.create(recursive: true);
      await dstFile.writeAsBytes(await srcFile.readAsBytes());

      done++;
      if (!mounted) return;
      setState(() {
        _progress01 = done / total;
      });
    }
  }

  Future<void> _startImport() async {
    if (!_canImport) return;

    final srcRoot = _sourcePath!;
    final backupRoot = _backupPath!;
    // Sanitize MAC again inline to avoid any stale hot-reload/import caching issues.
    final safeMac = widget.controllerMac.replaceAll(':', '_');
    final controllerDir = Directory('$backupRoot\\$safeMac');
    final stagingDir = Directory('${controllerDir.path}\\DB');
    final localRoot = Directory(_localDbRootPath);

    setState(() {
      _isImporting = true;
      _progress01 = 0;
    });

    try {
      // 1) Copy source -> staging backup/DB
      stagingDir.createSync(recursive: true);
      await _copyDbFiles(
        sourceDbDir: srcRoot,
        destDbDir: stagingDir.path,
        clearDest: true,
      );

      // 2) Copy staging -> local app DB root (overwrite)
      await _copyDbFiles(
        sourceDbDir: stagingDir.path,
        destDbDir: localRoot.path,
        clearDest: false,
      );

      // 3) Re-probe the staged copy right before navigating so boundaries
      //    that crossed during the copy itself (e.g. user clicked Import at
      //    14:14:30 and the copy finished at 14:15:10) are captured too.
      final finalProbe = await probeSourceFolder(
        sourceFolder: stagingDir.path,
        dbFiles: kInitialBackupDbFiles,
        now: DateTime.now(),
      );
      final initialGaps = probeResultsToGaps(finalProbe, now: DateTime.now());

      await widget.onCompleted('local', _backupPath!, initialGaps: initialGaps);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Import failed: $e')));
    } finally {
      if (!mounted) return;
      setState(() {
        _isImporting = false;
      });
    }
  }

  Widget _buildScanRow(String fileName, DbProbeResult r) {
    final exists = r.exists;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        exists ? Icons.check_circle : Icons.cancel,
        color: exists ? Colors.green : Colors.red,
      ),
      title: Text(fileName, style: const TextStyle(fontSize: 13.5)),
      trailing: Text(
        exists ? 'OK' : 'Missing',
        style: TextStyle(
          fontSize: 12,
          color: exists ? app.color.inactive : app.color.alert,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Builder(
          builder: (context) {
            final cs = Theme.of(context).colorScheme;
            return Text(
              'history.db  •  meter.db  •  optime.db  •  trend.db  •  ppd.db',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: cs.onSurfaceVariant,
              ),
            );
          },
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.folder_open),
              label: const Text('Select Source Folder'),
              onPressed: _isImporting ? null : _pickSourcePath,
              style: const ButtonStyle(
                mouseCursor: WidgetStatePropertyAll(SystemMouseCursors.click),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (_sourcePath != null)
          Text(
            'Source: $_sourcePath',
            style: TextStyle(color: app.color.inactive, fontSize: 13),
          ),
        const SizedBox(height: 10),

        Row(
          children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.save_alt_outlined),
              label: const Text('Select Backup Path'),
              onPressed: _isImporting ? null : _pickBackupPath,
              style: const ButtonStyle(
                mouseCursor: WidgetStatePropertyAll(SystemMouseCursors.click),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (_backupPath != null)
          Text(
            'Backup root: $_backupPath\nController folder: ${macToSafeFolderName(widget.controllerMac)}',
            style: TextStyle(color: app.color.inactive, fontSize: 13),
          ),
        const SizedBox(height: 12),

        if (_isScanning)
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text(
                'Scanning DB files' + '...',
                style: TextStyle(color: app.color.inactive, fontSize: 12.5),
              ),
            ],
          ),

        if (_sourcePath != null && _scanDone) ...[
          const Text(
            'Scan Result',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 220,
            child: ListView(
              children: kInitialBackupDbFiles.map((fname) {
                final r = _scanResult[fname] ?? const DbProbeResult.missing();
                return _buildScanRow(fname, r);
              }).toList(),
            ),
          ),
        ],

        const SizedBox(height: 16),

        Align(
          alignment: Alignment.centerLeft,
          child: ElevatedButton.icon(
            onPressed: _canImport ? _startImport : null,
            icon: const Icon(Icons.file_upload_rounded),
            label: const Text('Import'),
            style: ElevatedButton.styleFrom().copyWith(
              mouseCursor: WidgetStateProperty.resolveWith(
                (s) => s.contains(WidgetState.disabled)
                    ? SystemMouseCursors.basic
                    : SystemMouseCursors.click,
              ),
            ),
          ),
        ),

        if (_isImporting) ...[
          const SizedBox(height: 16),
          LinearProgressIndicator(value: _progress01),
          const SizedBox(height: 8),
          Text(
            'Importing... (${(_progress01 * 100).toStringAsFixed(0)}%)',
            style: TextStyle(color: app.color.inactive, fontSize: 12.5),
          ),
        ],
      ],
    );
  }
}
