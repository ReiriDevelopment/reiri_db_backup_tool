// File purpose: Presents controller, database, and real-time backup status summaries.

import 'package:flutter/material.dart';
import 'package:reiri_app_core/reiri_app_core.dart';
import 'package:reiri_db_backup_tool/lib/date_time_utils.dart';
import 'package:reiri_db_backup_tool/service/database_status_service.dart';

/// Presents controller connectivity, database health, and real-time status.
class DashboardView extends StatelessWidget {
  final List<DatabaseStatEntry> dbStats;
  final bool isConnected;
  final String macAddr;
  final String ctrlName;
  final String? backupRootPath;
  final VoidCallback onRefresh;
  final bool refreshOnCooldown;
  final VoidCallback onGoToSettings;
  final bool realtimeActive;
  final DateTime? lastRealtimeEvent;

  const DashboardView({
    super.key,
    required this.dbStats,
    required this.isConnected,
    required this.macAddr,
    required this.ctrlName,
    required this.backupRootPath,
    required this.onRefresh,
    required this.refreshOnCooldown,
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
                app.word('dashboard'),
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                app.word('dashboard_subtitle'),
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              _ControllerCard(
                isConnected: isConnected,
                macAddr: macAddr,
                ctrlName: ctrlName,
                onRefresh: onRefresh,
                refreshOnCooldown: refreshOnCooldown,
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

/// Prompts the user to configure a backup directory.
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
          Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: Colors.orange.shade700,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              app.word('backup_directory_not_configured'),
              style: TextStyle(fontSize: 13, color: Colors.orange.shade800),
            ),
          ),
          TextButton(
            onPressed: onGoToSettings,
            style:
                TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  visualDensity: VisualDensity.compact,
                  foregroundColor: Colors.orange.shade800,
                ).copyWith(
                  mouseCursor: const WidgetStatePropertyAll(
                    SystemMouseCursors.click,
                  ),
                ),
            child: Text(
              app.word('go_to_settings'),
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Summarizes the selected controller and its connection state.
class _ControllerCard extends StatelessWidget {
  final bool isConnected;
  final String macAddr;
  final String ctrlName;
  final VoidCallback onRefresh;
  final bool refreshOnCooldown;

  const _ControllerCard({
    required this.isConnected,
    required this.macAddr,
    required this.ctrlName,
    required this.onRefresh,
    required this.refreshOnCooldown,
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
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.router_outlined, color: cs.secondary),
            ),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ctrlName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                Text(
                  '${app.word('mac_address')}: $macAddr',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                ),
              ],
            ),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: refreshOnCooldown ? null : onRefresh,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: Text(
                app.word(refreshOnCooldown ? 'refreshed' : 'refresh'),
              ),
              style:
                  OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ).copyWith(
                    mouseCursor: WidgetStateProperty.resolveWith(
                      (s) => s.contains(WidgetState.disabled)
                          ? SystemMouseCursors.basic
                          : SystemMouseCursors.click,
                    ),
                  ),
            ),
            const SizedBox(width: 16),
            Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 9,
                  color: isConnected ? Colors.green : Colors.red,
                ),
                const SizedBox(width: 6),
                Text(
                  app.word(isConnected ? 'connected' : 'disconnected'),
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

/// Displays synchronization status for all monitored databases.
class _DatabaseStatusCard extends StatelessWidget {
  final List<DatabaseStatEntry> dbStats;
  const _DatabaseStatusCard({required this.dbStats});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final rows = dbStats.isEmpty ? DatabaseStatusService.emptyEntries : dbStats;

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
            Text(
              app.word('database_status'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
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

/// Renders column labels for the database status table.
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
          Expanded(
            flex: 22,
            child: Text(app.word('table_database'), style: style),
          ),
          Expanded(
            flex: 28,
            child: Text(app.word('table_description'), style: style),
          ),
          Expanded(
            flex: 20,
            child: Text(app.word('table_last_backup'), style: style),
          ),
          Expanded(
            flex: 16,
            child: Text(
              app.word('table_status'),
              style: style,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}

/// Displays the latest backup information for one database.
class _TableRow extends StatelessWidget {
  final DatabaseStatEntry db;
  const _TableRow({required this.db});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isNotFound = db.status == DatabaseSyncStatus.notFound;
    final isDelayed = db.status == DatabaseSyncStatus.delayed;

    final Color badgeBg;
    final Color badgeBorder;
    final Color badgeText;
    final String badgeLabel;
    IconData? badgeIcon;

    if (isNotFound) {
      badgeBg = cs.surfaceContainerHigh;
      badgeBorder = cs.outlineVariant;
      badgeText = cs.onSurfaceVariant;
      badgeLabel = app.word('not_found');
      badgeIcon = null;
    } else if (isDelayed) {
      badgeBg = Colors.orange.shade50;
      badgeBorder = Colors.orange.shade200;
      badgeText = Colors.orange.shade700;
      badgeLabel = app.word('delayed');
      badgeIcon = Icons.warning_amber_rounded;
    } else if (db.status == DatabaseSyncStatus.missingDisconnected) {
      badgeBg = Colors.red.shade50;
      badgeBorder = Colors.red.shade200;
      badgeText = Colors.red.shade700;
      badgeLabel = app.word('not_synced');
      badgeIcon = Icons.close_rounded;
    } else if (db.status == DatabaseSyncStatus.missingScheduled) {
      badgeBg = Colors.blue.shade50;
      badgeBorder = Colors.blue.shade200;
      badgeText = Colors.blue.shade700;
      badgeLabel = app.word('scheduled_to_sync');
      badgeIcon = Icons.sync_rounded;
    } else {
      badgeBg = Colors.green.shade50;
      badgeBorder = Colors.green.shade200;
      badgeText = Colors.green.shade700;
      badgeLabel = app.word('synced');
      badgeIcon = Icons.check_rounded;
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.4)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 22,
            child: Text(
              db.filename,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            flex: 28,
            child: Text(
              app.word(db.descriptionKey),
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
          ),
          Expanded(
            flex: 20,
            child: db.lastBackup != null
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        formatDateTime(db.lastBackup!),
                        style: const TextStyle(fontSize: 13),
                      ),
                      Text(
                        _fmtAgo(db.lastBackup!),
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  )
                : const Text('—', style: TextStyle(fontSize: 13)),
          ),
          Expanded(
            flex: 16,
            child: Align(
              alignment: Alignment.centerRight,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
                    Text(
                      badgeLabel,
                      style: TextStyle(
                        fontSize: 12,
                        color: badgeText,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
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

/// Shows whether real-time backup is active and when it last received data.
class _RealtimeBackupCard extends StatelessWidget {
  final bool isActive;
  final DateTime? lastEvent;

  const _RealtimeBackupCard({required this.isActive, required this.lastEvent});

  String _lastEventLabel() {
    if (lastEvent == null) return app.word('no_events_yet');
    return _fmtAgo(lastEvent!);
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
            Text(
              app.word('realtime_backup'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 9,
                  color: isActive ? Colors.green : cs.outlineVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  app.word(isActive ? 'active' : 'waiting_for_connection'),
                  style: TextStyle(
                    color: isActive ? Colors.green : cs.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                    fontSize: 13,
                  ),
                ),
                if (isActive)
                  Text(
                    ' — ${app.word('appending_new_records')}',
                    style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                  ),
                const Spacer(),
                if (isActive)
                  Text(
                    '${app.word('last_event')}: ${_lastEventLabel()}',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _fmtAgo(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inSeconds < 60) {
    return '${diff.inSeconds}${app.word('duration_seconds')} '
        '${app.word('ago')}';
  }
  if (diff.inMinutes < 60) {
    return '${diff.inMinutes}${app.word('duration_minutes')} '
        '${app.word('ago')}';
  }
  if (diff.inHours < 24) {
    return '${diff.inHours}${app.word('duration_hours')} ${app.word('ago')}';
  }
  return '${diff.inDays}${app.word('duration_days_short')} ${app.word('ago')}';
}
