// File purpose: Displays, filters, paginates, and exports backup log entries.

import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reiri_app_core/reiri_app_core.dart';
import 'package:reiri_db_backup_tool/lib/date_time_utils.dart';
import 'package:reiri_db_backup_tool/model/backup_database.dart';
import 'package:reiri_db_backup_tool/model/backup_log_entry.dart';
import 'package:reiri_db_backup_tool/provider/backup_log_provider.dart';

final _kAllDbNames = const [
  BackupDatabase.history,
  BackupDatabase.meter,
  BackupDatabase.optime,
  BackupDatabase.ppd,
  BackupDatabase.trend,
].map((database) => database.fileName).toList(growable: false);

/// Displays searchable backup activity and supports log export.
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

/// Manages backup-log filters, pagination, selection, and export actions.
class _BackupLogViewState extends ConsumerState<BackupLogView> {
  BackupLogType? _typeFilter;
  String? _dbFilter;
  int _shownCount = _kPageSize;

  /// Applies type, result, date-range, and text filters to the full log list.
  List<BackupLogEntry> _applyFilters(List<BackupLogEntry> entries) {
    return entries
        .where((e) {
          // Legacy failures came from interval-based verification. The backup
          // history now contains confirmed database-write events only.
          if (e.result != BackupLogResult.success) return false;
          if (_typeFilter != null && e.type != _typeFilter) return false;
          if (_dbFilter != null && e.database != _dbFilter) return false;
          return true;
        })
        .take(_kDisplayCap)
        .toList();
  }

  void _resetShown() => _shownCount = _kPageSize;

  /// Writes the currently filtered entries to a user-selected CSV file.
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

    String csvRow(List<String> cols) => cols.map(csvCell).join(',');

    final buf = StringBuffer();
    buf.writeln(
      csvRow(['Backed Up At', 'Record Time', 'Type', 'Database', 'Details']),
    );
    for (final e in entries) {
      buf.writeln(
        csvRow([
          e.backedUpAt != null
              ? formatDateTime(e.backedUpAt!, includeSeconds: true)
              : '',
          formatDateTime(e.timestamp, includeSeconds: true),
          e.type == BackupLogType.realtime ? 'Real-time' : 'Recovery',
          e.database,
          e.details ?? '',
        ]),
      );
    }

    var savePath = location.path;
    if (!savePath.toLowerCase().endsWith('.csv')) savePath = '$savePath.csv';
    await File(savePath).writeAsString(buf.toString());
  }

  /// Writes the currently filtered entries to a user-selected JSON file.
  Future<void> _exportJson(List<BackupLogEntry> entries) async {
    final location = await getSaveLocation(
      suggestedName: 'backup_log.json',
      initialDirectory: widget.backupPath,
      acceptedTypeGroups: [
        const XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    if (location == null) return;

    final exportedEntries = entries.map((entry) {
      final json = entry.toJson();
      json.remove('result');
      return json;
    }).toList();
    final json = const JsonEncoder.withIndent('  ').convert(exportedEntries);

    var savePath = location.path;
    if (!savePath.toLowerCase().endsWith('.json')) savePath = '$savePath.json';
    await File(savePath).writeAsString(json);
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
              app.word('backup_log'),
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 2, 24, 0),
            child: Text(
              app.word('backup_log_subtitle'),
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
          ),
          // ── Filter row 1: Type + Export ───────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
            child: Row(
              children: [
                _filterLabel(context, app.word('filter_type')),
                const SizedBox(width: 8),
                _FilterPill(
                  label: app.word('all'),
                  selected: _typeFilter == null,
                  onTap: () => setState(() {
                    _typeFilter = null;
                    _resetShown();
                  }),
                ),
                const SizedBox(width: 4),
                _FilterPill(
                  label: app.word('realtime'),
                  selected: _typeFilter == BackupLogType.realtime,
                  onTap: () => setState(() {
                    _typeFilter = BackupLogType.realtime;
                    _resetShown();
                  }),
                ),
                const SizedBox(width: 4),
                _FilterPill(
                  label: app.word('recovery'),
                  selected: _typeFilter == BackupLogType.recovery,
                  onTap: () => setState(() {
                    _typeFilter = BackupLogType.recovery;
                    _resetShown();
                  }),
                ),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: filtered.isEmpty
                      ? null
                      : () => _exportJson(filtered),
                  icon: const Icon(Icons.data_object_rounded, size: 15),
                  label: Text(app.word('export_json')),
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
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: filtered.isEmpty
                      ? null
                      : () => _exportCsv(filtered),
                  icon: const Icon(Icons.download_rounded, size: 15),
                  label: Text(app.word('export_csv')),
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
              ],
            ),
          ),
          // ── Filter row 2: Database ────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Row(
              children: [
                _filterLabel(context, app.word('table_database')),
                const SizedBox(width: 8),
                _FilterPill(
                  label: app.word('all'),
                  selected: _dbFilter == null,
                  onTap: () => setState(() {
                    _dbFilter = null;
                    _resetShown();
                  }),
                ),
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
                      }),
                    ),
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
                          _logHeaderCell(
                            context,
                            app.word('log_backed_up_at'),
                            flex: 20,
                          ),
                          _logHeaderCell(
                            context,
                            app.word('log_record_time'),
                            flex: 20,
                          ),
                          _logHeaderCell(
                            context,
                            app.word('filter_type'),
                            flex: 20,
                          ),
                          _logHeaderCell(
                            context,
                            app.word('table_database'),
                            flex: 40,
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: filtered.isEmpty
                          ? Center(
                              child: Text(
                                app.word('no_log_entries'),
                                style: TextStyle(
                                  color: cs.onSurfaceVariant,
                                  fontSize: 13,
                                ),
                              ),
                            )
                          : ListView.builder(
                              itemCount: shown.length + (hasMore ? 1 : 0),
                              itemBuilder: (ctx, i) {
                                if (i == shown.length) {
                                  return Center(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
                                      child: TextButton(
                                        onPressed: () => setState(
                                          () => _shownCount += _kPageSize,
                                        ),
                                        style: const ButtonStyle(
                                          mouseCursor: WidgetStatePropertyAll(
                                            SystemMouseCursors.click,
                                          ),
                                        ),
                                        child: Text(app.word('load_more')),
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

  Widget _logHeaderCell(
    BuildContext context,
    String text, {
    required int flex,
  }) {
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

/// Renders a compact selectable backup-log filter.
class _FilterPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FilterPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

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

/// Displays one backup log entry as a table row.
class _LogRow extends StatelessWidget {
  final BackupLogEntry entry;
  const _LogRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isRealtime = entry.type == BackupLogType.realtime;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.4)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 20,
            child: Text(
              entry.backedUpAt != null
                  ? formatDateTime(entry.backedUpAt!, includeSeconds: true)
                  : '—',
              style: TextStyle(
                fontSize: 13,
                color: entry.backedUpAt != null ? null : Colors.grey,
              ),
            ),
          ),
          Expanded(
            flex: 20,
            child: Text(
              formatDateTime(entry.timestamp, includeSeconds: true),
              style: const TextStyle(fontSize: 13),
            ),
          ),
          Expanded(
            flex: 20,
            child: _LogBadge(
              label: app.word(isRealtime ? 'realtime' : 'recovery'),
              color: isRealtime ? Colors.cyan.shade700 : Colors.orange.shade700,
              bg: isRealtime ? Colors.cyan.shade50 : Colors.orange.shade50,
              border: isRealtime
                  ? Colors.cyan.shade200
                  : Colors.orange.shade200,
            ),
          ),
          Expanded(
            flex: 40,
            child: Text(
              entry.database,
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Displays the source type of a backup log entry.
class _LogBadge extends StatelessWidget {
  final String label;
  final Color color;
  final Color bg;
  final Color border;

  const _LogBadge({
    required this.label,
    required this.color,
    required this.bg,
    required this.border,
  });

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
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: color,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
