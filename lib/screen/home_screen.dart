import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reiri_app_core/reiri_app_core.dart';

import 'package:reiri_db_backup_tool/lib/initial_backup_constants.dart';
import 'package:reiri_db_backup_tool/model/backup_metadata.dart';

import 'package:reiri_db_backup_tool/provider/backup_log_provider.dart';
import 'package:reiri_db_backup_tool/provider/recovery_provider.dart';
import 'package:reiri_db_backup_tool/screen/initial_backup_screen.dart';
import 'package:reiri_db_backup_tool/screen/login_screen.dart';
import 'package:reiri_db_backup_tool/service/connection_monitor_service.dart';
import 'package:reiri_db_backup_tool/service/database_status_service.dart';
import 'package:reiri_db_backup_tool/service/file_log_service.dart';
import 'package:reiri_db_backup_tool/service/realtime_backup_service.dart';
import 'package:reiri_db_backup_tool/service/recovery_service.dart';
import 'package:reiri_db_backup_tool/service/tray_service.dart';
import 'package:reiri_db_backup_tool/view/backup_log_view.dart';
import 'package:reiri_db_backup_tool/view/dashboard_view.dart';
import 'package:reiri_db_backup_tool/view/recovery_view.dart';
import 'package:reiri_db_backup_tool/view/settings_view.dart';

/// Identifies the content sections available from the home sidebar.
enum _NavItem { dashboard, recovery, backupLog, settings }

/// Hosts backup monitoring, recovery, logs, and settings after setup.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

/// Coordinates connection monitoring, recovery, and real-time backup services.
class _HomeScreenState extends ConsumerState<HomeScreen> {
  _NavItem _selected = _NavItem.dashboard;
  List<DatabaseStatEntry> _dbStats = [];
  Timer? _refreshTimer;
  DateTime _lastRefreshTick = DateTime.now();
  bool _refreshTickRunning = false;
  bool _refreshCoolingDown = false;
  String? _backupRootPath;
  String _currentMac = '';

  bool _realtimeActive = false;
  DateTime? _lastRealtimeEvent;

  // The WebSocket can take 90 seconds to notice a dead link.
  // Track OS reachability for immediate dashboard and recovery updates.
  bool _networkReachable = true;
  Timer? _networkCheckTimer;

  // Realtime starts only after app.db points to the backup folder.
  bool _localBackupDbReady = false;
  final _recoveryService = RecoveryService();
  late final ConnectionMonitorService _connectionMonitor;
  late final RealtimeBackupService _realtimeBackup;
  late final DatabaseStatusService _databaseStatus;

  // Defer connection changes while recovery owns the database handles.
  bool _connectionSyncDeferredByRecovery = false;

  bool get _isRecoveryFlushing => ref.read(recoveryProvider).isFlushing;

  Future<void> _runGapDetection() async {
    if (_isRecoveryFlushing) {
      _connectionSyncDeferredByRecovery = true;
      return;
    }
    if (_backupRootPath == null) return;
    final result = await ref.read(recoveryProvider.notifier).detectGaps();
    if (result == null || result.gaps.isEmpty || !mounted) return;
    await _loadDbStats(recordRealtimeEvents: false);
    final instantFill = await loadInstantFill();
    if ((instantFill || result.autoFill) && mounted) {
      FileLogService().log(
        '[Recovery] Auto-fill: starting immediately'
        '${result.autoFill ? ' (initial setup)' : ' (user preference)'}',
      );
      // Keep realtime stopped until recovery has finished reopening MAIN.
      // Starting db_backup_start while the flush owns app.db races its
      // close/reopen cycle and can leave the initial gaps scheduled.
      await ref.read(recoveryProvider.notifier).runFlushNow();
    }
  }

  void _tryStartRealtimeBackup() {
    final connection = ref.read(connectionProvider);
    final started = _realtimeBackup.tryStart(
      localDatabaseReady: _localBackupDbReady,
      controllerReady: connection != null && connection['state'] == 'ready',
    );
    FileLogService().log('[RealtimeBackup] tryStart: $started');
  }

  @override
  void initState() {
    super.initState();
    _connectionMonitor = ConnectionMonitorService(
      isControllerReady: () {
        final connection = ref.read(connectionProvider);
        return connection != null && connection['state'] == 'ready';
      },
    );
    _realtimeBackup = RealtimeBackupService();
    _databaseStatus = DatabaseStatusService(
      recoveryService: _recoveryService,
      isRealtimeActive: () => _realtimeActive,
      isControllerConnected: () => _connectionMonitor.effectiveConnected,
      addLogEntries: (entries) =>
          ref.read(backupLogProvider.notifier).addEntries(entries),
    );
    _init();
    _refreshTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _handleRefreshTick(),
    );
    // Probe after recovery metadata loads to avoid a false "no gap".
    _networkCheckTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _checkNetworkReachable(),
    );
  }

  // Recover a Windows sleep gap before recording the next heartbeat.
  Future<void> _handleRefreshTick() async {
    if (_refreshTickRunning) return;
    _refreshTickRunning = true;
    try {
      final now = DateTime.now();
      final previousTick = _lastRefreshTick;
      _lastRefreshTick = now;

      // Recovery owns the DB handles; skip stats and sleep detection.
      if (_isRecoveryFlushing) return;

      final elapsed = now.difference(previousTick);

      if (elapsed > const Duration(minutes: 2)) {
        FileLogService().log(
          '[Recovery] System timer pause detected (${elapsed.inMinutes}min); '
          'recovering from $previousTick',
        );
        await _recoveryService.onDisconnected(at: previousTick);
        _connectionMonitor.markDisconnected();
        _realtimeBackup.handleDisconnected();
        if (mounted) setState(() => _realtimeActive = false);
        await _checkNetworkReachable();
      } else if (_isEffectivelyConnected()) {
        await _recoveryService.recordHeartbeat(at: now);
      }

      await _loadDbStats();
      _maybeAutoFlush();
    } finally {
      _refreshTickRunning = false;
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _networkCheckTimer?.cancel();
    // Record disconnect time so the next launch can compute the gap correctly.
    _recoveryService.onDisconnected();
    super.dispose();
  }

  Future<void> _checkNetworkReachable() async {
    final update = await _connectionMonitor.checkNow();
    if (!mounted) return;
    if (update.networkReachable != _networkReachable) {
      setState(() => _networkReachable = update.networkReachable);
    }
    await _processConnectionUpdate(update);
  }

  bool _isEffectivelyConnected() => _connectionMonitor.effectiveConnected;

  // Apply the combined controller and OS reachability state once.
  Future<void> _syncEffectiveConnection() async {
    if (!mounted) return;

    if (_isRecoveryFlushing) {
      if (!_connectionSyncDeferredByRecovery) {
        _connectionSyncDeferredByRecovery = true;
        FileLogService().log(
          '[Recovery] Connection-state processing deferred during flush',
        );
      }
      return;
    }

    if (_connectionSyncDeferredByRecovery) {
      _connectionSyncDeferredByRecovery = false;
      FileLogService().log(
        '[Recovery] Processing deferred connection state after flush',
      );
    }

    await _processConnectionUpdate(_connectionMonitor.sync());
  }

  Future<void> _processConnectionUpdate(ConnectionMonitorUpdate update) async {
    if (!update.effectiveConnectionChanged) return;
    final effective = update.effectiveConnected;

    TrayService.instance.updateStatus(
      isConnected: effective,
      backupHealthy: effective && _realtimeActive,
    );

    if (effective) {
      FileLogService().log('[Connection] Reconnected to controller');
      await _runGapDetection();
      _tryStartRealtimeBackup();
    } else if (_realtimeBackup.isStarted) {
      _realtimeBackup.handleDisconnected();
      if (mounted) setState(() => _realtimeActive = false);
      FileLogService().log('[Connection] Disconnected from controller');
      await _recoveryService.onDisconnected();
    }
  }

  Future<void> _init() async {
    _currentMac =
        app.selectedController?['macaddr']?.toString() ??
        app.controllerList.keys.firstOrNull ??
        '';

    if (_currentMac.isNotEmpty) {
      ref.read(backupLogProvider.notifier).init(_currentMac);
    }

    // Missing backup files always return to initial setup.
    if (_currentMac.isNotEmpty) {
      final needsBackup = await InitialBackupScreen.needsInitialBackup(
        _currentMac,
      );
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
        // Start logging before recovery initialization.
        final safeMac = macToSafeFolderName(_currentMac);
        FileLogService().init(stored, safeMac: safeMac);
        // Recovery may redirect app.db to TEMP on resume.
        await _recoveryService.init(rootPath: stored, safeMac: safeMac);
        // Seed the schedule before attaching the recovery service.
        final recovTime = await loadRecoveryTime();
        ref
            .read(recoveryProvider.notifier)
            .setRecoveryTime(recovTime.hour, recovTime.minute);
        ref.read(recoveryProvider.notifier).attach(_recoveryService);

        // Recovery resumes interrupted work before MAIN opens.
        final ok = await _openReiriDb();
        if (!ok) return;
      }
    }
    if (mounted) {
      _localBackupDbReady = true;

      // Auto-login may already be ready, so synchronize once on startup.
      await _checkNetworkReachable();

      _tryStartRealtimeBackup();
    }
    await _loadDbStats();
  }

  Future<bool> _openReiriDb() async {
    if (app.db == null) {
      FileLogService().log('[ReiriDb] app.db is null; skipping DB init');
      return false;
    }
    await _recoveryService.openActiveRealtimeDb();
    FileLogService().log('[ReiriDb] Active recovery target opened');
    return true;
  }

  Future<void> _loadDbStats({bool recordRealtimeEvents = true}) async {
    final root = _backupRootPath;
    if (root == null || _currentMac.isEmpty) return;
    final snapshot = await _databaseStatus.load(
      backupRootPath: root,
      macAddress: _currentMac,
      recordRealtimeEvents: recordRealtimeEvents,
    );
    if (!mounted || snapshot == null) return;
    setState(() {
      _dbStats = snapshot.entries;
      _lastRealtimeEvent = snapshot.lastRealtimeEvent;
    });
  }

  void _handleManualRefresh() {
    if (_refreshCoolingDown) return;
    setState(() => _refreshCoolingDown = true);
    _checkNetworkReachable();
    _loadDbStats();
    Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _refreshCoolingDown = false);
    });
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
            title: Text(app.word('move_backup_data')),
            content: Text(
              '${app.word('move_backup_data_message')}\n\n$_backupRootPath',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(app.word('start_fresh')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(app.word('move_data')),
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

    final ok = await _openReiriDb();
    if (!ok) return;
    _localBackupDbReady = true;
    await _loadDbStats();
    if (mounted) _tryStartRealtimeBackup();
  }

  // Copy the controller folder when the backup root changes.
  Future<void> _migrateBackupData(
    String oldRoot,
    String newRoot,
    String safeMac,
  ) async {
    final src = Directory('$oldRoot\\$safeMac');
    if (!await src.exists()) return;
    final dst = Directory('$newRoot\\$safeMac');
    if (!await dst.exists()) await dst.create(recursive: true);
    await _copyDirRecursive(src, dst);
    FileLogService().log(
      '[Migrate] Copied backup data from $oldRoot to $newRoot',
    );
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
        title: Text(app.word('logout')),
        content: Text(app.word('logout_backup_warning')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(app.word('cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade600,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              // Persist the outage start before leaving.
              await _recoveryService.onDisconnected();
              app.logout();
              if (context.mounted) {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (_) => LoginScreen()),
                );
              }
            },
            child: Text(app.word('logout')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final connection = ref.watch(connectionProvider);
    final isConnected =
        connection != null &&
        connection['state'] == 'ready' &&
        _networkReachable;
    final mac = _currentMac.isNotEmpty ? _currentMac : 'N/A';
    final ctrlName =
        app.controllerList[mac]?['name']?.toString() ??
        app.word('fallback_controller_name');

    // Reconcile WebSocket changes with OS reachability.
    ref.listen(connectionProvider, (prev, next) => _syncEffectiveConnection());

    // Refresh dashboard state after a flush.
    ref.listen<RecoveryState>(recoveryProvider, (prev, next) async {
      if (prev != null &&
          prev.isFlushing &&
          !next.isFlushing &&
          next.backupState == BackupState.realtimeMain) {
        await _loadDbStats(recordRealtimeEvents: false);
        await _syncEffectiveConnection();
      }
    });

    // Observe the realtime backup command.
    ref.listen(communicationProvider(_realtimeBackup.command), (_, data) async {
      if (data == null) return;
      FileLogService().log(
        '[RealtimeBackup] Start response: ${data['result']}',
      );

      // ReiriController saves db_wr packets.
      // This listener handles the start ACK.
      if (mounted && _realtimeBackup.handleControllerResponse(data)) {
        setState(() => _realtimeActive = true);
        TrayService.instance.updateStatus(
          isConnected: _connectionMonitor.effectiveConnected,
          backupHealthy: _connectionMonitor.effectiveConnected,
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
            child: _buildTabContent(context, isConnected, mac, ctrlName),
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
        return DashboardView(
          dbStats: _dbStats,
          isConnected: isConnected,
          macAddr: mac,
          ctrlName: ctrlName,
          backupRootPath: _backupRootPath,
          onRefresh: _handleManualRefresh,
          refreshOnCooldown: _refreshCoolingDown,
          onGoToSettings: () => setState(() => _selected = _NavItem.settings),
          realtimeActive: _realtimeActive && _networkReachable,
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

/// Renders the home navigation and missing-data indicator.
class _Sidebar extends ConsumerWidget {
  final _NavItem selected;
  final ValueChanged<_NavItem> onSelect;

  const _Sidebar({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final themeMode = ref.watch(stringDataProvider('theme_mode'));
    final isDark =
        themeMode == 'dark' ||
        (themeMode != 'light' &&
            MediaQuery.of(context).platformBrightness == Brightness.dark);
    final hasMissingData = ref.watch(recoveryProvider).hasGaps;

    // Keep the logo readable without wasting space on narrow windows.
    final isWideScreen = MediaQuery.sizeOf(context).width >= 1400;
    final sidebarWidth = isWideScreen ? 220.0 : 170.0;

    return SizedBox(
      width: sidebarWidth,
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
                        text: isWideScreen ? 'Reiri ' : 'Reiri\n',
                        style: TextStyle(
                          color: cs.primary,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                      TextSpan(
                        text: 'DB Backup',
                        style: TextStyle(
                          color: cs.onSurface,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _NavTile(
                icon: Icons.dashboard_outlined,
                label: app.word('dashboard'),
                item: _NavItem.dashboard,
                selected: selected,
                onTap: onSelect,
              ),
              _NavTile(
                icon: Icons.restore_rounded,
                label: app.word('recovery'),
                item: _NavItem.recovery,
                selected: selected,
                onTap: onSelect,
                showDot: hasMissingData,
              ),
              _NavTile(
                icon: Icons.article_outlined,
                label: app.word('backup_log'),
                item: _NavItem.backupLog,
                selected: selected,
                onTap: onSelect,
              ),
              _NavTile(
                icon: Icons.settings_outlined,
                label: app.word('settings'),
                item: _NavItem.settings,
                selected: selected,
                onTap: onSelect,
              ),
              const Spacer(),
              ListTile(
                dense: true,
                minLeadingWidth: 20,
                leading: Icon(
                  isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                  size: 18,
                ),
                title: Text(
                  app.word(isDark ? 'light_mode' : 'dark_mode'),
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
                child: Text(
                  'v1.0.0',
                  style: TextStyle(fontSize: 11, color: cs.outlineVariant),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Displays one selectable destination in the home sidebar.
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
        child: Icon(
          icon,
          size: 18,
          color: isActive ? cs.primary : cs.onSurfaceVariant,
        ),
      ),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          color: isActive ? cs.primary : cs.onSurfaceVariant,
          fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      onTap: () => onTap(item),
    );
  }
}
