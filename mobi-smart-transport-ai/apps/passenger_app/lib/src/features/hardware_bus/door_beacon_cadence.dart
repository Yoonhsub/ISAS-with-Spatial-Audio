/// RSSI changes cadence only. It is not a distance, direction, or safety value.
class DoorBeaconCadence {
  static const _entryThresholds = [-80, -70, -60];
  static const _exitThresholds = [-84, -74, -64];
  static const _intervals = [1300, 1050, 800, 550];
  int _level = 0;

  void reset() => _level = 0;

  int intervalForRssi(int rssi) {
    if (rssi < -120 || rssi >= 0) {
      throw ArgumentError.value(rssi, 'rssi', 'Expected a valid BLE RSSI');
    }
    // The source scanner already smooths RSSI. These separate entry/exit
    // thresholds add hysteresis so small fluctuations do not chatter.
    while (_level < 3 && rssi >= _entryThresholds[_level]) {
      _level++;
    }
    while (_level > 0 && rssi < _exitThresholds[_level - 1]) {
      _level--;
    }
    return _intervals[_level];
  }
}
