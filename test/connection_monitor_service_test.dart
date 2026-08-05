import 'package:flutter_test/flutter_test.dart';
import 'package:reiri_db_backup_tool/service/connection_monitor_service.dart';

void main() {
  test('sync reports only effective connection transitions', () {
    var controllerReady = false;
    final service = ConnectionMonitorService(
      isControllerReady: () => controllerReady,
    );

    expect(service.sync().effectiveConnectionChanged, isFalse);

    controllerReady = true;
    final connected = service.sync();
    expect(connected.effectiveConnected, isTrue);
    expect(connected.effectiveConnectionChanged, isTrue);
    expect(service.sync().effectiveConnectionChanged, isFalse);

    controllerReady = false;
    final disconnected = service.sync();
    expect(disconnected.effectiveConnected, isFalse);
    expect(disconnected.effectiveConnectionChanged, isTrue);
  });

  test('markDisconnected allows a ready connection to be processed again', () {
    final service = ConnectionMonitorService(isControllerReady: () => true);

    expect(service.sync().effectiveConnectionChanged, isTrue);
    service.markDisconnected();
    expect(service.sync().effectiveConnectionChanged, isTrue);
  });
}
