import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reiri_app_core/reiri_app_core.dart';

import '../model/backup_log_entry.dart';

const _kStorageKey = 'BACKUP_LOG_V1';
const _kMaxEntries = 1000000;

final backupLogProvider =
    NotifierProvider<BackupLogNotifier, List<BackupLogEntry>>(
  BackupLogNotifier.new,
);

class BackupLogNotifier extends Notifier<List<BackupLogEntry>> {
  String _mac = '';

  @override
  List<BackupLogEntry> build() => [];

  Future<void> init(String mac) async {
    if (_mac == mac) return;
    _mac = mac;
    await _load();
  }

  Future<void> _load() async {
    try {
      final data = await app.loadJson(_kStorageKey, macaddr: _mac);
      final raw = data['entries'] as List<dynamic>? ?? [];
      state = raw
          .map((e) => BackupLogEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {}
  }

  Future<void> addEntry(BackupLogEntry entry) => addEntries([entry]);

  Future<void> addEntries(List<BackupLogEntry> newEntries) async {
    if (_mac.isEmpty) return;
    final updated = [...newEntries, ...state];
    final capped = updated.length > _kMaxEntries
        ? updated.sublist(0, _kMaxEntries)
        : updated;
    state = capped;
    await _persist(capped);
  }

  Future<void> _persist(List<BackupLogEntry> entries) async {
    try {
      await app.storeJson(
        _kStorageKey,
        {'entries': entries.map((e) => e.toJson()).toList()},
        macaddr: _mac,
      );
    } catch (_) {}
  }

  /// Persists entries directly to storage without going through the provider.
  /// Use this from screens that run before HomeScreen mounts (e.g. initial backup).
  static Future<void> persistEntries(
      String mac, List<BackupLogEntry> newEntries) async {
    try {
      final data = await app.loadJson(_kStorageKey, macaddr: mac);
      final raw = data['entries'] as List<dynamic>? ?? [];
      final existing = raw
          .map((e) => BackupLogEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      final all = [...newEntries, ...existing];
      final capped =
          all.length > _kMaxEntries ? all.sublist(0, _kMaxEntries) : all;
      await app.storeJson(
        _kStorageKey,
        {'entries': capped.map((e) => e.toJson()).toList()},
        macaddr: mac,
      );
    } catch (_) {}
  }

  /// Wipes all log entries for [mac] from storage.
  static Future<void> clearEntries(String mac) async {
    try {
      await app.storeJson(_kStorageKey, {'entries': []}, macaddr: mac);
    } catch (_) {}
  }
}
