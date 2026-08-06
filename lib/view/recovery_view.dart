// File purpose: Displays detected backup gaps and recovery progress controls.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reiri_app_core/reiri_app_core.dart';

import 'package:reiri_db_backup_tool/lib/date_time_utils.dart';
import 'package:reiri_db_backup_tool/model/backup_metadata.dart';
import 'package:reiri_db_backup_tool/provider/recovery_provider.dart';

/// Displays detected database gaps and current recovery progress.
class RecoveryView extends ConsumerWidget {
  const RecoveryView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final state = ref.watch(recoveryProvider);

    return ColoredBox(
      color: cs.surfaceContainerLowest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ─────────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        app.word('recovery'),
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        app.word('recovery_subtitle'),
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // ── Gap table / loading overlay / empty state ───────────────────────
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: state.isFlushing
                  ? _FlushingOverlay(step: state.flushStep)
                  : state.hasGaps
                  ? _GapTable(
                      periods: state.gapPeriods,
                      scheduledAt: state.scheduledAt,
                    )
                  : _EmptyState(backupState: state.backupState),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Scan button ───────────────────────────────────────────────────────────────

// ── Gap table ─────────────────────────────────────────────────────────────────

/// Displays missing database periods in a structured table.
class _GapTable extends StatelessWidget {
  final List<GapRange> periods;
  final DateTime? scheduledAt;
  const _GapTable({required this.periods, required this.scheduledAt});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: Column(
        children: [
          _GapTableHeader(),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: periods.length,
              itemBuilder: (_, i) =>
                  _GapRow(gap: periods[i], scheduledAt: scheduledAt),
            ),
          ),
        ],
      ),
    );
  }
}

/// Renders column labels for the missing-period table.
class _GapTableHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 11,
      letterSpacing: 0.6,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w500,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
      child: Row(
        children: [
          Expanded(
            flex: 22,
            child: Text(app.word('table_database'), style: style),
          ),
          Expanded(
            flex: 38,
            child: Text(app.word('table_missing_record_period'), style: style),
          ),
          Expanded(flex: 16, child: Text(app.word('duration'), style: style)),
          Expanded(
            flex: 24,
            child: Text(
              app.word('scheduled'),
              style: style,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}

/// Displays one missing database period and its recovery schedule.
class _GapRow extends StatelessWidget {
  final GapRange gap;
  final DateTime? scheduledAt;
  const _GapRow({required this.gap, required this.scheduledAt});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dur = gap.duration;
    final String durationLabel;
    final Color chipColor;
    if (dur.inDays >= 3) {
      durationLabel = '${dur.inDays} ${app.word('days')}';
      chipColor = Colors.red.shade600;
    } else if (dur.inDays >= 1) {
      durationLabel =
          '${dur.inDays} ${app.word(dur.inDays == 1 ? 'day' : 'days')}';
      chipColor = Colors.orange.shade600;
    } else if (dur.inHours >= 1) {
      durationLabel =
          '${dur.inHours}${app.word('duration_hours')} '
          '${dur.inMinutes.remainder(60)}${app.word('duration_minutes')}';
      chipColor = Colors.amber.shade700;
    } else {
      durationLabel = dur.inMinutes == 0
          ? '<1${app.word('duration_minutes')}'
          : '${dur.inMinutes}${app.word('duration_minutes')}';
      chipColor = Colors.amber.shade700;
    }

    final scheduleLabel = scheduledAt != null
        ? formatScheduledDateTime(scheduledAt!)
        : '—';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
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
              gap.dbFile,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            flex: 38,
            child: Text(
              '${formatDateTime(gap.start)} – ${formatDateTime(gap.end)}',
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
            ),
          ),
          Expanded(
            flex: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: chipColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: chipColor.withValues(alpha: 0.3)),
              ),
              child: Text(
                durationLabel,
                style: TextStyle(
                  fontSize: 12,
                  color: chipColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          Expanded(
            flex: 24,
            child: Text(
              scheduleLabel,
              style: TextStyle(
                fontSize: 13,
                fontFamily: 'monospace',
                color: cs.onSurfaceVariant,
              ),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Flushing overlay ──────────────────────────────────────────────────────────

/// Blocks recovery controls while showing the active flush step.
class _FlushingOverlay extends StatelessWidget {
  final String? step;
  const _FlushingOverlay({this.step});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: const Color(0xFF0BAEC7),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              app.word('recovering_missing_data'),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            if (step != null) ...[
              const SizedBox(height: 8),
              Text(
                step!,
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

/// Explains whether recovery is clear or has not been scanned yet.
class _EmptyState extends StatelessWidget {
  final BackupState backupState;
  const _EmptyState({required this.backupState});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isMain = backupState == BackupState.realtimeMain;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isMain ? Icons.check_circle_outline_rounded : Icons.restore_rounded,
            size: 48,
            color: isMain ? Colors.green.shade400 : cs.outlineVariant,
          ),
          const SizedBox(height: 16),
          Text(
            app.word(isMain ? 'no_missing_data_detected' : 'no_gaps_found'),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isMain
                ? app.word('all_databases_up_to_date')
                : app.word('recovery_subtitle'),
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
