// File purpose: Loads, persists, and publishes per-controller backup log entries.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reiri_app_core/reiri_app_core.dart';

import '../model/backup_log_entry.dart';

const _kStorageKey = 'BACKUP_LOG_V1';
const _kMaxEntries = 1000000;

final backupLogProvider =
    NotifierProvider<BackupLogNotifier, List<BackupLogEntry>>(
      BackupLogNotifier.new,
    );

/// Loads, filters, and persists backup log entries for the selected controller.
class BackupLogNotifier extends Notifier<List<BackupLogEntry>> {
  String _mac = '';

  @override
  List<BackupLogEntry> build() => [];

  /// Switches to [mac] and loads that controller's persisted log once.
  Future<void> init(String mac) async {
    if (_mac == mac) return;
    _mac = mac;
    await _load();
  }

  /// Decodes stored entries into state; unreadable storage is treated as empty.
  Future<void> _load() async {
    try {
      final data = await app.loadJson(_kStorageKey, macaddr: _mac);
      final raw = data['entries'] as List<dynamic>? ?? [];
      state = raw
          .map((e) => BackupLogEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {}
  }

  /// Prepends new activity, enforces the retention cap, and persists the result.
  Future<void> addEntries(List<BackupLogEntry> newEntries) async {
    if (_mac.isEmpty) return;
    final updated = [...newEntries, ...state];
    final capped = updated.length > _kMaxEntries
        ? updated.sublist(0, _kMaxEntries)
        : updated;
    state = capped;
    await _persist(capped);
  }

  /// Serializes the current controller's entries to application storage.
  Future<void> _persist(List<BackupLogEntry> entries) async {
    try {
      await app.storeJson(_kStorageKey, {
        'entries': entries.map((e) => e.toJson()).toList(),
      }, macaddr: _mac);
    } catch (_) {}
  }

  /// Wipes all log entries for [mac] from storage.
  static Future<void> clearEntries(String mac) async {
    try {
      await app.storeJson(_kStorageKey, {'entries': []}, macaddr: mac);
    } catch (_) {}
  }
}
