// File purpose: Renders and manages backup, recovery, and startup settings.

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reiri_app_core/reiri_app_core.dart';

import 'package:reiri_db_backup_tool/lib/initial_backup_constants.dart';
import 'package:reiri_db_backup_tool/provider/recovery_provider.dart';

/// Lets the user configure backup storage, recovery, theme, and logout.
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

/// Loads and updates the persisted application settings.
class _SettingsViewState extends ConsumerState<SettingsView> {
  bool? _launchOnStartup; // null = still loading from registry
  bool _autoLogin = false;
  ({int hour, int minute})? _recoveryTime; // null = still loading from disk
  bool? _instantFill; // null = still loading from disk

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

  /// Loads the persisted off-peak recovery schedule into the time fields.
  Future<void> _loadRecoveryTime() async {
    final t = await loadRecoveryTime();
    if (mounted) {
      setState(() => _recoveryTime = (hour: t.hour, minute: t.minute));
    }
  }

  /// Loads whether short gaps should be recovered immediately.
  Future<void> _loadInstantFill() async {
    final v = await loadInstantFill();
    if (mounted) setState(() => _instantFill = v);
  }

  /// Reads the Windows Run entry to reflect the actual startup setting.
  Future<void> _checkStartupRegistry() async {
    final result = await Process.run('reg', [
      'query',
      _regKey,
      '/v',
      _regValueName,
    ]);
    if (mounted) setState(() => _launchOnStartup = result.exitCode == 0);
  }

  /// Adds or removes the current executable from the user's Windows Run key.
  Future<void> _setLaunchOnStartup(bool value) async {
    if (value) {
      final exePath = Platform.resolvedExecutable;
      await Process.run('reg', [
        'add',
        _regKey,
        '/v',
        _regValueName,
        '/t',
        'REG_SZ',
        '/d',
        exePath,
        '/f',
      ]);
    } else {
      await Process.run('reg', ['delete', _regKey, '/v', _regValueName, '/f']);
    }
    await _checkStartupRegistry();
  }

  /// Opens the time picker and persists the selected recovery schedule.
  Future<void> _pickRecoveryTime(BuildContext context) async {
    final current = _recoveryTime ?? kDefaultRecoveryTime;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current.hour, minute: current.minute),
      helpText: app.word('recovery_schedule_time'),
    );
    if (picked == null || !mounted) return;
    setState(() => _recoveryTime = (hour: picked.hour, minute: picked.minute));
    await storeRecoveryTime(picked.hour, picked.minute);
    ref
        .read(recoveryProvider.notifier)
        .updateRecoveryTime(picked.hour, picked.minute);
  }

  /// Selects a backup root and delegates migration to the home screen.
  Future<void> _pickPath() async {
    final path = await getDirectoryPath(
      confirmButtonText: app.word('select_backup_folder'),
    );
    if (path != null && path.isNotEmpty) {
      await widget.onPathChanged(path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final themeMode = ref.watch(stringDataProvider('theme_mode'));
    final isDark =
        themeMode == 'dark' ||
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
                app.word('settings'),
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                app.word('settings_subtitle'),
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
                                      app.word('backup_storage_path'),
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: cs.onSurface,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      widget.backupRootPath ??
                                          app.word('not_configured_browse'),
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
                                icon: const Icon(
                                  Icons.folder_open_outlined,
                                  size: 16,
                                ),
                                label: Text(app.word('browse')),
                                style:
                                    OutlinedButton.styleFrom(
                                      visualDensity: VisualDensity.compact,
                                    ).copyWith(
                                      mouseCursor: const WidgetStatePropertyAll(
                                        SystemMouseCursors.click,
                                      ),
                                    ),
                              ),
                            ],
                          ),
                          if (widget.backupRootPath == null) ...[
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Icon(
                                  Icons.warning_amber_rounded,
                                  size: 14,
                                  color: Colors.orange.shade700,
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  app.word('set_backup_folder_hint'),
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.orange.shade700,
                                  ),
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
                      title: app.word('lang'),
                      subtitle: app.word('display_language_description'),
                      trailing: DropdownButton<String>(
                        value: app.lang,
                        underline: const SizedBox(),
                        borderRadius: BorderRadius.circular(8),
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurface,
                          fontFamily: 'Poppins',
                        ),
                        onChanged: (val) async {
                          if (val != null) {
                            await app.setLang(val);
                            setState(() {});
                          }
                        },
                        items: app.selectableLang
                            .map(
                              (code) => DropdownMenuItem(
                                value: code,
                                child: Text(app.word(code)),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                    _SettingsDivider(),
                    // ── Dark Mode ────────────────────────────────────────────
                    _SettingsTile(
                      title: app.word('dark_mode'),
                      subtitle: app.word('dark_mode_description'),
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
                      title: app.word('launch_on_windows_startup'),
                      subtitle: app.word('launch_startup_description'),
                      trailing: _launchOnStartup == null
                          ? const SizedBox(
                              width: 51,
                              height: 31,
                              child: Center(
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
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
                      title: app.word('auto_login_on_startup'),
                      subtitle: app.word('auto_login_description'),
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
                      title: app.word('recovery_mode'),
                      subtitle: app.word('recovery_mode_description'),
                      trailing: _instantFill == null
                          ? const SizedBox(
                              width: 51,
                              height: 31,
                              child: Center(
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              ),
                            )
                          : SegmentedButton<bool>(
                              segments: [
                                ButtonSegment(
                                  value: true,
                                  label: Text(app.word('immediate')),
                                  icon: const Icon(
                                    Icons.flash_on_rounded,
                                    size: 14,
                                  ),
                                ),
                                ButtonSegment(
                                  value: false,
                                  label: Text(app.word('scheduled')),
                                  icon: const Icon(
                                    Icons.schedule_rounded,
                                    size: 14,
                                  ),
                                ),
                              ],
                              selected: {_instantFill!},
                              style: ButtonStyle(
                                visualDensity: VisualDensity.compact,
                                mouseCursor: const WidgetStatePropertyAll(
                                  SystemMouseCursors.click,
                                ),
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
                      title: app.word('recovery_schedule_time'),
                      subtitle: _instantFill == true
                          ? app.word('immediate_mode_active')
                          : app.word('recovery_schedule_description'),
                      trailing: OutlinedButton(
                        onPressed:
                            (_recoveryTime == null || _instantFill == true)
                            ? null
                            : () => _pickRecoveryTime(context),
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
                        child: Text(
                          _recoveryTime == null
                              ? '--:--'
                              : '${_recoveryTime!.hour.toString().padLeft(2, '0')}:${_recoveryTime!.minute.toString().padLeft(2, '0')}',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                          ),
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
                  label: Text(app.word('logout')),
                  style:
                      FilledButton.styleFrom(
                        backgroundColor: Colors.red.shade600,
                        foregroundColor: Colors.white,
                      ).copyWith(
                        mouseCursor: const WidgetStatePropertyAll(
                          SystemMouseCursors.click,
                        ),
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

/// Renders a labeled settings row with optional control content.
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
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
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

/// Separates adjacent settings rows.
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
