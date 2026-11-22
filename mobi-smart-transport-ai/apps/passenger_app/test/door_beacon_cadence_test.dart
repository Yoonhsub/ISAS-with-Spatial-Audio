import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/door_beacon_cadence.dart';

void main() {
  test('RSSI cadence is bounded and stronger signal shortens interval', () {
    final cadence = DoorBeaconCadence();
    expect(cadence.intervalForRssi(-100), 1300);
    expect(cadence.intervalForRssi(-60), 550);
    expect(cadence.intervalForRssi(-100), 1300);
  });

  test('hysteresis holds a tier at its entry boundary', () {
    final cadence = DoorBeaconCadence();
    expect(cadence.intervalForRssi(-80), 1050);
    expect(cadence.intervalForRssi(-83), 1050);
    expect(cadence.intervalForRssi(-90), 1300);
  });

  test('rejects RSSI outside the scanner range', () {
    final cadence = DoorBeaconCadence();
    expect(() => cadence.intervalForRssi(0), throwsArgumentError);
    expect(() => cadence.intervalForRssi(-121), throwsArgumentError);
  });
}
