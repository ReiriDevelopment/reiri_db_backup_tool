import 'dart:io';

import 'package:ftpconnect/ftpconnect.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:reiri_app_core/reiri_app_core.dart';

import 'package:reiri_db_backup_tool/lib/initial_backup_constants.dart';

class InitialBackupFtpView extends StatefulWidget {
  const InitialBackupFtpView({
    super.key,
    required this.controllerIp,
    required this.macaddr,
    required this.onCompleted,
  });

  final String controllerIp;
  final String macaddr;
  final Future<void> Function(String methodValue, String backupPath) onCompleted;

  @override
  State<InitialBackupFtpView> createState() => _InitialBackupFtpViewState();
}

class _InitialBackupFtpViewState extends State<InitialBackupFtpView> {
  String? _backupPath;
  bool _isDownloading = false;
  double _progress01 = 0;
  int _downloadedCount = 0;
  String? _currentFile;

  bool get _canStart =>
      !_isDownloading && _backupPath != null && _backupPath!.isNotEmpty;

  String get _dbFolderName => kInitialBackupDbFolderName;

  Future<void> _pickBackupPath() async {
    final path = await getDirectoryPath();
    if (path == null || path.isEmpty) return;
    setState(() {
      _backupPath = path;
      _progress01 = 0;
      _downloadedCount = 0;
      _currentFile = null;
    });
  }

  Future<void> _startDownload() async {
    if (!_canStart) return;
    if (widget.controllerIp.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Controller IP is not available.')),
      );
      return;
    }

    setState(() {
      _isDownloading = true;
      _progress01 = 0;
      _downloadedCount = 0;
      _currentFile = null;
    });

    final safeMac = widget.macaddr.replaceAll(':', '_');
    final dbDir = Directory('${_backupPath!}\\$safeMac\\$_dbFolderName');
    dbDir.createSync(recursive: true);

    final remoteFiles = kInitialBackupDbFiles;
    final totalFiles = remoteFiles.length;
    int completedFiles = 0;

    FTPConnect? ftp;
    try {
      ftp = FTPConnect(widget.controllerIp, user: 'reiri', pass: 'reiri_logiN');
      if (!await ftp.connect()) {
        throw Exception('FTP connect failed');
      }
      await ftp.setTransferType(TransferType.binary);
      await ftp.changeDirectory('/var/www/db');

      for (final remoteName in remoteFiles) {
        if (!_isDownloading) return;
        setState(() => _currentFile = remoteName);

        final exists = await ftp.existFile(remoteName);
        if (!exists) {
          completedFiles++;
          setState(() {
            _downloadedCount = completedFiles;
            _progress01 = completedFiles / totalFiles;
          });
          continue;
        }

        final localFile = File('${dbDir.path}\\$remoteName');
        await ftp.downloadFile(
          remoteName,
          localFile,
          onProgress: (percent, received, fileSize) {
            final overall = (completedFiles + (percent / 100)) / totalFiles;
            if (!mounted) return;
            setState(() => _progress01 = overall.clamp(0, 1));
          },
        );

        completedFiles++;
        setState(() {
          _downloadedCount = completedFiles;
          _progress01 = completedFiles / totalFiles;
        });
      }

      await ftp.disconnect();
      ftp = null;

      if (!mounted) return;
      await widget.onCompleted('ftp', _backupPath!);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('FTP download failed: $e')),
      );
    } finally {
      try {
        await ftp?.disconnect();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _currentFile = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_backupPath == null)
          Row(
            children: [
              const Icon(Icons.storage_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Backup path: not selected',
                  style: TextStyle(color: app.color.inactive, fontSize: 13),
                ),
              ),
              TextButton.icon(
                onPressed: _isDownloading ? null : _pickBackupPath,
                icon: const Icon(Icons.folder_open),
                label: const Text('Select Path'),
                style: const ButtonStyle(
                  mouseCursor: WidgetStatePropertyAll(SystemMouseCursors.click),
                ),
              ),
            ],
          )
        else
          Row(
            children: [
              const Icon(Icons.folder_outlined),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${_backupPath!}\\${macToSafeFolderName(widget.macaddr)}\\$_dbFolderName',
                  style: TextStyle(color: app.color.inactive, fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: _isDownloading ? null : _pickBackupPath,
                style: const ButtonStyle(
                  mouseCursor: WidgetStatePropertyAll(SystemMouseCursors.click),
                ),
                child: const Text('Change'),
              ),
            ],
          ),

        const SizedBox(height: 16),

        ElevatedButton.icon(
          onPressed: _canStart ? _startDownload : null,
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('Start FTP Download'),
          style: ElevatedButton.styleFrom().copyWith(
            mouseCursor: WidgetStateProperty.resolveWith((s) =>
                s.contains(WidgetState.disabled)
                    ? SystemMouseCursors.basic
                    : SystemMouseCursors.click),
          ),
        ),

        if (_isDownloading) ...[
          const SizedBox(height: 16),
          LinearProgressIndicator(value: _progress01),
          const SizedBox(height: 8),
          Text(
            '${(_progress01 * 100).toStringAsFixed(0)}%  '
            '($_downloadedCount / ${kInitialBackupDbFiles.length})'
            '${_currentFile != null ? '  —  $_currentFile' : ''}',
            style: TextStyle(color: app.color.inactive, fontSize: 12.5),
          ),
        ],
      ],
    );
  }
}
