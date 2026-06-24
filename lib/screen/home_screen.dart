import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reiri_app_core/reiri_app_core.dart';

import 'package:reiri_db_backup_tool/lib/initial_backup_constants.dart';
import 'package:reiri_db_backup_tool/service/tray_service.dart';
import 'package:reiri_db_backup_tool/model/backup_log_entry.dart';
import 'package:reiri_db_backup_tool/model/backup_metadata.dart';

import 'package:reiri_db_backup_tool/provider/backup_log_provider.dart';
import 'package:reiri_db_backup_tool/provider/recovery_provider.dart';
import 'package:reiri_db_backup_tool/screen/initial_backup_screen.dart';
import 'package:reiri_db_backup_tool/screen/login_screen.dart';
import 'package:reiri_db_backup_tool/service/file_log_service.dart';
import 'package:reiri_db_backup_tool/service/recovery_service.dart';
import 'package:reiri_db_backup_tool/view/backup_log_view.dart';
import 'package:reiri_db_backup_tool/view/recovery_view.dart';
import 'package:reiri_db_backup_tool/view/settings_view.dart';

// ─── Enums & models ───────────────────────────────────────────────────────────

enum _NavItem { dashboard, recovery, backupLog, settings }

enum _SyncStatus { synced, delayed, notFound, missingDisconnected, missingScheduled }

class _DbDesc {
  final String filename;
  final String description;
  const _DbDesc(this.filename, this.description);
}

const _kDbDescriptions = [
  _DbDesc('history.db', 'Operation history'),
  _DbDesc('meter.db', 'Energy metering'),
  _DbDesc('optime.db', 'Operation time'),
  _DbDesc('trend.db', 'Trend data'),
  _DbDesc('ppd.db', 'PPD calculated'),
];

class _DbStatEntry {
  final String filename;
  final String description;
  final DateTime? lastBackup;
  final _SyncStatus status;
  const _DbStatEntry({
    required this.filename,
    required this.description,
    required this.lastBackup,
    required this.status,
  });
}

// ─── Root screen ──────────────────────────────────────────────────────────────

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  _NavItem _selected = _NavItem.dashboard;
  List<_DbStatEntry> _dbStats = [];
  Timer? _refreshTimer;
  bool _loadingStats = false;
  String? _backupRootPath;
  String _currentMac = '';

  final _bcom = RealtimeDbBackup();
  bool _realtimeActive = false;
  DateTime? _lastRealtimeEvent;
  bool _realtimeStarted = false;
  /// True after backup-folder DBs are opened (or there is nothing to open).
  /// Realtime must not start before this: `db_wr` is applied in [ReiriController] via [app.db].
  bool _localBackupDbReady = false;
  DateTime? _lastKnownMaxModified;

  final Map<String, DateTime> _prevFileMod = {};
  bool _firstStatLoad = true;

  final _recoveryService = RecoveryService();

  /// Guards against running gap detection twice at once. Both [_init] (when the
  /// controller is already connected at mount) and the [connectionProvider]
  /// listener call [_runGapDetection]; without this flag they can race and
  /// drive two concurrent TEMP-staging cycles on the same DB handles.
  bool _gapDetectionRunning = false;

  /// Runs reconnect gap detection exactly once at a time and surfaces any gaps
  /// to the recovery provider. [RecoveryService] also serializes internally,
  /// but this avoids even queueing a redundant second pass.
  Future<void> _runGapDetection() async {
    if (_gapDetectionRunning) return;
    if (_backupRootPath == null) return;
    _gapDetectionRunning = true;
    try {
      await _recoveryService.onConnected();
      final allGaps = _recoveryService.metadata.detectedGaps;
      if (allGaps.isNotEmpty) {
        FileLogService().log(
            '[Recovery] *** ${allGaps.length} gap(s) scheduled (including carry-over) ***');
        for (final g in allGaps) {
          FileLogService().log(
              '[Recovery]   ${g.dbFile}: ${g.start} → ${g.end} (${g.duration.inMinutes}min)');
        }
        if (mounted) ref.read(recoveryProvider.notifier).onGapsDetected(allGaps);
        if (mounted) await _loadDbStats();
      } else {
        FileLogService().log('[Recovery] No gaps — real-time → MAIN DB');
      }
    } finally {
      _gapDetectionRunning = false;
    }
  }

  void _tryStartRealtimeBackup() {
    if (!_localBackupDbReady) return;
    final connection = ref.read(connectionProvider);
    if (connection == null || connection['state'] != 'ready') return;
    if (_realtimeStarted) return;
    _realtimeStarted = true;
    final started = _bcom.start();
    print('[RealtimeBackup] _tryStartRealtimeBackup — bcom.start(): $started');
    if (started) app.requestController(_bcom);
  }

  @override
  void initState() {
    super.initState();
    _init();
    _refreshTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) {
        // Crash-safety heartbeat: while connected, keep disconnectedAt fresh
        // so a force-kill leaves a timestamp ≤1 min stale for gap detection.
        // Must NOT update during a real outage — that would overwrite the
        // original disconnect timestamp and cause gap detection to miss the gap.
        final conn = ref.read(connectionProvider);
        if (conn != null && conn['state'] == 'ready') {
          _recoveryService.onDisconnected();
        }
        _loadDbStats();
        _maybeAutoFlush();
      },
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    // Record disconnect time so the next launch can compute the gap correctly.
    _recoveryService.onDisconnected();
    super.dispose();
  }

  Future<void> _init() async {
    _currentMac = app.selectedController?['macaddr']?.toString() ??
        app.controllerList.keys.firstOrNull ?? '';

    if (_currentMac.isNotEmpty) {
      ref.read(backupLogProvider.notifier).init(_currentMac);
    }

    // Guard: if backup files are missing, redirect to initial backup regardless
    // of which navigation path brought us here (login, auto-login, splash).
    if (_currentMac.isNotEmpty) {
      final needsBackup =
          await InitialBackupScreen.needsInitialBackup(_currentMac);
      if (needsBackup) {
        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => InitialBackupScreen(initialMac: _currentMac),
            ),
          );
        }
        return;
      }
    }

    if (_currentMac.isNotEmpty) {
      final stored = await loadBackupRootPath(_currentMac);
      if (mounted) setState(() => _backupRootPath = stored);
      if (stored != null) {
        // Init file logger before recovery service so all recovery events land
        // in the log from the very first line.
        final safeMac = macToSafeFolderName(_currentMac);
        FileLogService().init(stored, safeMac: safeMac);
        // Init recovery service first (may redirect app.db to TEMP on resume).
        await _recoveryService.init(rootPath: stored, safeMac: safeMac);
        // Seed the notifier's cached recovery time before attaching so
        // _syncFromService() computes scheduledAt with the correct time.
        final recovTime = await loadRecoveryTime();
        ref.read(recoveryProvider.notifier).setRecoveryTime(
            recovTime.hour, recovTime.minute);
        ref.read(recoveryProvider.notifier).attach(_recoveryService);

        // If a previous session left us mid-flush, DB is already on MAIN after
        // RecoveryService.init() re-ran the flush. Open MAIN normally.
        final ok = await _openReiriDb(stored);
        if (!ok) return;
      }
    }
    if (mounted) {
      _localBackupDbReady = true;

      // If the connection is already 'ready' when HomeScreen mounts (e.g. after
      // auto-login), the connection listener won't fire — run gap detection now.
      final connection = ref.read(connectionProvider);
      if (connection != null && connection['state'] == 'ready' && _backupRootPath != null) {
        FileLogService().log('[Connection] Already connected on startup — running gap detection');
        await _runGapDetection();
      }

      _tryStartRealtimeBackup();
    }
    await _loadDbStats();
  }

  Future<bool> _openReiriDb(String rootPath) async {
    if (app.db == null) {
      print('[ReiriDb] app.db is null — skipping DB init');
      return false;
    }
    final safeMac = macToSafeFolderName(_currentMac);
    final dbDir = '$rootPath\\$safeMac\\$kInitialBackupDbFolderName';
    print('[ReiriDb] setting DB path → $dbDir');
    await app.setDbPath(dbDir);

    await app.db!.openHistoryDb(); await app.db!.initHistoryDb();
    await app.db!.openMeterDb();   await app.db!.initMeterDb();
    await app.db!.openOptimeDb();  await app.db!.initOptimeDb();
    await app.db!.openPpdDb();     await app.db!.initPpdDb();
    await app.db!.openTrendDb();   await app.db!.initTrendDb();
    print('[ReiriDb] DB files opened and initialised');
    return true;
  }

  Future<void> _loadDbStats() async {
    if (_loadingStats) return;
    _loadingStats = true;
    try {
      if (_currentMac.isEmpty || _backupRootPath == null) return;

      final safeMac = macToSafeFolderName(_currentMac);
      final dbDirPath =
          '$_backupRootPath\\$safeMac\\$kInitialBackupDbFolderName';
      final tempDirPath =
          '$_backupRootPath\\$safeMac\\$kTempDbFolderName';
      final inTempMode = _recoveryService.hasActiveGap;

      final entries = <_DbStatEntry>[];
      final pendingLogEntries = <BackupLogEntry>[];
      DateTime? maxModified;
      for (final desc in _kDbDescriptions) {
        final filePath = '$dbDirPath\\${desc.filename}';
        final file = File(filePath);

        // Determine effective last-modified: use TEMP file time when it is
        // newer than MAIN (real-time writes land in TEMP during gap recovery).
        DateTime? effectiveMod;
        bool fileFound = false;

        if (await file.exists()) {
          fileFound = true;
          effectiveMod = (await file.stat()).modified;
        }
        if (inTempMode) {
          final tempFile = File('$tempDirPath\\${desc.filename}');
          if (await tempFile.exists()) {
            fileFound = true;
            final tempMod = (await tempFile.stat()).modified;
            if (effectiveMod == null || tempMod.isAfter(effectiveMod)) {
              effectiveMod = tempMod;
            }
          }
        }

        if (fileFound && effectiveMod != null) {
          if (maxModified == null || effectiveMod.isAfter(maxModified)) {
            maxModified = effectiveMod;
          }
          if (!_firstStatLoad && _realtimeActive) {
            final prevMod = _prevFileMod[desc.filename];
            if (prevMod == null || effectiveMod.isAfter(prevMod)) {
              DateTime recordTime = effectiveMod;
              try {
                final dbType = RecoveryService.fileToDbType(desc.filename);
                if (dbType != null && app.db != null) {
                  int latestInt = 0;
                  switch (dbType) {
                    case 'trend':
                      latestInt = await app.db!.latestTrendData();
                    case 'meter':
                      latestInt = app.db!.latestMeterData();
                    case 'optime':
                      latestInt = await app.db!.latestOptimeData();
                    case 'ppd':
                      latestInt = await app.db!.latestPpdData();
                    case 'history':
                      latestInt = await app.db!.latestHistoryData();
                  }
                  if (latestInt > 0) recordTime = _dbIntToDateTime(latestInt);
                }
              } catch (_) {}
              pendingLogEntries.add(BackupLogEntry(
                timestamp: recordTime,
                backedUpAt: DateTime.now(),
                type: BackupLogType.realtime,
                result: BackupLogResult.success,
                database: desc.filename,
              ));
            }
          }
          _prevFileMod[desc.filename] = effectiveMod;
          final detectedGaps = _recoveryService.metadata.detectedGaps;
          final hasGapForFile =
              detectedGaps.any((g) => g.dbFile == desc.filename);
          _SyncStatus entryStatus;
          if (hasGapForFile) {
            final conn = ref.read(connectionProvider);
            final connected = conn != null && conn['state'] == 'ready';
            entryStatus = connected
                ? _SyncStatus.missingScheduled
                : _SyncStatus.missingDisconnected;
          } else {
            entryStatus = _SyncStatus.synced;
          }
          entries.add(_DbStatEntry(
            filename: desc.filename,
            description: desc.description,
            lastBackup: effectiveMod,
            status: entryStatus,
          ));
        } else {
          entries.add(_DbStatEntry(
            filename: desc.filename,
            description: desc.description,
            lastBackup: null,
            status: _SyncStatus.notFound,
          ));
        }
      }

      if (mounted) {
        setState(() {
          _dbStats = entries;
          if (_realtimeActive &&
              maxModified != null &&
              (_lastKnownMaxModified == null ||
                  maxModified.isAfter(_lastKnownMaxModified!))) {
            _lastRealtimeEvent = DateTime.now();
          }
          _lastKnownMaxModified = maxModified;
        });
        if (pendingLogEntries.isNotEmpty) {
          ref.read(backupLogProvider.notifier).addEntries(pendingLogEntries);
        }
      }
      _firstStatLoad = false;
    } finally {
      _loadingStats = false;
    }
  }


  void _maybeAutoFlush() {
    final recovState = ref.read(recoveryProvider);
    if (recovState.scheduledAt == null) return;
    if (recovState.isFlushing) return;
    if (DateTime.now().isBefore(recovState.scheduledAt!)) return;
    ref.read(recoveryProvider.notifier).runFlushNow();
  }

  Future<void> _setBackupPath(String path) async {
    final safeMac = _currentMac.isEmpty ? '' : macToSafeFolderName(_currentMac);

    // Offer to migrate existing data when the path actually changes.
    if (_backupRootPath != null &&
        _backupRootPath != path &&
        _currentMac.isNotEmpty) {
      final oldMacDir = Directory('$_backupRootPath\\$safeMac');
      if (await oldMacDir.exists() && mounted) {
        final move = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Move Backup Data?'),
            content: Text(
              'Existing backup data was found at:\n$_backupRootPath\n\n'
              'Move it to the new location so backup can continue from where it left off?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('No, start fresh'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Move Data'),
              ),
            ],
          ),
        );
        if (move == true) {
          await _migrateBackupData(_backupRootPath!, path, safeMac);
        }
      }
    }

    if (_currentMac.isNotEmpty) {
      await storeBackupRootPath(_currentMac, path);
    }
    setState(() => _backupRootPath = path);
    FileLogService().init(path, safeMac: safeMac);

    // Init recovery service for the newly selected path.
    if (_currentMac.isNotEmpty) {
      await _recoveryService.init(rootPath: path, safeMac: safeMac);
      ref.read(recoveryProvider.notifier).attach(_recoveryService);
    }

    final ok = await _openReiriDb(path);
    if (!ok) return;
    _localBackupDbReady = true;
    await _loadDbStats();
    if (mounted) _tryStartRealtimeBackup();
  }

  /// Copies the per-controller folder from [oldRoot] to [newRoot] so the user
  /// can continue backing up to the new location without losing history.
  Future<void> _migrateBackupData(
      String oldRoot, String newRoot, String safeMac) async {
    final src = Directory('$oldRoot\\$safeMac');
    if (!await src.exists()) return;
    final dst = Directory('$newRoot\\$safeMac');
    if (!await dst.exists()) await dst.create(recursive: true);
    await _copyDirRecursive(src, dst);
    FileLogService().log('[Migrate] Copied backup data from $oldRoot to $newRoot');
  }

  Future<void> _copyDirRecursive(Directory src, Directory dst) async {
    await for (final entity in src.list()) {
      final name = entity.path.contains('\\')
          ? entity.path.split('\\').last
          : entity.path.split('/').last;
      if (entity is File) {
        await entity.copy('${dst.path}\\$name');
      } else if (entity is Directory) {
        final subDst = Directory('${dst.path}\\$name');
        if (!await subDst.exists()) await subDst.create();
        await _copyDirRecursive(entity, subDst);
      }
    }
  }

  void _showLogoutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Logout'),
        content: const Text(
          'Backup will stop after logout. Are you sure you want to log out?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Colors.red.shade600),
            onPressed: () async {
              Navigator.pop(ctx);
              // Record disconnect time before leaving so the next login can
              // compute the gap correctly.
              await _recoveryService.onDisconnected();
              app.logout();
              if (context.mounted) {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (_) => LoginScreen()),
                );
              }
            },
            child: const Text('Logout'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final connection = ref.watch(connectionProvider);
    final isConnected =
        connection != null && connection['state'] == 'ready';
    final mac = _currentMac.isNotEmpty ? _currentMac : 'N/A';
    final ctrlName = app.controllerList[mac]?['name']?.toString() ??
        'Reiri Controller';

    // Auto-start realtime backup when connection becomes ready; reset on disconnect.
    ref.listen(connectionProvider, (_, next) async {
      final ready = next != null && next['state'] == 'ready';
      TrayService.instance.updateStatus(
        isConnected: ready,
        backupHealthy: ready && _realtimeActive,
      );
      if (ready) {
        FileLogService().log('[Connection] Reconnected to controller');
        // Detect gaps from the previous disconnect period (reconnect while running).
        await _runGapDetection();
        _tryStartRealtimeBackup();
      } else if (_realtimeStarted) {
        _realtimeStarted = false;
        if (mounted) setState(() => _realtimeActive = false);
        FileLogService().log('[Connection] Disconnected from controller');
        // Record the disconnect time so the next connect can compute the gap.
        await _recoveryService.onDisconnected();
      }
    });

    // After a manual or scheduled flush, refresh stats and log recovery entries.
    ref.listen<RecoveryState>(recoveryProvider, (prev, next) async {
      if (prev != null &&
          prev.isFlushing &&
          !next.isFlushing &&
          next.backupState == BackupState.realtimeMain) {
        await _loadDbStats();
      }
    });

    // Receive records pushed by the controller and append them to the local DB.
    ref.listen(communicationProvider(_bcom), (_, data) async {
      print('[RealtimeBackup] listener fired — data: $data');
      if (data == null) return;

      print('[RealtimeBackup] keys: ${data.keys.toList()}');
      print('[RealtimeBackup] result: ${data['result']}');
      print('[RealtimeBackup] sub_command: ${_bcom.sub_command}');
      print('[RealtimeBackup] app.db null? ${app.db == null}');
      print('[RealtimeBackup] data[data]: ${data['data']}');

      // db_wr packets are handled directly by ReiriController._dispatch() → app.db.save().
      // This provider only fires once with the start ACK (result: OK, data: null).
      if (mounted) {
        setState(() => _realtimeActive = true);
        final conn = ref.read(connectionProvider);
        TrayService.instance.updateStatus(
          isConnected: conn != null && conn['state'] == 'ready',
          backupHealthy: true,
        );
      }
    });

    return Scaffold(
      body: Row(
        children: [
          _Sidebar(
            selected: _selected,
            onSelect: (item) => setState(() => _selected = item),
          ),
          Expanded(
            child: _buildTabContent(
                context, isConnected, mac, ctrlName),
          ),
        ],
      ),
    );
  }

  Widget _buildTabContent(
    BuildContext context,
    bool isConnected,
    String mac,
    String ctrlName,
  ) {
    switch (_selected) {
      case _NavItem.dashboard:
        return _DashboardContent(
          dbStats: _dbStats,
          isConnected: isConnected,
          macAddr: mac,
          ctrlName: ctrlName,
          backupRootPath: _backupRootPath,
          onRefresh: _loadDbStats,
          onGoToSettings: () =>
              setState(() => _selected = _NavItem.settings),
          realtimeActive: _realtimeActive,
          lastRealtimeEvent: _lastRealtimeEvent,
        );
      case _NavItem.recovery:
        return const RecoveryView();
      case _NavItem.backupLog:
        return BackupLogView(
          macAddr: _currentMac,
          backupPath: _backupRootPath != null && _currentMac.isNotEmpty
              ? '$_backupRootPath\\${macToSafeFolderName(_currentMac)}'
              : null,
        );
      case _NavItem.settings:
        return SettingsView(
          backupRootPath: _backupRootPath,
          onPathChanged: _setBackupPath,
          onLogout: () => _showLogoutDialog(context),
        );
    }
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

/// Converts the DB integer date format (YYYYMMDDHHmm) to a [DateTime].
DateTime _dbIntToDateTime(int date) {
  final year  = date ~/ 100000000;
  final rest  = date % 100000000;
  final month = rest  ~/ 1000000;
  final rest2 = rest  %  1000000;
  final day   = rest2 ~/ 10000;
  final rest3 = rest2 %  10000;
  final hour  = rest3 ~/ 100;
  final min   = rest3 %  100;
  return DateTime(year, month, day, hour, min);
}

// ─── Sidebar ──────────────────────────────────────────────────────────────────

class _Sidebar extends ConsumerWidget {
  final _NavItem selected;
  final ValueChanged<_NavItem> onSelect;

  const _Sidebar({
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final themeMode = ref.watch(stringDataProvider('theme_mode'));
    final isDark = themeMode == 'dark' ||
        (themeMode != 'light' &&
            MediaQuery.of(context).platformBrightness ==
                Brightness.dark);
    final hasMissingData = ref.watch(recoveryProvider).hasGaps;

    return SizedBox(
      width: 170,
      child: Material(
        color: cs.surface,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(right: BorderSide(color: cs.outlineVariant)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 22, 18, 28),
                child: RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: 'Reiri ',
                        style: TextStyle(
                            color: cs.primary,
                            fontWeight: FontWeight.bold,
                            fontSize: 18),
                      ),
                      TextSpan(
                        text: 'Backup',
                        style: TextStyle(
                            color: cs.onSurface,
                            fontWeight: FontWeight.bold,
                            fontSize: 18),
                      ),
                    ],
                  ),
                ),
              ),
              _NavTile(
                icon: Icons.dashboard_outlined,
                label: 'Dashboard',
                item: _NavItem.dashboard,
                selected: selected,
                onTap: onSelect,
              ),
              _NavTile(
                icon: Icons.restore_rounded,
                label: 'Recovery',
                item: _NavItem.recovery,
                selected: selected,
                onTap: onSelect,
                showDot: hasMissingData,
              ),
              _NavTile(
                icon: Icons.article_outlined,
                label: 'Backup Log',
                item: _NavItem.backupLog,
                selected: selected,
                onTap: onSelect,
              ),
              _NavTile(
                icon: Icons.settings_outlined,
                label: 'Settings',
                item: _NavItem.settings,
                selected: selected,
                onTap: onSelect,
              ),
              const Spacer(),
              ListTile(
                dense: true,
                minLeadingWidth: 20,
                leading: Icon(
                  isDark
                      ? Icons.light_mode_outlined
                      : Icons.dark_mode_outlined,
                  size: 18,
                ),
                title: Text(
                  isDark ? 'Light Mode' : 'Dark Mode',
                  style: const TextStyle(fontSize: 13),
                ),
                onTap: () {
                  ref
                      .read(stringDataProvider('theme_mode').notifier)
                      .set(isDark ? 'light' : 'dark');
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
                child: Text('v1.0.0',
                    style: TextStyle(
                        fontSize: 11, color: cs.outlineVariant)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final _NavItem item;
  final _NavItem selected;
  final ValueChanged<_NavItem> onTap;
  final bool showDot;

  const _NavTile({
    required this.icon,
    required this.label,
    required this.item,
    required this.selected,
    required this.onTap,
    this.showDot = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isActive = selected == item;
    return ListTile(
      dense: true,
      minLeadingWidth: 20,
      selected: isActive,
      selectedTileColor: cs.primaryContainer.withValues(alpha: 0.5),
      leading: Badge(
        isLabelVisible: showDot,
        backgroundColor: Colors.orange,
        smallSize: 7,
        child: Icon(icon,
            size: 18,
            color: isActive ? cs.primary : cs.onSurfaceVariant),
      ),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          color: isActive ? cs.primary : cs.onSurfaceVariant,
          fontWeight:
              isActive ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      onTap: () => onTap(item),
    );
  }
}

// ─── Dashboard content ────────────────────────────────────────────────────────

class _DashboardContent extends StatelessWidget {
  final List<_DbStatEntry> dbStats;
  final bool isConnected;
  final String macAddr;
  final String ctrlName;
  final String? backupRootPath;
  final VoidCallback onRefresh;
  final VoidCallback onGoToSettings;
  final bool realtimeActive;
  final DateTime? lastRealtimeEvent;

  const _DashboardContent({
    required this.dbStats,
    required this.isConnected,
    required this.macAddr,
    required this.ctrlName,
    required this.backupRootPath,
    required this.onRefresh,
    required this.onGoToSettings,
    required this.realtimeActive,
    required this.lastRealtimeEvent,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ColoredBox(
      color: cs.surfaceContainerLowest,
      child: Align(
        alignment: Alignment.topLeft,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Dashboard',
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface),
              ),
              const SizedBox(height: 2),
              Text(
                'Overview of backup status and connected databases',
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              _ControllerCard(
                isConnected: isConnected,
                macAddr: macAddr,
                ctrlName: ctrlName,
                onRefresh: onRefresh,
              ),
              if (backupRootPath == null) ...[
                const SizedBox(height: 12),
                _NoBkPathBanner(onGoToSettings: onGoToSettings),
              ],
              const SizedBox(height: 16),
              _DatabaseStatusCard(dbStats: dbStats),
              const SizedBox(height: 20),
              _RealtimeBackupCard(
                isActive: realtimeActive,
                lastEvent: lastRealtimeEvent,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoBkPathBanner extends StatelessWidget {
  final VoidCallback onGoToSettings;
  const _NoBkPathBanner({required this.onGoToSettings});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.orange.shade200),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded,
              size: 18, color: Colors.orange.shade700),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Backup directory not configured. '
              'DB stats cannot be loaded.',
              style: TextStyle(
                  fontSize: 13, color: Colors.orange.shade800),
            ),
          ),
          TextButton(
            onPressed: onGoToSettings,
            style: TextButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              visualDensity: VisualDensity.compact,
              foregroundColor: Colors.orange.shade800,
            ).copyWith(
              mouseCursor: const WidgetStatePropertyAll(SystemMouseCursors.click),
            ),
            child: const Text('Go to Settings',
                style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

// ─── Controller header card ───────────────────────────────────────────────────

class _ControllerCard extends StatelessWidget {
  final bool isConnected;
  final String macAddr;
  final String ctrlName;
  final VoidCallback onRefresh;

  const _ControllerCard({
    required this.isConnected,
    required this.macAddr,
    required this.ctrlName,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                  color: cs.secondaryContainer,
                  borderRadius: BorderRadius.circular(8)),
              child: Icon(Icons.router_outlined, color: cs.secondary),
            ),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(ctrlName,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 15)),
                Text('MAC: $macAddr',
                    style: TextStyle(
                        color: cs.onSurfaceVariant, fontSize: 12)),
              ],
            ),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Refresh Now'),
              style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact).copyWith(
                mouseCursor: const WidgetStatePropertyAll(SystemMouseCursors.click),
              ),
            ),
            const SizedBox(width: 16),
            Row(
              children: [
                Icon(Icons.circle,
                    size: 9,
                    color: isConnected ? Colors.green : Colors.red),
                const SizedBox(width: 6),
                Text(
                  isConnected ? 'Connected' : 'Disconnected',
                  style: TextStyle(
                    color: isConnected ? Colors.green : Colors.red,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Database status table ────────────────────────────────────────────────────

class _DatabaseStatusCard extends StatelessWidget {
  final List<_DbStatEntry> dbStats;
  const _DatabaseStatusCard({required this.dbStats});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final rows = dbStats.isEmpty
        ? _kDbDescriptions
            .map((d) => _DbStatEntry(
                filename: d.filename,
                description: d.description,
                lastBackup: null,
                status: _SyncStatus.notFound))
            .toList()
        : dbStats;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Database Status',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            _TableHeader(),
            const Divider(height: 1),
            ...rows.map((db) => _TableRow(db: db)),
          ],
        ),
      ),
    );
  }
}

class _TableHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 11,
      letterSpacing: 0.6,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w500,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(flex: 22, child: Text('DATABASE', style: style)),
          Expanded(
              flex: 28, child: Text('DESCRIPTION', style: style)),
          Expanded(
              flex: 20, child: Text('LAST BACKUP', style: style)),
          Expanded(
              flex: 16,
              child: Text('STATUS',
                  style: style, textAlign: TextAlign.end)),
        ],
      ),
    );
  }
}

class _TableRow extends StatelessWidget {
  final _DbStatEntry db;
  const _TableRow({required this.db});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isNotFound = db.status == _SyncStatus.notFound;
    final isDelayed = db.status == _SyncStatus.delayed;

    final Color badgeBg;
    final Color badgeBorder;
    final Color badgeText;
    final String badgeLabel;
    IconData? badgeIcon;

    if (isNotFound) {
      badgeBg = cs.surfaceContainerHigh;
      badgeBorder = cs.outlineVariant;
      badgeText = cs.onSurfaceVariant;
      badgeLabel = 'Not found';
      badgeIcon = null;
    } else if (isDelayed) {
      badgeBg = Colors.orange.shade50;
      badgeBorder = Colors.orange.shade200;
      badgeText = Colors.orange.shade700;
      badgeLabel = 'Delayed';
      badgeIcon = Icons.warning_amber_rounded;
    } else if (db.status == _SyncStatus.missingDisconnected) {
      badgeBg = Colors.red.shade50;
      badgeBorder = Colors.red.shade200;
      badgeText = Colors.red.shade700;
      badgeLabel = 'Not synced';
      badgeIcon = Icons.close_rounded;
    } else if (db.status == _SyncStatus.missingScheduled) {
      badgeBg = Colors.blue.shade50;
      badgeBorder = Colors.blue.shade200;
      badgeText = Colors.blue.shade700;
      badgeLabel = 'Scheduled to sync';
      badgeIcon = Icons.sync_rounded;
    } else {
      badgeBg = Colors.green.shade50;
      badgeBorder = Colors.green.shade200;
      badgeText = Colors.green.shade700;
      badgeLabel = 'Synced';
      badgeIcon = Icons.check_rounded;
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(
                color: cs.outlineVariant.withValues(alpha: 0.4))),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 22,
            child: Text(db.filename,
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    fontWeight: FontWeight.w500)),
          ),
          Expanded(
            flex: 28,
            child: Text(db.description,
                style: TextStyle(
                    fontSize: 13, color: cs.onSurfaceVariant)),
          ),
          Expanded(
            flex: 20,
            child: db.lastBackup != null
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_fmtDateTime(db.lastBackup!),
                          style: const TextStyle(fontSize: 13)),
                      Text(_fmtAgo(db.lastBackup!),
                          style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurfaceVariant)),
                    ],
                  )
                : const Text('—', style: TextStyle(fontSize: 13)),
          ),
          Expanded(
            flex: 16,
            child: Align(
              alignment: Alignment.centerRight,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: badgeBg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: badgeBorder),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (badgeIcon != null) ...[
                      Icon(badgeIcon, size: 11, color: badgeText),
                      const SizedBox(width: 3),
                    ],
                    Text(badgeLabel,
                        style: TextStyle(
                            fontSize: 12,
                            color: badgeText,
                            fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Real-time backup card ────────────────────────────────────────────────────

class _RealtimeBackupCard extends StatelessWidget {
  final bool isActive;
  final DateTime? lastEvent;

  const _RealtimeBackupCard({
    required this.isActive,
    required this.lastEvent,
  });

  String _lastEventLabel() {
    if (lastEvent == null) return 'No events yet';
    final diff = DateTime.now().difference(lastEvent!);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${diff.inHours}h ago';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Real-time Backup',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.circle,
                    size: 9,
                    color: isActive ? Colors.green : cs.outlineVariant),
                const SizedBox(width: 8),
                Text(
                  isActive ? 'Active' : 'Waiting for connection',
                  style: TextStyle(
                      color: isActive
                          ? Colors.green
                          : cs.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                      fontSize: 13),
                ),
                if (isActive)
                  Text(' — Appending new records',
                      style: TextStyle(
                          fontSize: 13, color: cs.onSurfaceVariant)),
                const Spacer(),
                if (isActive)
                  Text(
                    'Last event: ${_lastEventLabel()}',
                    style: TextStyle(
                        fontSize: 12, color: cs.onSurfaceVariant),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

String _fmtDateTime(DateTime dt) {
  final d = dt.day.toString().padLeft(2, '0');
  final mon = _kMonths[dt.month - 1];
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  return '$d $mon $h:$m';
}

String _fmtAgo(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}

const _kMonths = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];
