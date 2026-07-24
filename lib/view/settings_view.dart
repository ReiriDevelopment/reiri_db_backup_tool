import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reiri_app_core/reiri_app_core.dart';

import 'package:reiri_db_backup_tool/lib/initial_backup_constants.dart';
import 'package:reiri_db_backup_tool/provider/recovery_provider.dart';

class SettingsView extends ConsumerStatefulWidget {
  final String? backupRootPath;
  final Future<void> Function(String path) onPathChanged;
  final VoidCallback onLogout;

  const SettingsView({
    super.key,
    required this.backupRootPath,
    required this.onPathChanged,
    required this.onLogout,
  });

  @override
  ConsumerState<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends ConsumerState<SettingsView> {
  bool? _launchOnStartup;   // null = still loading from registry
  bool _autoLogin = false;
  ({int hour, int minute})? _recoveryTime;  // null = still loading from disk
  bool? _instantFill;                       // null = still loading from disk

  static const _regValueName = 'ReiriBackup';
  static const _regKey =
      r'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run';

  @override
  void initState() {
    super.initState();
    _autoLogin = app.autoLogin;
    _checkStartupRegistry();
    _loadRecoveryTime();
    _loadInstantFill();
  }

  Future<void> _loadRecoveryTime() async {
    final t = await loadRecoveryTime();
    if (mounted) setState(() => _recoveryTime = (hour: t.hour, minute: t.minute));
  }

  Future<void> _loadInstantFill() async {
    final v = await loadInstantFill();
    if (mounted) setState(() => _instantFill = v);
  }

  Future<void> _checkStartupRegistry() async {
    final result = await Process.run(
      'reg',
      ['query', _regKey, '/v', _regValueName],
    );
    if (mounted) setState(() => _launchOnStartup = result.exitCode == 0);
  }

  Future<void> _setLaunchOnStartup(bool value) async {
    if (value) {
      final exePath = Platform.resolvedExecutable;
      await Process.run('reg', [
        'add', _regKey, '/v', _regValueName, '/t', 'REG_SZ', '/d', exePath, '/f',
      ]);
    } else {
      await Process.run('reg', [
        'delete', _regKey, '/v', _regValueName, '/f',
      ]);
    }
    await _checkStartupRegistry();
  }

  Future<void> _pickRecoveryTime(BuildContext context) async {
    final current = _recoveryTime ?? kDefaultRecoveryTime;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current.hour, minute: current.minute),
      helpText: 'Recovery Schedule Time',
    );
    if (picked == null || !mounted) return;
    setState(() => _recoveryTime = (hour: picked.hour, minute: picked.minute));
    await storeRecoveryTime(picked.hour, picked.minute);
    ref.read(recoveryProvider.notifier).updateRecoveryTime(picked.hour, picked.minute);
  }

  Future<void> _pickPath() async {
    final path = await getDirectoryPath(
      confirmButtonText: 'Select Backup Folder',
    );
    if (path != null && path.isNotEmpty) {
      await widget.onPathChanged(path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final themeMode = ref.watch(stringDataProvider('theme_mode'));
    final isDark = themeMode == 'dark' ||
        (themeMode != 'light' &&
            MediaQuery.of(context).platformBrightness == Brightness.dark);

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
                'Settings',
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface),
              ),
              const SizedBox(height: 2),
              Text(
                'Configure backup preferences and connection',
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              Card(
                elevation: 0,
                color: cs.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: cs.outlineVariant),
                ),
                child: Column(
                  children: [
                    // ── Backup Storage Path ──────────────────────────────────
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Backup Storage Path',
                                      style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: cs.onSurface),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      widget.backupRootPath ??
                                          'Not configured. Tap Browse to set.',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontFamily: 'monospace',
                                        color: widget.backupRootPath != null
                                            ? cs.onSurfaceVariant
                                            : Colors.orange.shade700,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 16),
                              OutlinedButton.icon(
                                onPressed: _pickPath,
                                icon: const Icon(Icons.folder_open_outlined,
                                    size: 16),
                                label: const Text('Browse'),
                                style: OutlinedButton.styleFrom(
                                    visualDensity: VisualDensity.compact).copyWith(
                                  mouseCursor: const WidgetStatePropertyAll(SystemMouseCursors.click),
                                ),
                              ),
                            ],
                          ),
                          if (widget.backupRootPath == null) ...[
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Icon(Icons.warning_amber_rounded,
                                    size: 14, color: Colors.orange.shade700),
                                const SizedBox(width: 5),
                                Text(
                                  'Set your backup folder to enable dashboard DB stats.',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.orange.shade700),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    _SettingsDivider(),
                    // ── Language ─────────────────────────────────────────────
                    _SettingsTile(
                      title: 'Language',
                      subtitle: 'Display language for all UI text',
                      trailing: DropdownButton<String>(
                        value: app.lang,
                        underline: const SizedBox(),
                        borderRadius: BorderRadius.circular(8),
                        style: TextStyle(
                            fontSize: 13,
                            color: cs.onSurface,
                            fontFamily: 'Poppins'),
                        onChanged: (val) async {
                          if (val != null) {
                            await app.setLang(val);
                            setState(() {});
                          }
                        },
                        items: app.selectableLang
                            .map((code) => DropdownMenuItem(
                                  value: code,
                                  child: Text(app.word(code)),
                                ))
                            .toList(),
                      ),
                    ),
                    _SettingsDivider(),
                    // ── Dark Mode ────────────────────────────────────────────
                    _SettingsTile(
                      title: 'Dark Mode',
                      subtitle: 'Switch between light and dark appearance',
                      trailing: Switch(
                        value: isDark,
                        onChanged: (val) {
                          ref
                              .read(stringDataProvider('theme_mode').notifier)
                              .set(val ? 'dark' : 'light');
                        },
                      ),
                    ),
                    _SettingsDivider(),
                    // ── Launch on Windows Startup ────────────────────────────
                    _SettingsTile(
                      title: 'Launch on Windows Startup',
                      subtitle: 'Start the app automatically when Windows boots',
                      trailing: _launchOnStartup == null
                          ? const SizedBox(
                              width: 51, height: 31,
                              child: Center(
                                child: SizedBox(
                                  width: 16, height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              ),
                            )
                          : Switch(
                              value: _launchOnStartup!,
                              onChanged: _setLaunchOnStartup,
                            ),
                    ),
                    _SettingsDivider(),
                    // ── Auto-login on Startup ────────────────────────────────
                    _SettingsTile(
                      title: 'Auto-login on Startup',
                      subtitle: 'Connect to last-used controller automatically',
                      trailing: Switch(
                        value: _autoLogin,
                        onChanged: (val) async {
                          await app.setAutoLogin(val);
                          if (mounted) setState(() => _autoLogin = val);
                        },
                      ),
                    ),
                    _SettingsDivider(),
                    // ── Recovery Mode ────────────────────────────────────────
                    _SettingsTile(
                      title: 'Recovery Mode',
                      subtitle: 'Fill missing data immediately on reconnect, or at a scheduled time',
                      trailing: _instantFill == null
                          ? const SizedBox(
                              width: 51, height: 31,
                              child: Center(
                                child: SizedBox(
                                  width: 16, height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              ),
                            )
                          : SegmentedButton<bool>(
                              segments: const [
                                ButtonSegment(
                                  value: true,
                                  label: Text('Immediate'),
                                  icon: Icon(Icons.flash_on_rounded, size: 14),
                                ),
                                ButtonSegment(
                                  value: false,
                                  label: Text('Scheduled'),
                                  icon: Icon(Icons.schedule_rounded, size: 14),
                                ),
                              ],
                              selected: {_instantFill!},
                              style: ButtonStyle(
                                visualDensity: VisualDensity.compact,
                                mouseCursor: const WidgetStatePropertyAll(SystemMouseCursors.click),
                              ),
                              onSelectionChanged: (s) async {
                                final val = s.first;
                                setState(() => _instantFill = val);
                                await storeInstantFill(val);
                              },
                            ),
                    ),
                    _SettingsDivider(),
                    // ── Recovery Schedule Time ───────────────────────────────
                    _SettingsTile(
                      title: 'Recovery Schedule Time',
                      subtitle: _instantFill == true
                          ? 'Not used — immediate mode is active'
                          : 'Daily time to merge gap recovery data into backup',
                      trailing: OutlinedButton(
                        onPressed: (_recoveryTime == null || _instantFill == true)
                            ? null
                            : () => _pickRecoveryTime(context),
                        style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact).copyWith(
                          mouseCursor: WidgetStateProperty.resolveWith((s) =>
                              s.contains(WidgetState.disabled)
                                  ? SystemMouseCursors.basic
                                  : SystemMouseCursors.click),
                        ),
                        child: Text(
                          _recoveryTime == null
                              ? '--:--'
                              : '${_recoveryTime!.hour.toString().padLeft(2, '0')}:${_recoveryTime!.minute.toString().padLeft(2, '0')}',
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 13),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: widget.onLogout,
                  icon: const Icon(Icons.logout_rounded, size: 16),
                  label: const Text('Logout'),
                  style: FilledButton.styleFrom(
                      backgroundColor: Colors.red.shade600,
                      foregroundColor: Colors.white).copyWith(
                    mouseCursor: const WidgetStatePropertyAll(SystemMouseCursors.click),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget trailing;

  const _SettingsTile({
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style:
                      TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          trailing,
        ],
      ),
    );
  }
}

class _SettingsDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      indent: 20,
      endIndent: 20,
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }
}
