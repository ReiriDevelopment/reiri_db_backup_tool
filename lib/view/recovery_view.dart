import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:reiri_db_backup_tool/lib/date_time_utils.dart';
import 'package:reiri_db_backup_tool/model/backup_metadata.dart';
import 'package:reiri_db_backup_tool/provider/recovery_provider.dart';

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
                        'Recovery',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Detect and recover missing record periods from the controller',
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                _ScanButton(state: state),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // ── Status banner when TEMP DB is active ────────────────────────────
          // if (state.backupState == BackupState.realtimeTemp)
          //   Padding(
          //     padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          //     child: _TempDbBanner(isFlushing: state.isFlushing, ref: ref),
          //   ),

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

class _ScanButton extends ConsumerWidget {
  final RecoveryState state;
  const _ScanButton({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FilledButton.icon(
      onPressed: state.isScanning
          ? null
          : () => ref.read(recoveryProvider.notifier).scanForGaps(),
      icon: state.isScanning
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.search_rounded, size: 16),
      label: Text(state.isScanning ? 'Scanning...' : 'Scan for Gaps'),
      style:
          FilledButton.styleFrom(
            backgroundColor: const Color(0xFF0BAEC7),
            foregroundColor: Colors.white,
            visualDensity: VisualDensity.compact,
          ).copyWith(
            mouseCursor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.disabled)
                  ? SystemMouseCursors.basic
                  : SystemMouseCursors.click,
            ),
          ),
    );
  }
}

// ── Gap table ─────────────────────────────────────────────────────────────────

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
          Expanded(flex: 22, child: Text('DATABASE', style: style)),
          Expanded(
            flex: 38,
            child: Text('MISSING RECORD PERIOD', style: style),
          ),
          Expanded(flex: 16, child: Text('DURATION', style: style)),
          Expanded(
            flex: 24,
            child: Text('SCHEDULED', style: style, textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }
}

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
      durationLabel = '${dur.inDays} days';
      chipColor = Colors.red.shade600;
    } else if (dur.inDays >= 1) {
      durationLabel = '${dur.inDays} ${dur.inDays == 1 ? "day" : "days"}';
      chipColor = Colors.orange.shade600;
    } else if (dur.inHours >= 1) {
      durationLabel = '${dur.inHours}h ${dur.inMinutes.remainder(60)}m';
      chipColor = Colors.amber.shade700;
    } else {
      durationLabel = dur.inMinutes == 0 ? '<1m' : '${dur.inMinutes}m';
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
              'Recovering missing data',
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
            isMain ? 'No missing data detected' : 'No gaps found',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isMain
                ? 'All databases are up to date. Real-time backup is active.'
                : 'Press "Scan for Gaps" to check for missing records.',
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
