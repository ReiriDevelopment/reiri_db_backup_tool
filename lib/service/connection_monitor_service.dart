// File purpose: Combines controller connection state with network reachability checks.

import 'dart:io';

import 'package:reiri_app_core/reiri_app_core.dart';

import 'package:reiri_db_backup_tool/service/file_log_service.dart';

/// Describes the latest network and effective controller connection state.
class ConnectionMonitorUpdate {
  final bool networkReachable;
  final bool effectiveConnected;
  final bool effectiveConnectionChanged;

  const ConnectionMonitorUpdate({
    required this.networkReachable,
    required this.effectiveConnected,
    required this.effectiveConnectionChanged,
  });
}

/// Combines WebSocket state with faster OS/TCP reachability.
class ConnectionMonitorService {
  static const int _failureThreshold = 3;

  final bool Function() isControllerReady;

  bool _networkReachable = true;
  bool _lastEffectiveConnected = false;
  int _consecutiveProbeFailures = 0;

  bool get networkReachable => _networkReachable;
  ConnectionMonitorService({required this.isControllerReady});

  bool get effectiveConnected => isControllerReady() && _networkReachable;

  /// Probes reachability with failure debouncing, then returns effective state.
  Future<ConnectionMonitorUpdate> checkNow() async {
    final reachable = await _probeNetworkReachable();
    if (reachable) {
      if (_consecutiveProbeFailures > 0) {
        FileLogService().log(
          '[Connection] Network probe recovered after '
          '$_consecutiveProbeFailures failed attempt(s)',
        );
      }
      _consecutiveProbeFailures = 0;
    } else {
      _consecutiveProbeFailures++;
      if (_networkReachable && _consecutiveProbeFailures < _failureThreshold) {
        FileLogService().log(
          '[Connection] Network probe failed '
          '($_consecutiveProbeFailures/$_failureThreshold); '
          'keeping connected state',
        );
        return sync();
      }
    }
    _networkReachable = reachable;
    return sync();
  }

  /// Reconciles WebSocket readiness with the last reachability result and
  /// reports whether the effective connection changed since the prior sync.
  ConnectionMonitorUpdate sync() {
    final effective = effectiveConnected;
    final changed = effective != _lastEffectiveConnected;
    _lastEffectiveConnected = effective;
    return ConnectionMonitorUpdate(
      networkReachable: _networkReachable,
      effectiveConnected: effective,
      effectiveConnectionChanged: changed,
    );
  }

  /// Resets transition tracking after a confirmed disconnection.
  void markDisconnected() {
    _lastEffectiveConnected = false;
  }

  /// Checks for an IPv4 interface and, for local controllers, their TCP port.
  Future<bool> _probeNetworkReachable() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      if (interfaces.isEmpty) return false;
    } catch (_) {
      // Continue to the controller probe on platforms that cannot enumerate
      // interfaces.
    }

    final ipAddress = app.selectedController?['ipaddr']?.toString();
    final isCloud = app.selectedController?['cloud'] == true;
    if (isCloud || ipAddress == null || ipAddress.isEmpty) return true;

    try {
      final socket = await Socket.connect(
        ipAddress,
        52001,
        timeout: const Duration(seconds: 2),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
}
