import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reiri_db_backup_tool/model/backup_log_entry.dart';
import 'package:reiri_db_backup_tool/provider/backup_log_provider.dart';

const _kAllDbNames = [
  'history.db',
  'meter.db',
  'optime.db',
  'ppd.db',
  'trend.db',
];

class BackupLogView extends ConsumerStatefulWidget {
  final String macAddr;

  /// Full path to the current controller folder (e.g. `C:\backup\AA-BB-CC...`).
  /// When set, the CSV save dialog opens here by default.
  final String? backupPath;

  const BackupLogView({super.key, required this.macAddr, this.backupPath});

  @override
  ConsumerState<BackupLogView> createState() => _BackupLogViewState();
}

const _kDisplayCap = 100000;
const _kPageSize = 20;

class _BackupLogViewState extends ConsumerState<BackupLogView> {
  BackupLogType? _typeFilter;
  BackupLogResult? _resultFilter;
  String? _dbFilter;
  int _shownCount = _kPageSize;

  List<BackupLogEntry> _applyFilters(List<BackupLogEntry> entries) {
    return entries.where((e) {
      if (_typeFilter != null && e.type != _typeFilter) return false;
      if (_resultFilter != null && e.result != _resultFilter) return false;
      if (_dbFilter != null && e.database != _dbFilter) return false;
      return true;
    }).take(_kDisplayCap).toList();
  }

  void _resetShown() => _shownCount = _kPageSize;

  Future<void> _exportCsv(List<BackupLogEntry> entries) async {
    final location = await getSaveLocation(
      suggestedName: 'backup_log.csv',
      initialDirectory: widget.backupPath,
      acceptedTypeGroups: [
        const XTypeGroup(label: 'CSV', extensions: ['csv']),
      ],
    );
    if (location == null) return;

    String csvCell(String v) {
      if (v.contains(',') || v.contains('"') || v.contains('\n')) {
        return '"${v.replaceAll('"', '""')}"';
      }
      return v;
    }

    String csvRow(List<String> cols) =>
        cols.map(csvCell).join(',');

    final buf = StringBuffer();
    buf.writeln(csvRow(['Backed Up At', 'Record Time', 'Type', 'Result', 'Database', 'Details']));
    for (final e in entries) {
      buf.writeln(csvRow([
        e.backedUpAt != null ? _fmtDateTime(e.backedUpAt!) : '',
        _fmtDateTime(e.timestamp),
        e.type == BackupLogType.realtime ? 'Real-time' : 'Recovery',
        e.result == BackupLogResult.success ? 'Success' : 'Fail',
        e.database,
        e.details ?? '',
      ]));
    }

    var savePath = location.path;
    if (!savePath.toLowerCase().endsWith('.csv')) savePath = '$savePath.csv';
    await File(savePath).writeAsString(buf.toString());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final all = ref.watch(backupLogProvider);
    final filtered = _applyFilters(all);
    final shown = filtered.take(_shownCount).toList();
    final hasMore = shown.length < filtered.length;

    return ColoredBox(
      color: cs.surfaceContainerLowest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: Text(
              'Backup Log',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 2, 24, 0),
            child: Text(
              'Full history of all backup and recovery events',
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
          ),
          // ── Filter row 1: Type + Result + Export ──────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
            child: Row(
              children: [
                _filterLabel(context, 'TYPE'),
                const SizedBox(width: 8),
                _FilterPill(
                    label: 'All',
                    selected: _typeFilter == null,
                    onTap: () => setState(() {
                          _typeFilter = null;
                          _resetShown();
                        })),
                const SizedBox(width: 4),
                _FilterPill(
                    label: 'Real-time',
                    selected: _typeFilter == BackupLogType.realtime,
                    onTap: () => setState(() {
                          _typeFilter = BackupLogType.realtime;
                          _resetShown();
                        })),
                const SizedBox(width: 4),
                _FilterPill(
                    label: 'Recovery',
                    selected: _typeFilter == BackupLogType.recovery,
                    onTap: () => setState(() {
                          _typeFilter = BackupLogType.recovery;
                          _resetShown();
                        })),
                const SizedBox(width: 20),
                _filterLabel(context, 'RESULT'),
                const SizedBox(width: 8),
                _FilterPill(
                    label: 'All',
                    selected: _resultFilter == null,
                    onTap: () => setState(() {
                          _resultFilter = null;
                          _resetShown();
                        })),
                const SizedBox(width: 4),
                _FilterPill(
                    label: 'Success',
                    selected: _resultFilter == BackupLogResult.success,
                    onTap: () => setState(() {
                          _resultFilter = BackupLogResult.success;
                          _resetShown();
                        })),
                const SizedBox(width: 4),
                _FilterPill(
                    label: 'Fail',
                    selected: _resultFilter == BackupLogResult.fail,
                    onTap: () => setState(() {
                          _resultFilter = BackupLogResult.fail;
                          _resetShown();
                        })),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed:
                      filtered.isEmpty ? null : () => _exportCsv(filtered),
                  icon: const Icon(Icons.download_rounded, size: 15),
                  label: const Text('Export CSV'),
                  style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact).copyWith(
                    mouseCursor: WidgetStateProperty.resolveWith((s) =>
                        s.contains(WidgetState.disabled)
                            ? SystemMouseCursors.basic
                            : SystemMouseCursors.click),
                  ),
                ),
              ],
            ),
          ),
          // ── Filter row 2: Database ────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Row(
              children: [
                _filterLabel(context, 'DATABASE'),
                const SizedBox(width: 8),
                _FilterPill(
                    label: 'All',
                    selected: _dbFilter == null,
                    onTap: () => setState(() {
                          _dbFilter = null;
                          _resetShown();
                        })),
                const SizedBox(width: 4),
                ..._kAllDbNames.map((db) {
                  final short = db.replaceAll('.db', '');
                  return Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: _FilterPill(
                        label: short,
                        selected: _dbFilter == db,
                        onTap: () => setState(() {
                              _dbFilter = db;
                              _resetShown();
                            })),
                  );
                }),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: cs.outlineVariant),
                ),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
                      child: Row(
                        children: [
                          _logHeaderCell(context, 'BACKED UP AT', flex: 20),
                          _logHeaderCell(context, 'RECORD TIME', flex: 20),
                          _logHeaderCell(context, 'TYPE', flex: 15),
                          _logHeaderCell(context, 'RESULT', flex: 15),
                          _logHeaderCell(context, 'DATABASE', flex: 30),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: filtered.isEmpty
                          ? Center(
                              child: Text(
                                'No log entries yet',
                                style: TextStyle(
                                    color: cs.onSurfaceVariant, fontSize: 13),
                              ),
                            )
                          : ListView.builder(
                              itemCount: shown.length + (hasMore ? 1 : 0),
                              itemBuilder: (ctx, i) {
                                if (i == shown.length) {
                                  return Center(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 12),
                                      child: TextButton(
                                        onPressed: () => setState(
                                            () => _shownCount += _kPageSize),
                                        style: const ButtonStyle(
                                          mouseCursor: WidgetStatePropertyAll(
                                              SystemMouseCursors.click),
                                        ),
                                        child: const Text('Load More'),
                                      ),
                                    ),
                                  );
                                }
                                return _LogRow(entry: shown[i]);
                              },
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

  Widget _filterLabel(BuildContext context, String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        letterSpacing: 0.6,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w500,
      ),
    );
  }

  Widget _logHeaderCell(BuildContext context, String text, {required int flex}) {
    return Expanded(
      flex: flex,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          letterSpacing: 0.6,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FilterPill(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      mouseCursor: SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? cs.primaryContainer.withValues(alpha: 0.5)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected
                ? cs.primary.withValues(alpha: 0.5)
                : cs.outlineVariant,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: selected ? cs.primary : cs.onSurfaceVariant,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  final BackupLogEntry entry;
  const _LogRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isRealtime = entry.type == BackupLogType.realtime;
    final isSuccess = entry.result == BackupLogResult.success;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        border: Border(
            bottom:
                BorderSide(color: cs.outlineVariant.withValues(alpha: 0.4))),
      ),
      child: Row(
        children: [
          Expanded(
              flex: 20,
              child: Text(
                  entry.backedUpAt != null
                      ? _fmtDateTime(entry.backedUpAt!)
                      : '—',
                  style: TextStyle(
                      fontSize: 13,
                      color: entry.backedUpAt != null ? null : Colors.grey))),
          Expanded(
              flex: 20,
              child: Text(_fmtDateTime(entry.timestamp),
                  style: const TextStyle(fontSize: 13))),
          Expanded(
            flex: 15,
            child: _LogBadge(
              label: isRealtime ? 'Real-time' : 'Recovery',
              color: isRealtime ? Colors.cyan.shade700 : Colors.orange.shade700,
              bg: isRealtime ? Colors.cyan.shade50 : Colors.orange.shade50,
              border:
                  isRealtime ? Colors.cyan.shade200 : Colors.orange.shade200,
            ),
          ),
          Expanded(
            flex: 15,
            child: _LogBadge(
              label: isSuccess ? 'Success' : 'Fail',
              color: isSuccess ? Colors.green.shade700 : Colors.red.shade700,
              bg: isSuccess ? Colors.green.shade50 : Colors.red.shade50,
              border: isSuccess ? Colors.green.shade200 : Colors.red.shade200,
            ),
          ),
          Expanded(
              flex: 30,
              child: Text(entry.database,
                  style: const TextStyle(
                      fontSize: 13, fontFamily: 'monospace'))),
        ],
      ),
    );
  }
}

class _LogBadge extends StatelessWidget {
  final String label;
  final Color color;
  final Color bg;
  final Color border;

  const _LogBadge(
      {required this.label,
      required this.color,
      required this.bg,
      required this.border});

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: border),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12, color: color, fontWeight: FontWeight.w500)),
      ),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

String _fmtDateTime(DateTime dt) {
  final d = dt.day.toString().padLeft(2, '0');
  final mon = _kMonths[dt.month - 1];
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  final s = dt.second.toString().padLeft(2, '0');
  return '$d $mon $h:$m:$s';
}

const _kMonths = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];
