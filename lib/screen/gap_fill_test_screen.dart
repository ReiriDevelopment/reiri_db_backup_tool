import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reiri_app_core/reiri_app_core.dart';

import 'package:reiri_db_backup_tool/model/backup_metadata.dart';
import 'package:reiri_db_backup_tool/provider/recovery_provider.dart';

// ─── Screen ───────────────────────────────────────────────────────────────────

class GapFillTestScreen extends ConsumerStatefulWidget {
  const GapFillTestScreen({super.key});

  @override
  ConsumerState<GapFillTestScreen> createState() => _GapFillTestScreenState();
}

class _GapFillTestScreenState extends ConsumerState<GapFillTestScreen> {
  // One DbAccess instance per db type so each has its own communicationProvider.
  final _cmds = {
    'meter':   DbAccess(),
    'optime':  DbAccess(),
    'trend':   DbAccess(),
    'ppd':     DbAccess(),
    'history': DbAccess(),
  };

  static const _dbTypes = ['meter', 'optime', 'trend', 'ppd', 'history'];

  String _selectedDb = 'meter';

  // Custom range (falls back to first detected gap when null).
  DateTime? _customFrom;
  DateTime? _customTo;

  final Map<String, _FetchResult> _results = {};
  final Map<String, bool> _loading = {};

  DbAccess get _activeCmd => _cmds[_selectedDb]!;

  // ── helpers ──────────────────────────────────────────────────────────────

  (DateTime, DateTime)? _resolveRange() {
    if (_customFrom != null && _customTo != null) {
      return (_customFrom!, _customTo!);
    }
    final gaps = ref.read(recoveryProvider).gaps;
    if (gaps.isEmpty) return null;
    // Merge all gaps into a single bounding window.
    DateTime from = gaps.first.start;
    DateTime to = gaps.first.end;
    for (final g in gaps) {
      if (g.start.isBefore(from)) from = g.start;
      if (g.end.isAfter(to)) to = g.end;
    }
    return (from, to);
  }

  void _fetch(String dbType) {
    final range = _resolveRange();
    if (range == null) {
      setState(() {
        _results[dbType] = _FetchResult.error('No gap detected and no custom range set.');
      });
      return;
    }
    final cmd = _cmds[dbType]!;
    final ok = cmd.dbBackup(dbType, range.$1, range.$2);
    if (!ok) {
      setState(() {
        _results[dbType] = _FetchResult.error('Command is locked (previous request in progress).');
      });
      return;
    }
    setState(() {
      _loading[dbType] = true;
      _results[dbType] = _FetchResult.pending(range.$1, range.$2);
    });
    app.requestController(cmd);
  }

  void _fetchAll() {
    for (final db in _dbTypes) {
      _fetch(db);
    }
  }

  Future<void> _pickDateTime(bool isFrom) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now.subtract(const Duration(days: 1)),
      firstDate: DateTime(2020),
      lastDate: now,
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: isFrom ? 0 : 23, minute: isFrom ? 0 : 59),
    );
    if (time == null || !mounted) return;
    final dt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    setState(() {
      if (isFrom) _customFrom = dt; else _customTo = dt;
    });
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // Listen to each command's provider.
    for (final db in _dbTypes) {
      final cmd = _cmds[db]!;
      ref.listen(communicationProvider(cmd), (_, data) {
        if (data == null) return;
        setState(() {
          _loading[db] = false;
          final result = data['result'] as String? ?? '?';
          if (result == 'OK') {
            final raw = data['data'];
            _results[db] = _FetchResult.ok(raw);
          } else {
            _results[db] = _FetchResult.error('Controller returned: $result');
          }
        });
      });
    }

    final gaps = ref.watch(recoveryProvider).gaps;
    final backupState = ref.watch(recoveryProvider).backupState;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Gap Fill — Command Test'),
        backgroundColor: cs.surface,
        foregroundColor: cs.onSurface,
        elevation: 0,
      ),
      backgroundColor: cs.surfaceContainerLowest,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Left panel: controls ──────────────────────────────────────────
          SizedBox(
            width: 300,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SectionHeader('Connection & State'),
                  _InfoTile('Backup state', backupState.name),
                  _InfoTile('Active gaps', '${gaps.length}'),
                  const SizedBox(height: 16),

                  _SectionHeader('Gap Ranges Detected'),
                  if (gaps.isEmpty)
                    _Callout(
                      icon: Icons.info_outline,
                      color: cs.onSurfaceVariant,
                      message: 'No gaps in provider. '
                          'Set a custom range below or trigger a gap detection first.',
                    )
                  else
                    ...gaps.map((g) => _GapChip(gap: g)),

                  const SizedBox(height: 16),
                  _SectionHeader('Custom Range (optional)'),
                  Text(
                    'Overrides detected gap. Leave blank to use detected gap.',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  _DateTimePickerTile(
                    label: 'From',
                    value: _customFrom,
                    onTap: () => _pickDateTime(true),
                    onClear: () => setState(() => _customFrom = null),
                  ),
                  const SizedBox(height: 6),
                  _DateTimePickerTile(
                    label: 'To',
                    value: _customTo,
                    onTap: () => _pickDateTime(false),
                    onClear: () => setState(() => _customTo = null),
                  ),

                  const SizedBox(height: 20),
                  _SectionHeader('Fetch Single DB'),
                  DropdownButtonFormField<String>(
                    value: _selectedDb,
                    decoration: InputDecoration(
                      labelText: 'DB type',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                    ),
                    items: _dbTypes
                        .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                        .toList(),
                    onChanged: (v) => setState(() => _selectedDb = v!),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: _loading[_selectedDb] == true
                        ? null
                        : () => _fetch(_selectedDb),
                    icon: _loading[_selectedDb] == true
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.download_rounded, size: 16),
                    label: Text('Fetch ${_selectedDb}_db_backup'),
                    style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                  ),

                  const SizedBox(height: 20),
                  _SectionHeader('Fetch All DB Types'),
                  OutlinedButton.icon(
                    onPressed: _loading.values.any((v) => v) ? null : _fetchAll,
                    icon: const Icon(Icons.download_for_offline_outlined,
                        size: 16),
                    label: const Text('Fetch All'),
                    style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                  ),
                ],
              ),
            ),
          ),

          VerticalDivider(width: 1, color: cs.outlineVariant),

          // ── Right panel: results ──────────────────────────────────────────
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SectionHeader('Results'),
                  const SizedBox(height: 8),
                  ..._dbTypes.map((db) => _ResultCard(
                        dbType: db,
                        loading: _loading[db] == true,
                        result: _results[db],
                      )),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Data model ───────────────────────────────────────────────────────────────

class _FetchResult {
  final bool success;
  final String? errorMessage;
  final dynamic rawData;
  final DateTime? from;
  final DateTime? to;

  const _FetchResult._({
    required this.success,
    this.errorMessage,
    this.rawData,
    this.from,
    this.to,
  });

  factory _FetchResult.pending(DateTime from, DateTime to) =>
      _FetchResult._(success: false, from: from, to: to);
  factory _FetchResult.ok(dynamic data) =>
      _FetchResult._(success: true, rawData: data);
  factory _FetchResult.error(String msg) =>
      _FetchResult._(success: false, errorMessage: msg);

  bool get isPending => errorMessage == null && rawData == null;
  int get recordCount =>
      (rawData is List) ? (rawData as List).length : 0;
}

// ─── Widgets ──────────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w600,
          color: cs.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  final String label;
  final String value;
  const _InfoTile(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ),
          Text(value,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _Callout extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String message;
  const _Callout(
      {required this.icon, required this.color, required this.message});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Expanded(
          child:
              Text(message, style: TextStyle(fontSize: 12, color: color)),
        ),
      ],
    );
  }
}

class _GapChip extends StatelessWidget {
  final GapRange gap;
  const _GapChip({required this.gap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(gap.dbFile,
              style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
          Text(
            '${_fmt(gap.start)} → ${_fmt(gap.end)}',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  String _fmt(DateTime dt) =>
      '${dt.year}-${_p(dt.month)}-${_p(dt.day)} ${_p(dt.hour)}:${_p(dt.minute)}';
  String _p(int v) => v.toString().padLeft(2, '0');
}

class _DateTimePickerTile extends StatelessWidget {
  final String label;
  final DateTime? value;
  final VoidCallback onTap;
  final VoidCallback onClear;
  const _DateTimePickerTile({
    required this.label,
    required this.value,
    required this.onTap,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final display = value == null
        ? 'Not set (use gap)'
        : '${value!.year}-${_p(value!.month)}-${_p(value!.day)} '
            '${_p(value!.hour)}:${_p(value!.minute)}';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: cs.outline),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Text('$label: ',
                style:
                    TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            Expanded(
              child: Text(display,
                  style: TextStyle(
                    fontSize: 12,
                    color: value == null
                        ? cs.onSurfaceVariant
                        : cs.onSurface,
                  )),
            ),
            if (value != null)
              GestureDetector(
                onTap: onClear,
                child: Icon(Icons.clear, size: 14,
                    color: cs.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }

  String _p(int v) => v.toString().padLeft(2, '0');
}

class _ResultCard extends StatefulWidget {
  final String dbType;
  final bool loading;
  final _FetchResult? result;
  const _ResultCard(
      {required this.dbType, required this.loading, required this.result});

  @override
  State<_ResultCard> createState() => _ResultCardState();
}

class _ResultCardState extends State<_ResultCard> {
  bool _expanded = true;
  int _maxRecords = 5;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final result = widget.result;

    Color borderColor = cs.outlineVariant;
    Color headerBg = cs.surface;
    if (result != null) {
      if (result.success) {
        borderColor = Colors.green.shade300;
        headerBg = Colors.green.shade50;
      } else if (result.errorMessage != null) {
        borderColor = Colors.red.shade300;
        headerBg = Colors.red.shade50;
      }
    }

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: borderColor),
      ),
      child: Column(
        children: [
          // Header
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(10)),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: headerBg,
                borderRadius: _expanded
                    ? const BorderRadius.vertical(top: Radius.circular(10))
                    : BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Text(
                    '${widget.dbType}_db_backup',
                    style: const TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                        fontSize: 13),
                  ),
                  const SizedBox(width: 10),
                  if (widget.loading)
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else if (result != null && result.success)
                    _Badge(
                        '${result.recordCount} records',
                        Colors.green.shade700,
                        Colors.green.shade100)
                  else if (result != null && result.errorMessage != null)
                    _Badge('Error', Colors.red.shade700,
                        Colors.red.shade100)
                  else if (result != null && result.isPending)
                    _Badge('Sent…', Colors.blue.shade700,
                        Colors.blue.shade100),
                  const Spacer(),
                  Icon(
                    _expanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                    size: 18,
                    color: cs.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),

          // Body
          if (_expanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: _buildBody(cs, result),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme cs, _FetchResult? result) {
    if (result == null) {
      return Text(
        'Not fetched yet. Press Fetch or Fetch All.',
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      );
    }
    if (result.isPending) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Querying controller…',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          if (result.from != null) ...[
            const SizedBox(height: 4),
            Text('From: ${result.from}  →  To: ${result.to}',
                style: const TextStyle(
                    fontSize: 11, fontFamily: 'monospace')),
          ],
        ],
      );
    }
    if (result.errorMessage != null) {
      return Text(result.errorMessage!,
          style: TextStyle(
              fontSize: 12, color: Colors.red.shade700));
    }

    // Success
    final data = result.rawData;
    if (data == null) {
      return Text('No data returned.',
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant));
    }

    final list = data is List ? data : [data];
    final showing = list.take(_maxRecords).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Summary row
        Row(
          children: [
            _Badge('${list.length} records total',
                Colors.green.shade700, Colors.green.shade50),
            const SizedBox(width: 8),
            Text(
              'Showing first $_maxRecords',
              style:
                  TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // Raw records
        Container(
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(6),
          ),
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '// Raw record format — each entry is one DB row',
                style: TextStyle(
                    fontSize: 10,
                    fontFamily: 'monospace',
                    color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 6),
              ...showing.asMap().entries.map((e) {
                final pretty =
                    const JsonEncoder.withIndent('  ').convert(e.value);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '[${e.key}]:',
                        style: TextStyle(
                            fontSize: 10,
                            fontFamily: 'monospace',
                            color: cs.primary,
                            fontWeight: FontWeight.w600),
                      ),
                      SelectableText(
                        pretty,
                        style: const TextStyle(
                            fontSize: 11, fontFamily: 'monospace'),
                      ),
                    ],
                  ),
                );
              }),
              if (list.length > _maxRecords)
                TextButton(
                  onPressed: () =>
                      setState(() => _maxRecords += 5),
                  style: const ButtonStyle(
                    mouseCursor: WidgetStatePropertyAll(
                        SystemMouseCursors.click),
                  ),
                  child: Text(
                    'Show more (${list.length - _maxRecords} remaining)',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),

        // Column count hint
        if (list.isNotEmpty && list.first is List) ...[
          const SizedBox(height: 8),
          Text(
            '→ Record has ${(list.first as List).length} columns. '
            'Check above to identify schema before writing to SQLite.',
            style: TextStyle(
                fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  final Color bg;
  const _Badge(this.label, this.color, this.bg);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: color.withValues(alpha: 0.3))),
      child: Text(label,
          style: TextStyle(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.w600)),
    );
  }
}
